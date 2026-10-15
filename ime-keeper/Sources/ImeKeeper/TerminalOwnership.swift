import AppKit
import Darwin
import Foundation

// All callers run on the main thread. Reuse the compiled script rather than
// spawning osascript several times on every focus transition.
private let ghosttyFocusScript = NSAppleScript(source: """
    with timeout of 1 seconds
    tell application "Ghostty"
        if not frontmost then return ""
        return id of focused terminal of selected tab of front window
    end tell
    end timeout
    """)

/// A terminal surface distinguishes Ghostty tabs and splits, unlike app focus.
func focusedGhosttySurface() throws -> String? {
    guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == TerminalApp.ghostty.bundleIdentifier else { return nil }
    guard let script = ghosttyFocusScript else { throw KeeperError.message("cannot compile Ghostty focus query") }
    var error: NSDictionary?
    let result = script.executeAndReturnError(&error)
    if let error { throw KeeperError.message("Ghostty focus query failed: \(error)") }
    let value = (result.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return nil }
    guard UUID(uuidString: value) != nil else { throw KeeperError.message("Ghostty returned an invalid terminal ID") }
    return value
}

private let kittyCommandStart = Data("\u{1b}P@kitty-cmd".utf8)
private let kittyCommandEnd = Data("\u{1b}\\".utf8)

func kittyCommand(_ name: String, payload: [String: Any] = [:]) throws -> Data {
    let body: [String: Any] = ["cmd": name, "version": [0, 26, 0], "no_response": false, "payload": payload]
    return kittyCommandStart + (try JSONSerialization.data(withJSONObject: body)) + kittyCommandEnd
}

/// Returns nil until a complete `ESC P @kitty-cmd ... ESC \` frame has arrived.
func kittyResponse(_ buffer: Data) throws -> [String: Any]? {
    guard let start = buffer.range(of: kittyCommandStart) else { return nil }
    guard let end = buffer.range(of: kittyCommandEnd, in: start.upperBound..<buffer.endIndex) else { return nil }
    guard let response = try JSONSerialization.jsonObject(with: buffer[start.upperBound..<end.lowerBound]) as? [String: Any] else {
        throw KeeperError.message("kitty response is not a JSON object")
    }
    guard response["ok"] as? Bool == true else {
        throw KeeperError.message("kitty remote control: \(response["error"] as? String ?? "request failed")")
    }
    return response
}

/// The window ID with keyboard focus, or nil when no kitty OS window is focused.
func kittyFocusedWindow(_ response: [String: Any]) throws -> String? {
    guard let text = response["data"] as? String,
          let osWindows = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]] else {
        throw KeeperError.message("kitty ls returned no window list")
    }
    for osWindow in osWindows where osWindow["is_focused"] as? Bool == true {
        for tab in osWindow["tabs"] as? [[String: Any]] ?? [] where tab["is_focused"] as? Bool == true {
            for window in tab["windows"] as? [[String: Any]] ?? [] where window["is_focused"] as? Bool == true {
                guard let id = window["id"] as? Int else { throw KeeperError.message("kitty returned an invalid window ID") }
                return String(id)
            }
        }
    }
    return nil
}

/// Speaks kitty's remote-control protocol in process; spawning `kitten` on every poll is too slow.
func focusedKittySurface(listenOn: String) throws -> String? {
    guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == TerminalApp.kitty.bundleIdentifier else { return nil }
    guard listenOn.hasPrefix("unix:") else { throw KeeperError.message("kitty listen_on must be a unix: socket, got \(listenOn)") }
    let deadline = Date().addingTimeInterval(1)
    let socket = try UnixSocket(path: String(listenOn.dropFirst(5)), deadline: deadline)
    try socket.write(try kittyCommand("ls"), deadline: deadline)
    var buffer = Data()
    while true {
        if let response = try kittyResponse(buffer) { return try kittyFocusedWindow(response) }
        guard buffer.count <= 8 * 1024 * 1024 else { throw KeeperError.message("kitty response is too large") }
        guard let data = try socket.readAvailable(until: deadline) else { throw KeeperError.message("kitty focus query timed out") }
        buffer.append(data)
    }
}

enum TerminalApp: String, Codable {
    case ghostty, kitty
    var bundleIdentifier: String { self == .ghostty ? "com.mitchellh.ghostty" : "net.kovidgoyal.kitty" }
    var displayName: String { self == .ghostty ? "Ghostty" : "kitty" }
}

/// The terminal hosting the remote wrapper and how to ask it for the focused surface.
struct TerminalTarget: Codable, Equatable {
    let app: TerminalApp
    var listenOn: String? = nil
    static let ghostty = TerminalTarget(app: .ghostty)

    /// Ghostty sets TERM_PROGRAM; kitty exports its window ID and remote-control socket.
    static func current(_ environment: [String: String]) throws -> TerminalTarget {
        guard environment["TERM_PROGRAM"] != "ghostty", environment["KITTY_WINDOW_ID"] != nil else { return .ghostty }
        guard let listenOn = environment["KITTY_LISTEN_ON"], !listenOn.isEmpty else {
            throw KeeperError.message("kitty remote control is unavailable; set `allow_remote_control socket-only` and `listen_on unix:/tmp/kitty` in kitty.conf, then restart kitty")
        }
        return TerminalTarget(app: .kitty, listenOn: listenOn)
    }

