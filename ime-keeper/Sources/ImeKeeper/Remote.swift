import AppKit
import Darwin
import Foundation

/// The reader can invalidate an in-flight query without waiting for that query.
final class RemoteInbox {
    private let lock = NSCondition()
    private var revision: UInt64 = 1
    private var stopped = false
    private var failure: String?
    private var focusAt = Date.distantPast
    private var departure: String?
    private var focusSample: UInt64 = 0
    private var focusSamplePending = false
    private var modeReceipts: [String: (RemotePaneObservation, Date)] = [:]
    private var identityRevision: UInt64 = 0

    struct View {
        let revision: UInt64
        let stopped: Bool
        let failure: String?
        let focusAt: Date
        let departure: String?
        let focusSamplePending: Bool
        let identityRevision: UInt64
    }
    func view() -> View {
        lock.lock(); defer { lock.unlock() }
        return View(revision: revision, stopped: stopped, failure: failure, focusAt: focusAt,
                    departure: departure, focusSamplePending: focusSamplePending, identityRevision: identityRevision)
    }
    // Invalidate BEFORE dispatching to the main thread. Otherwise an already
    // queued switch can run first and become the supposed departure source.
    func beginFocusSample() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        revision &+= 1
        lock.broadcast()
        identityRevision &+= 1
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
        lock.broadcast()
    }
    func invalidate(structural: Bool = false, observation: RemotePaneObservation? = nil) {
        lock.lock(); defer { lock.unlock() }
        if structural { identityRevision &+= 1; modeReceipts.removeAll() }
        if let observation {
            let previous = modeReceipts[observation.pane.paneID]?.0
            if previous?.tokens != observation.tokens {
                modeReceipts[observation.pane.paneID] = (observation, Date())
            }
        }
        revision &+= 1
        lock.broadcast()
    }
    /// Predicate and wait share the writer lock; notifications coalesce into revision.
    func wait(after revision: UInt64, until deadline: Date) {
        lock.lock(); defer { lock.unlock() }
        while self.revision == revision && !stopped && failure == nil && Date() < deadline {
            _ = lock.wait(until: deadline)
        }
    }
    func modeApplied(_ observation: RemotePaneObservation) -> Date? {
        lock.lock(); defer { lock.unlock() }
        guard let (received, at) = modeReceipts[observation.pane.paneID],
              received.pane == observation.pane, received.terminalID == observation.terminalID,
              received.tokens == observation.tokens else { return nil }
        modeReceipts.removeValue(forKey: observation.pane.paneID)
        return at
    }
    func cancelFocusObservation(preserveFocusWindow: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        focusSample &+= 1 // Reject callbacks queued before terminal ownership was lost.
        focusSamplePending = false
        departure = nil
        if !preserveFocusWindow { focusAt = .distantPast }
        modeReceipts.removeAll()
        identityRevision &+= 1
        revision &+= 1
        lock.broadcast()
    }
    func checkSubscriptionFrame(_ frame: [String: Any]) throws {
        do { try HerdrAPI.checkError(frame) }
        catch {
            fail(String(describing: error))
            throw error
        }
    }
    func consumed(_ revision: UInt64) {
        lock.lock(); defer { lock.unlock() }
        if self.revision == revision { departure = nil }
    }
    func fail(_ error: String) { lock.lock(); failure = error; revision &+= 1; lock.broadcast(); lock.unlock() }
    func stop() { lock.lock(); stopped = true; lock.broadcast(); lock.unlock() }
}

final class StopSignal {
    private let lock = NSLock()
    private var value = false
    var stopped: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func stop() { lock.lock(); value = true; lock.unlock() }
}

private struct RemoteStatus: Codable, Equatable {
    let target: String
    let session: String
    let connection: String
    let pid: Int32
    let socket: String
    let ghosttyTerminalID: String
    let state: SessionState
    let error: String?
    let focusError: String?
    let metadataErrors: [String: String]
    var metrics = RemoteMetrics()
    var processAlive: Bool? = nil
}

private func onMain<T>(_ operation: () throws -> T) rethrows -> T {
    try DispatchQueue.main.sync(execute: operation)
}

