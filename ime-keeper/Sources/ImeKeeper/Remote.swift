import AppKit
import Darwin
import Foundation

/// The reader can invalidate an in-flight query without waiting for that query.
final class RemoteInbox {
    private let lock = NSLock()
    private var revision: UInt64 = 1
    private var stopped = false
    private var failure: String?
    private var focusAt = Date.distantPast
    private var departure: String?
    private var focusSample: UInt64 = 0
    private var focusSamplePending = false

    struct View {
        let revision: UInt64
        let stopped: Bool
        let failure: String?
        let focusAt: Date
        let departure: String?
        let focusSamplePending: Bool
    }
    func view() -> View {
        lock.lock(); defer { lock.unlock() }
        return View(revision: revision, stopped: stopped, failure: failure, focusAt: focusAt,
                    departure: departure, focusSamplePending: focusSamplePending)
    }
    // Invalidate BEFORE dispatching to the main thread. Otherwise an already
    // queued switch can run first and become the supposed departure source.
    func beginFocusSample() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        revision &+= 1
        focusSample &+= 1
        focusSamplePending = true
        focusAt = Date()
        return focusSample
    }
    func finishFocusSample(_ sample: UInt64, source: String?) {
        lock.lock(); defer { lock.unlock() }
        guard sample == focusSample, focusSamplePending else { return }
        if departure == nil { departure = source }
        focusSamplePending = false
        revision &+= 1
    }
    func invalidate(focus: Bool = false, source: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        revision &+= 1
        if focus {
            focusAt = Date()
            // The first departure belongs to the last applied pane. Intermediate
            // panes in a rapid burst never owned the input source.
            if departure == nil { departure = source }
        }
    }
    func consumed(_ revision: UInt64) {
        lock.lock(); defer { lock.unlock() }
        if self.revision == revision { departure = nil }
    }
    func fail(_ error: String) { lock.lock(); failure = error; revision &+= 1; lock.unlock() }
    func stop() { lock.lock(); stopped = true; lock.unlock() }
}

private func onMain<T>(_ operation: () throws -> T) rethrows -> T {
    try DispatchQueue.main.sync(execute: operation)
}

final class RemoteBridge {
    let options: RemoteOptions
    let directories: PluginDirectories
    let terminalFocus: RemoteTerminalFocus
    let stopSignal = RemoteInbox()
    private var state = SessionState.empty
    private var terminalPanes: [String: Pane] = [:]
    private var store: Store?
    private var remoteSocket = ""
    private var lastError: String?
    private var identityCache: [Int32: (Date, LocalProcessIdentity)] = [:]

    init(options: RemoteOptions, directories: PluginDirectories, terminalFocus: RemoteTerminalFocus) {
        self.options = options
        self.directories = directories
        self.terminalFocus = terminalFocus
    }

    private func configuration() throws -> Configuration {
        let path = directories.config.appendingPathComponent("config.json")
        if !FileManager.default.fileExists(atPath: path.path) { return Configuration(version: 1, rules: []) }
        return try Configuration.decode(Data(contentsOf: path))
    }