    func focusedSurface() throws -> String? {
        switch app {
        case .ghostty: return try focusedGhosttySurface()
        case .kitty:
            guard let listenOn else { throw KeeperError.message("kitty registration has no remote-control socket") }
            return try focusedKittySurface(listenOn: listenOn)
        }
    }
}

func terminalCanControl(remoteSurface: String, focusedSurface: String?, remote: Bool) -> Bool {
    guard let focusedSurface else { return false }
    return remote ? focusedSurface == remoteSurface : focusedSurface != remoteSurface
}

/// Used only on the main thread. Cache polling, but never the final switch check.
final class RemoteTerminalFocus {
    let surfaceID: String
    let terminal: TerminalTarget
    private var checkedAt = Date.distantPast
    private var selected = false
    private(set) var error: String?
    private let query: () throws -> String?

    init(surfaceID: String, terminal: TerminalTarget = .ghostty, query: (() throws -> String?)? = nil) {
        self.surfaceID = surfaceID
        self.terminal = terminal
        self.query = query ?? terminal.focusedSurface
    }

    func isSelected(fresh: Bool = false) -> Bool {
        if fresh || Date().timeIntervalSince(checkedAt) >= 0.1 {
            do {
                selected = terminalCanControl(remoteSurface: surfaceID, focusedSurface: try query(), remote: true)
                error = nil
            } catch {
                selected = false
                self.error = "\(terminal.app.displayName) terminal query failed; input-source control paused: \(error)"
            }
            checkedAt = Date()
        }
        return selected
    }
}

/// This lock prevents duplicate wrappers only. It never locks out local hooks.
final class RemoteRegistration {
    struct Record: Codable, Equatable {
        let pid: Int32
        let surfaceID: String
        let token: UUID
        var terminal = TerminalTarget.ghostty

        init(pid: Int32, surfaceID: String, token: UUID, terminal: TerminalTarget = .ghostty) {
            (self.pid, self.surfaceID, self.token, self.terminal) = (pid, surfaceID, token, terminal)
        }

        // Records written before kitty support have no terminal and were Ghostty.
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            pid = try values.decode(Int32.self, forKey: .pid)
            surfaceID = try values.decode(String.self, forKey: .surfaceID)
            token = try values.decode(UUID.self, forKey: .token)
            terminal = try values.decodeIfPresent(TerminalTarget.self, forKey: .terminal) ?? .ghostty
        }
    }
    private let lock: FileLock
    private let path: URL
    private let record: Record

    static func lockPath(_ directory: URL) -> String { directory.appendingPathComponent("remote-instance.lock").path }

    init(directory: URL, surfaceID: String, terminal: TerminalTarget = .ghostty) throws {
        lock = try FileLock(path: Self.lockPath(directory), nonblocking: true)
        path = directory.appendingPathComponent("remote-controller.json")
        record = Record(pid: getpid(), surfaceID: surfaceID, token: UUID(), terminal: terminal)
        try JSONEncoder().encode(record).write(to: path, options: .atomic)
    }

    deinit {
        if let data = try? Data(contentsOf: path), let current = try? JSONDecoder().decode(Record.self, from: data), current == record {
            try? FileManager.default.removeItem(at: path)
        }
        withExtendedLifetime(lock) {}
    }

    static func active(in directory: URL) throws -> Record? {
        if let probe = try FileLock.tryAcquire(path: lockPath(directory)) {
            return withExtendedLifetime(probe) { nil } // Ignore files left by a crashed process.
        }
        return try JSONDecoder().decode(Record.self, from: Data(contentsOf: directory.appendingPathComponent("remote-controller.json")))
    }
}

func localInputAllowed(store: Store, query: (() throws -> String?)? = nil) throws -> Bool {
    guard let remote = try RemoteRegistration.active(in: store.directory) else { return true }
    let focused = try (query ?? remote.terminal.focusedSurface)()
    return terminalCanControl(remoteSurface: remote.surfaceID, focusedSurface: focused, remote: false)
}

/// Call under the short global switch lock. Changing domains invalidates the
/// previous physical policy; another terminal's source is not an editing choice.
struct InputOwner {
    let directory: URL
    private var path: URL { directory.appendingPathComponent("input-owner.json") }
    func isCurrent(_ owner: String) -> Bool {
        guard let data = try? Data(contentsOf: path), let saved = try? JSONDecoder().decode(String.self, from: data) else { return false }
        return saved == owner
    }
    func claim(_ owner: String) throws { try JSONEncoder().encode(owner).write(to: path, options: .atomic) }
}

extension SessionState {
    mutating func relinquishInputObservation() {
        for key in editors.keys { editors[key]?.appliedMode = nil }
        currentPane = nil
        entryInputSourceID = nil
    }
}