final class RemoteBridge {
    let options: RemoteOptions
    let directories: PluginDirectories
    let terminalFocus: RemoteTerminalFocus
    let stopSignal = StopSignal()
    private var state = SessionState.empty
    private var terminalPanes: [String: Pane] = [:]
    private var store: Store?
    private var remoteSocket = ""
    private var lastError: String?
    private var focusError: String?
    private var metadata = RemoteMetadata()
    private let diagnostics = RemoteDiagnostics()
    private var stateWrites = RemoteWriteCache<SessionState>()
    private var statusWrites = RemoteWriteCache<RemoteStatus>()
    private var statusSchedule = RemoteStatusSchedule()
    private var identityRevision: UInt64 = 0
    private var identityCache = RemoteIdentityCache()

    init(options: RemoteOptions, directories: PluginDirectories, terminalFocus: RemoteTerminalFocus) {
        self.options = options
        self.directories = directories
        self.terminalFocus = terminalFocus
    }

    private func status(_ connection: String) {
        var value = RemoteStatus(target: options.target, session: options.session ?? "default",
            connection: connection, pid: getpid(), socket: remoteSocket,
            ghosttyTerminalID: terminalFocus.surfaceID, state: state,
            error: lastError, focusError: focusError, metadataErrors: metadata.errors)
        let path = directories.state.appendingPathComponent("remote-status.json")
        let now = Date()
        // Business changes flush immediately; counters alone flush at most every two seconds.
        value.metrics = statusWrites.saved?.metrics ?? RemoteMetrics()
        let businessChanged = value != statusWrites.saved
        guard statusSchedule.shouldWrite(businessChanged: businessChanged, now: now) else { return }
        value.metrics = diagnostics.snapshot()
        do {
            try statusWrites.save(value) { try encodedJSON(value).write(to: path, options: .atomic) }
            statusSchedule.succeeded(at: now)
        }
        catch { log("cannot save remote status: \(error)") }
    }