    private func status(_ connection: String) {
        var value: [String: Any] = ["target": options.target, "session": options.session ?? "default",
            "connection": connection, "pid": getpid(), "socket": remoteSocket,
            "ghosttyTerminalID": terminalFocus.surfaceID,
            "state": (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(state))) ?? [:]]
        if let lastError { value["error"] = lastError }
        if let focusError = onMain({ terminalFocus.error }) { value["focusError"] = focusError }
        let path = directories.state.appendingPathComponent("remote-status.json")
        do { try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: path, options: .atomic) }
        catch { log("cannot save remote status: \(error)") }
    }

    func run() {
        var retry: TimeInterval = 0.5
        while !stopSignal.view().stopped {
            do {
                let ssh = try RemoteSSH(options: options)
                defer { ssh.stop() }
                remoteSocket = try ssh.discover()
                try ssh.start(socket: remoteSocket)
                let api = HerdrAPI(path: ssh.localSocket)
                let subscription = try api.subscribe()
                let currentStore = try Store(directory: directories.state, key: "remote-" + options.namespace(socket: remoteSocket))
                // Refuse to overwrite a corrupt file. There is no stable server
                // incarnation in the API; a new connection starts fresh memory.
                _ = try currentStore.load()
                store = currentStore
                state = .empty
                terminalPanes = [:]
                identityCache = [:]
                lastError = nil
                let inbox = RemoteInbox()
                let readerDone = DispatchSemaphore(value: 0)
                DispatchQueue.global().async {
                    defer { readerDone.signal() }
                    do {
                        while !inbox.view().stopped && !self.stopSignal.view().stopped {
                            guard let event = try subscription.read(timeout: 0.2) else { continue }
                            let kind = event["event"] as? String ?? event["type"] as? String ?? ""
                            if kind == "events_lost" || (event["result"] as? [String: Any])?["type"] as? String == "events_lost" {
                                throw KeeperError.message("Herdr events lost; resubscribing")
                            }
                            let focus = kind == "pane_focused" || kind == "pane.focused"
                            if focus {
                                let sample = inbox.beginFocusSample()
                                let source: String? = onMain {
                                    let source = try? currentInputSourceID()
                                    return self.terminalFocus.isSelected(fresh: true) ? source : nil
                                }
                                inbox.finishFocusSample(sample, source: source)
                            } else {
                                inbox.invalidate()
                            }
                        }
                    } catch { inbox.fail(String(describing: error)) }
                }
                defer {
                    inbox.stop()
                    shutdown(subscription.fd, SHUT_RDWR)
                    _ = readerDone.wait(timeout: .now() + 1)
                }
                var handled: UInt64 = 0
                var wasFront = false
                var healthAt = Date.distantPast
                retry = 0.5
                while !stopSignal.view().stopped {
                    let front = onMain { terminalFocus.isSelected() }
                    if front != wasFront {
                        if !front {
                            // Never interpret another application's source as an
                            // editor choice when returning to Ghostty.
                            state.relinquishInputObservation()
                        }
                        inbox.invalidate()
                    }
                    let activated = front && !wasFront
                    wasFront = front
                    let view = inbox.view()
                    if let failure = view.failure { throw KeeperError.message(failure) }
                    if view.focusSamplePending || Date().timeIntervalSince(view.focusAt) < 0.1 {
                        Thread.sleep(forTimeInterval: 0.01)
                        continue
                    }
                    if handled != view.revision || activated || Date() >= healthAt {
                        if try reconcile(api: api, ssh: ssh, inbox: inbox, view: view, front: front) {
                            handled = view.revision
                            inbox.consumed(view.revision)
                            healthAt = Date().addingTimeInterval(2)
                            status(front ? "connected" : "paused: remote Ghostty terminal is not focused")
                        }
                    }
                    Thread.sleep(forTimeInterval: 0.02)
                }
            } catch {
                lastError = String(describing: error)
                status("disconnected; retrying")
                // Do not write diagnostics over the interactive terminal.
                let deadline = Date().addingTimeInterval(retry)
                while !stopSignal.view().stopped && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
                retry = min(retry * 2, 8)
            }
        }
        status("stopped")
    }

    private func reconcile(api: HerdrAPI, ssh: RemoteSSH, inbox: RemoteInbox,
                           view: RemoteInbox.View, front: Bool) throws -> Bool {
        guard let store else { return false }
        let result = try api.request("session.snapshot")
        guard let snapshot = result["snapshot"] as? [String: Any],
              let rows = snapshot["panes"] as? [[String: Any]] else {
            throw KeeperError.message("Herdr snapshot is missing panes")
        }
        let focusedID = snapshot["focused_pane_id"] as? String
        var candidate = state
        let ownership = InputOwner(directory: store.directory)
        if !ownership.isCurrent(store.key) { candidate.relinquishInputObservation() }
        var terminals: [String: Pane] = [:]
        for row in rows {
            let pane = try remotePane(row)
            if let terminal = row["terminal_id"] as? String {
                terminals[terminal] = pane
                if let old = terminalPanes[terminal], old != pane { candidate.movePane(from: old.paneID, to: pane) }
            }
        }
        let ids = Set(try rows.map { try remotePane($0).paneID })
        for id in Set(candidate.panes.keys).union(candidate.editors.keys) where !ids.contains(id) { candidate.closePane(id) }
        let focusedRow = rows.first { $0["pane_id"] as? String == focusedID }
        let pane = try focusedRow.map(remotePane)
        let entering = candidate.currentPane?.paneID != focusedID
        let observed: String? = try onMain { front && terminalFocus.isSelected(fresh: true) ? try currentInputSourceID() : nil }
        if entering, let source = view.departure ?? observed {
            // A focus event can still arrive after another app became active.
            if front { candidate.rememberLeavingPane(currentInputSourceID: source) }
        }
        let session = EditorSession(sourceID: "ssh:" + options.target, sessionID: store.key)
        // Background panes update mode caches without sampling the global IME.
        for row in rows where row["pane_id"] as? String != focusedID {
            let background = try remotePane(row)
            if let event = try? remoteEditorEvent(tokens: row["tokens"] as? [String: String] ?? [:]) {
                _ = try candidate.receiveRemoteEditor(event, pane: background, session: session, observed: nil)
            } else { _ = candidate.releaseRemoteEditor(paneID: background.paneID) }
        }
        guard let row = focusedRow, let pane else {
            candidate.currentPane = nil
            state = candidate
            terminalPanes = terminals
            try store.save(state)
            return true
        }
        let config = try configuration()
        let event = try remoteEditorEvent(tokens: row["tokens"] as? [String: String] ?? [:])
        var processes: [ForegroundProcess] = []
        if remoteNeedsProcesses(event: event, entering: entering,
                                saved: candidate.panes[pane.paneID], rules: config.rules) {
            let processResult = try api.request("pane.process_info", ["pane_id": pane.paneID])
            guard let info = processResult["process_info"] as? [String: Any] else {
                throw KeeperError.message("Herdr process response is missing process_info")
            }
            processes = remoteProcesses(info)
        }
        var desired = entering ? desiredInputSource(saved: candidate.panes[pane.paneID],
            ruleInputSourceID: matchingInputSource(rules: config.rules, processes: processes)) : nil
        var valid = false
        if let event {
            valid = editorIsForeground(pid: event.pid, processes: processes) { pid in
                if let (time, identity) = self.identityCache[pid], Date().timeIntervalSince(time) < 1 { return identity }
                guard let identity = ssh.identity(pid: pid) else { return nil }
                self.identityCache[pid] = (Date(), identity)
                return identity
            }
            // Exit/suspend may arrive after the editor relinquishes foreground.
            if !valid, event.event == .exit || event.event == .suspend,
               let previous = candidate.editors[pane.paneID], previous.instanceID == event.instanceID,
               previous.pid == event.pid { valid = true }
        }
        desired = try candidate.remoteFocusTarget(event: event, verified: valid, pane: pane, session: session,
                                                   entering: entering, observed: observed, ordinaryTarget: desired)
        // Revalidate focus and metadata after process queries; never apply an
        // old snapshot over a newer mode or a focus event received meanwhile.
        let currentResult = try api.request("pane.current")
        guard let current = currentResult["pane"] as? [String: Any],
              current["pane_id"] as? String == pane.paneID,
              current["tokens"] as? [String: String] == row["tokens"] as? [String: String],
              inbox.view().revision == view.revision, inbox.view().failure == nil else { return false }
        let applied = try onMain { () -> Bool in
            guard !self.stopSignal.view().stopped, inbox.view().revision == view.revision else { return false }
            guard front else { return true }
            let lock = try FileLock(path: store.switchLockPath)
            defer { withExtendedLifetime(lock) {} }
            guard self.terminalFocus.isSelected(fresh: true) else { return false }
            // The lock and AppleScript query can both wait. A focus event may
            // have invalidated this candidate during either operation.
            guard inbox.view().revision == view.revision, inbox.view().failure == nil else { return false }
            let latest = try currentInputSourceID()
            let manuallyChanged = candidate.acceptRemoteManualSource(pane: pane,
                baseline: view.departure ?? observed, current: latest)
            var entered = latest
            if let desired, !manuallyChanged {
                do {
                    if latest != desired { try selectInputSource(desired, settle: false) }
                    candidate.editorSwitchSucceeded(paneID: pane.paneID)
                    entered = desired
                    self.lastError = nil
                    if candidate.editors[pane.paneID]?.lifecycle != .active, candidate.panes[pane.paneID] == nil {
                        candidate.panes[pane.paneID] = PaneMemory(inputSourceID: desired, workspaceID: pane.workspaceID, tabID: pane.tabID)
                    }
                } catch {
                    // Preserve both reported mode and last applied policy for
                    // retry; a TIS failure is not a transport disconnect.
                    self.lastError = String(describing: error)
                }
            }
            try ownership.claim(store.key)
            candidate.currentPane = pane
            if entering { candidate.entryInputSourceID = entered }
            return true
        }
        guard applied else { return false }
        state = candidate
        terminalPanes = terminals
        try store.save(state)
        return true
    }
}

