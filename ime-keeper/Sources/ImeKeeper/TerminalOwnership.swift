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
    guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.mitchellh.ghostty" else { return nil }
    guard let script = ghosttyFocusScript else { throw KeeperError.message("cannot compile Ghostty focus query") }
    var error: NSDictionary?
    let result = script.executeAndReturnError(&error)
    if let error { throw KeeperError.message("Ghostty focus query failed: \(error)") }
    let value = (result.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return nil }
    guard UUID(uuidString: value) != nil else { throw KeeperError.message("Ghostty returned an invalid terminal ID") }
    return value
}

func terminalCanControl(remoteSurface: String, focusedSurface: String?, remote: Bool) -> Bool {
    guard let focusedSurface else { return false }
    return remote ? focusedSurface == remoteSurface : focusedSurface != remoteSurface
}

/// Used only on the main thread. Cache polling, but never the final switch check.
final class RemoteTerminalFocus {
    let surfaceID: String
    private var checkedAt = Date.distantPast
    private var selected = false
    private(set) var error: String?
    private let query: () throws -> String?

    init(surfaceID: String, query: @escaping () throws -> String? = focusedGhosttySurface) {
        self.surfaceID = surfaceID
        self.query = query
    }

    func isSelected(fresh: Bool = false) -> Bool {
        if fresh || Date().timeIntervalSince(checkedAt) >= 0.1 {
            do {
                selected = terminalCanControl(remoteSurface: surfaceID, focusedSurface: try query(), remote: true)
                error = nil
            } catch {
                selected = false
                self.error = "Ghostty terminal query failed; input-source control paused: \(error)"
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
    }
    private let lock: FileLock
    private let path: URL
    private let record: Record

    static func lockPath(_ directory: URL) -> String { directory.appendingPathComponent("remote-instance.lock").path }

    init(directory: URL, surfaceID: String) throws {
        lock = try FileLock(path: Self.lockPath(directory), nonblocking: true)
        path = directory.appendingPathComponent("remote-controller.json")
        record = Record(pid: getpid(), surfaceID: surfaceID, token: UUID())
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

func localInputAllowed(store: Store, query: () throws -> String? = focusedGhosttySurface) throws -> Bool {
    guard let remote = try RemoteRegistration.active(in: store.directory) else { return true }
    return terminalCanControl(remoteSurface: remote.surfaceID, focusedSurface: try query(), remote: false)
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