    func run() {
        var retry: TimeInterval = 0.5
        while !stopSignal.stopped {
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
                identityCache.clear()
                stateWrites = RemoteWriteCache()
                lastError = nil
                metadata = RemoteMetadata()
                let inbox = RemoteInbox()
                let readerDone = DispatchSemaphore(value: 0)
                DispatchQueue.global().async {
                    defer { readerDone.signal() }
                    do {
                        var filter = RemoteEventFilter()
                        while !inbox.view().stopped && !self.stopSignal.stopped {
                            guard let event = try subscription.read(timeout: 0.2) else { continue }
                            try inbox.checkSubscriptionFrame(event)
                            let kind = (event["event"] as? String ?? "").replacingOccurrences(of: ".", with: "_")
                            let data = event["data"] as? [String: Any] ?? [:]
                            self.diagnostics.update { $0.receivedEvents += 1 }
                            guard filter.accepts(kind: kind, data: data) else {
                                self.diagnostics.update { $0.ignoredEvents += 1 }
                                continue
                            }
                            let focus = kind == "pane_focused"
                            if focus {
                                let sample = inbox.beginFocusSample()
                                let source: String? = onMain {
                                    let source = try? currentInputSourceID()
                                    return self.terminalFocus.isSelected(fresh: true) ? source : nil
                                }
                                inbox.finishFocusSample(sample, source: source)
                            } else {
                                let observation = (data["pane"] as? [String: Any]).flatMap(RemotePaneObservation.init)
                                let lifecycle = observation?.tokens["ime_keeper_event"]
                                inbox.invalidate(structural: kind != "pane_updated" || observation == nil
                                    || lifecycle == "suspend" || lifecycle == "exit", observation: observation)
                            }
                        }
                    } catch { inbox.fail(String(describing: error)) }
                }
                defer {
                    inbox.stop()
                    shutdown(subscription.fd, SHUT_RDWR)
                    _ = readerDone.wait(timeout: .now() + 1)
                }
                retry = 0.5
                try RemoteWorker(inbox: inbox, diagnostics: diagnostics,
                    wait: { inbox.wait(after: $0, until: $1) },
                    stopped: { self.stopSignal.stopped },
                    focus: {
                        let observed = onMain {
                            RemoteFocusObservation(selected: self.terminalFocus.isSelected(), error: self.terminalFocus.error)
                        }
                        self.focusError = observed.error
                        return observed
                    },
                    relinquish: {
                        self.state.relinquishInputObservation()
                        self.identityCache.clear()
                    },
                    reconcile: { view, reason in
                        try self.reconcile(api: api, ssh: ssh, inbox: inbox, view: view, reason: reason)
                    },
                    status: { observation in
                        self.status(observation.selected ? "connected" : "paused: remote Ghostty terminal is not focused")
                    }).run()
            } catch {
                lastError = String(describing: error)
                status("disconnected; retrying")
                // Do not write diagnostics over the interactive terminal.
                let deadline = Date().addingTimeInterval(retry)
                while !stopSignal.stopped && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
                retry = min(retry * 2, 8)
            }
        }
        status("stopped")
    }

    private func reconcile(api: HerdrAPI, ssh: RemoteSSH, inbox: RemoteInbox,
                           view: RemoteInbox.View, reason: RemoteQueryReason) throws -> Bool {
        guard let store else { return false }
        diagnostics.update { $0.snapshotQueries += 1 }
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
        let parsed = try rows.map { row in
            let pane = try parsePane(row)
            return (row: row, pane: pane,
                    event: metadata.parse(tokens: row["tokens"] as? [String: String] ?? [:], paneID: pane.paneID))
        }
        for (row, pane, _) in parsed {
            if let terminal = row["terminal_id"] as? String {
                terminals[terminal] = pane
                if let old = terminalPanes[terminal], old != pane { candidate.movePane(from: old.paneID, to: pane) }
            }
        }
        let ids = Set(parsed.map { $0.pane.paneID })
        metadata.retain(panes: ids)
        for id in Set(candidate.panes.keys).union(candidate.editors.keys) where !ids.contains(id) { candidate.closePane(id) }
        let focused = parsed.first { $0.pane.paneID == focusedID }
        let focusedRow = focused?.row
        let pane = focused?.pane
        let entering = candidate.currentPane?.paneID != focusedID
        let observed: String? = try onMain { terminalFocus.isSelected(fresh: true) ? try currentInputSourceID() : nil }
        if entering, let source = view.departure ?? observed {
            // A focus event can still arrive after another app became active.
            if observed != nil { candidate.rememberLeavingPane(currentInputSourceID: source) }
        }
        let session = EditorSession(sourceID: "ssh:" + options.target, sessionID: store.key)
        // Background panes update mode caches without sampling the global IME.
        for (_, background, event) in parsed where background.paneID != focusedID {
            if let event {
                _ = try candidate.receiveRemoteEditor(event, pane: background, session: session, observed: nil)
            } else { _ = candidate.releaseRemoteEditor(paneID: background.paneID) }
        }
        guard let row = focusedRow, let pane else {
            candidate.currentPane = nil
            identityCache.clear()
            state = candidate
            terminalPanes = terminals
            try stateWrites.save(state) { try store.save(state) }
            return true
        }
        let config = try loadConfiguration(directory: directories.config)
        guard let observation = RemotePaneObservation(row) else {
            throw KeeperError.message("invalid remote pane observation")
        }
        let event = focused?.event
        let queryReason: RemoteQueryReason = reason == .health ? .health : entering ? .focus : reason
        if reason != .event || entering || event == nil || identityRevision != view.identityRevision
            || event?.event == .exit || event?.event == .suspend {
            identityCache.clear()
        }
        identityRevision = view.identityRevision
        var processes: [ForegroundProcess] = []
        if remoteNeedsProcesses(event: event, entering: entering,
                                saved: candidate.panes[pane.paneID], rules: config.rules) {
            diagnostics.update { $0.processQueries += 1 }
            let processResult = try api.request("pane.process_info", ["pane_id": pane.paneID])
            guard let info = processResult["process_info"] as? [String: Any] else {
                throw KeeperError.message("Herdr process response is missing process_info")
            }
            processes = parseProcesses(info)
        }
        var desired = entering ? desiredInputSource(saved: candidate.panes[pane.paneID],
            ruleInputSourceID: matchingInputSource(rules: config.rules, processes: processes)) : nil
        var valid = false
        if let event {
            valid = editorIsForeground(pid: event.pid, processes: processes) { pid in
                let key = "\(pane.workspaceID):\(pane.tabID):\(pane.paneID):\(observation.terminalID):\(event.instanceID):\(pid)"
                return self.identityCache.identity(key: key, onHit: {
                    self.diagnostics.update { $0.identityCacheHits += 1 }
                }) {
                    let started = Date()
                    defer {
                        self.diagnostics.update {
                            $0.identityQueries += 1
                            $0.identityQueriesByReason[queryReason.rawValue, default: 0] += 1
                            $0.identityQueryTotalMsByReason[queryReason.rawValue, default: 0] += Date().timeIntervalSince(started) * 1000
                        }
                    }
                    return ssh.identity(pid: pid)
                }
            }
            if !valid { identityCache.clear() }
            // Exit/suspend may arrive after the editor relinquishes foreground.
            if !valid, event.event == .exit || event.event == .suspend,
               let previous = candidate.editors[pane.paneID], previous.instanceID == event.instanceID,
               previous.pid == event.pid { valid = true }
        }
        desired = try candidate.remoteFocusTarget(event: event, verified: valid, pane: pane, session: session,
                                                   entering: entering, observed: observed, ordinaryTarget: desired)
        // Revalidate focus and metadata after process queries; never apply an
        // old snapshot over a newer mode or a focus event received meanwhile.
        diagnostics.update { $0.currentQueries += 1 }
        let currentResult = try api.request("pane.current")
        guard let current = currentResult["pane"] as? [String: Any],
              current["pane_id"] as? String == pane.paneID,
              RemotePaneObservation(current) == observation,
              inbox.view().revision == view.revision, inbox.view().failure == nil else { return false }
        let applied = try onMain { () -> Bool in
            guard !self.stopSignal.stopped, inbox.view().revision == view.revision else { return false }
            return try FileLock.with(path: store.switchLockPath) {
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
                        if let event, valid, candidate.editors[pane.paneID]?.appliedMode == event.mode,
                           let received = inbox.modeApplied(observation) {
                            self.diagnostics.update {
                                $0.appliedModeEvents += 1
                                $0.lastModeApplyMs = Date().timeIntervalSince(received) * 1000
                            }
                        }
                        entered = desired
                        self.lastError = nil
                        if candidate.editors[pane.paneID]?.lifecycle != .active, candidate.panes[pane.paneID] == nil {
                            candidate.panes[pane.paneID] = PaneMemory(desired, pane: pane)
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
        }
        guard applied else { return false }
        state = candidate
        terminalPanes = terminals
        try stateWrites.save(state) { try store.save(state) }
        return true
    }
}

func remoteStatus() throws {
    let path = PluginDirectories(environment: environment).state.appendingPathComponent("remote-status.json")
    var value = try JSONDecoder().decode(RemoteStatus.self, from: Data(contentsOf: path))
    value.processAlive = kill(value.pid, 0) == 0
    FileHandle.standardOutput.write(try encodedJSON(value))
    FileHandle.standardOutput.write(Data("\n".utf8))
}

func runRemote(arguments: [String]) throws {
    let options = try RemoteOptions(arguments: arguments)
    guard environment["HERDR_PANE_ID"] == nil else {
        throw KeeperError.message("start ime-keeper remote from a Ghostty shell outside local Herdr")
    }
    guard isatty(STDIN_FILENO) == 1 else { throw KeeperError.message("remote requires an interactive terminal") }
    let directories = PluginDirectories(environment: environment)
    try FileManager.default.createDirectory(at: directories.state, withIntermediateDirectories: true)
    guard let surfaceID = try focusedGhosttySurface() else {
        throw KeeperError.message("start remote from the selected Ghostty terminal; its surface ID could not be determined")
    }
    let registration = try RemoteRegistration(directory: directories.state, surfaceID: surfaceID)
    defer { withExtendedLifetime(registration) {} }
    _ = try loadConfiguration(directory: directories.config)
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