func remoteStatus() throws {
    let path = PluginDirectories(environment: environment).state.appendingPathComponent("remote-status.json")
    var value = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any] ?? [:]
    if let pid = value["pid"] as? Int32 { value["processAlive"] = kill(pid, 0) == 0 }
    FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]))
    FileHandle.standardOutput.write(Data("\n".utf8))
}

func runRemote(arguments: [String]) throws {
    let options = try RemoteOptions(arguments: arguments)
    guard environment["HERDR_PANE_ID"] == nil else {
        throw KeeperError.message("start ime-keeper remote from a Ghostty shell outside local Herdr")
    }
    guard isatty(STDIN_FILENO) == 1 else { throw KeeperError.message("remote requires an interactive terminal") }
    let directories = PluginDirectories(environment: environment)
    let store = try Store(directory: directories.state, key: "remote-owner")
    _ = try localInputAllowed(store: store)
    guard let surfaceID = try focusedGhosttySurface() else {
        throw KeeperError.message("start remote from the selected Ghostty terminal; its surface ID could not be determined")
    }
    let registration = try RemoteRegistration(directory: directories.state, surfaceID: surfaceID)
    defer { withExtendedLifetime(registration) {} }
    if FileManager.default.fileExists(atPath: directories.config.appendingPathComponent("config.json").path) {
        _ = try Configuration.decode(Data(contentsOf: directories.config.appendingPathComponent("config.json")))
    }
    let client = Process()
    client.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    client.arguments = [environment["HERDR_BIN_PATH"] ?? "herdr", "--remote", options.target] + options.sessionArguments
    client.standardInput = FileHandle.standardInput
    client.standardOutput = FileHandle.standardOutput
    client.standardError = FileHandle.standardError
    var clientEnv = environment
    clientEnv.removeValue(forKey: "HERDR_SOCKET_PATH")
    client.environment = clientEnv
    let bridge = RemoteBridge(options: options, directories: directories, terminalFocus: RemoteTerminalFocus(surfaceID: surfaceID))
    var terminal = termios()
    let hasTerminal = tcgetattr(STDIN_FILENO, &terminal) == 0
    let group = tcgetpgrp(STDIN_FILENO)
    let previousTTOU = signal(SIGTTOU, SIG_IGN)
    defer {
        if group > 0 { tcsetpgrp(STDIN_FILENO, group) }
        if hasTerminal { tcsetattr(STDIN_FILENO, TCSANOW, &terminal) }
        signal(SIGTTOU, previousTTOU)
    }
    try client.run()
    tcsetpgrp(STDIN_FILENO, getpgid(client.processIdentifier))
    var signals: [DispatchSourceSignal] = []
    for number in [SIGINT, SIGTERM, SIGHUP] {
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
        source.setEventHandler {
            bridge.stopSignal.stop()
            if client.isRunning { kill(client.processIdentifier, number) }
        }
        source.resume()
        signals.append(source)
    }
    defer { for source in signals { source.cancel() } }
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global().async { bridge.run(); done.signal() }
    while client.isRunning { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    bridge.stopSignal.stop()
    // Keep AppKit/TIS work on the main run loop while bounded network calls end.
    while done.wait(timeout: .now()) != .success { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    client.waitUntilExit()
    if client.terminationStatus != 0 { throw KeeperError.message("herdr exited with status \(client.terminationStatus)") }
}
