import Foundation

struct RemoteOptions: Equatable {
    let target: String
    var session: String?
    var herdr = "herdr"

    init(arguments: [String]) throws {
        guard let target = arguments.first, !target.isEmpty, !target.hasPrefix("-"),
              !target.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            throw KeeperError.message("usage: ime-keeper remote SSH_TARGET [--session NAME] [--remote-herdr PATH]")
        }
        self.target = target
        var index = 1
        while index < arguments.count {
            guard index + 1 < arguments.count, !arguments[index + 1].isEmpty else {
                throw KeeperError.message("missing value for \(arguments[index])")
            }
            switch arguments[index] {
            case "--session": session = arguments[index + 1]
            case "--remote-herdr": herdr = arguments[index + 1]
            default: throw KeeperError.message("unknown remote option \(arguments[index])")
            }
            index += 2
        }
    }

    var sessionArguments: [String] { session.map { ["--session", $0] } ?? [] }
    func namespace(socket: String) -> String {
        sessionKey("remote\u{0}\(target)\u{0}\(session ?? "")\u{0}\(socket)")
    }
}

func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

func remoteEditorEvent(tokens: [String: String]) throws -> EditorEvent? {
    guard tokens.keys.contains(where: { $0.hasPrefix("ime_keeper_") }) else { return nil }
    func field(_ key: String) throws -> String {
        guard let value = tokens["ime_keeper_" + key], !value.isEmpty, value.utf8.count <= 80 else {
            throw KeeperError.message("incomplete or oversized editor metadata: \(key)")
        }
        return value
    }
    guard let version = Int(try field("version")), let pid = Int32(try field("pid")),
          let sequence = UInt64(try field("sequence")),
          let kind = EditorEventKind(rawValue: try field("event")),
          let mode = EditorMode(rawValue: try field("mode")) else {
        throw KeeperError.message("invalid editor metadata")
    }
    let event = EditorEvent(version: version, instanceID: try field("instance"), pid: pid,
                            sequence: sequence, event: kind, mode: mode)
    try event.validate()
    return event
}

func remotePane(_ value: [String: Any]) throws -> Pane {
    guard let pane = value["pane_id"] as? String, let workspace = value["workspace_id"] as? String,
          let tab = value["tab_id"] as? String else { throw KeeperError.message("invalid remote pane identity") }
    return Pane(paneID: pane, workspaceID: workspace, tabID: tab)
}

func remoteProcesses(_ value: [String: Any]) -> [ForegroundProcess] {
    let rows = value["foreground_processes"] as? [[String: Any]] ?? []
    return rows.map {
        ForegroundProcess(name: $0["name"] as? String,
                          argv0: ($0["argv0"] as? String) ?? ($0["argv"] as? [String])?.first,
                          pid: ($0["pid"] as? NSNumber)?.int32Value)
    }
}

func remoteNeedsProcesses(event: EditorEvent?, entering: Bool, saved: PaneMemory?, rules: [Rule]) -> Bool {
    event != nil || (entering && saved == nil && !rules.isEmpty)
}

extension SessionState {
    /// A manual choice made while a remote restore is in flight belongs to the
    /// destination pane. Commit it instead of overwriting it or sampling it as
    /// the departure pane's preference. Active editors retain their mode policy.
    mutating func acceptRemoteManualSource(pane: Pane, baseline: String?, current: String) -> Bool {
        guard let baseline, baseline != current, editors[pane.paneID]?.lifecycle != .active else { return false }
        panes[pane.paneID] = PaneMemory(inputSourceID: current, workspaceID: pane.workspaceID, tabID: pane.tabID)
        return true
    }
}

extension SessionState {
    /// Metadata is a current-state snapshot. A subscriber may first encounter
    /// an instance on a mode event after startup, so bootstrap active instances.
    mutating func receiveRemoteEditor(_ event: EditorEvent, pane: Pane, session: EditorSession,
                                     observed: String?) throws -> String? {
        var incoming = event
        if let previous = editors[pane.paneID], previous.instanceID == event.instanceID,
           previous.pid == event.pid, previous.session == session,
           previous.lifecycle == .suspended, event.sequence >= previous.sequence,
           event.event != .exit && event.event != .suspend && event.event != .resume {
            // A renewed lease can contain the same sequence as the last report.
            // Keep editing memory while inactive, and re-arm only after the
            // transport has revalidated foreground ownership before applying.
            editors[pane.paneID]?.lifecycle = .active
            if let observed { editors[pane.paneID]?.beforeInputSourceID = observed }
        }
        if editors[pane.paneID]?.instanceID != event.instanceID,
           event.event != .exit && event.event != .suspend {
            incoming = EditorEvent(version: event.version, instanceID: event.instanceID, pid: event.pid,
                                   sequence: event.sequence, event: .snapshot, mode: event.mode)
        }
        return try receiveEditor(incoming, context: EditorContext(session: session, pane: pane),
                                 expectedSession: session, observedInputSourceID: observed)
    }

    mutating func releaseRemoteEditor(paneID: String) -> String? {
        guard let editor = editors[paneID] else { return nil }
        let pending = editor.lifecycle == .active || editor.appliedMode != nil
        if pending, let before = editor.beforeInputSourceID {
            panes[paneID] = PaneMemory(inputSourceID: before, workspaceID: editor.pane.workspaceID,
                                      tabID: editor.pane.tabID)
        }
        if editor.lifecycle != .exited { editors[paneID]?.lifecycle = .suspended }
        // Retain dormant identity and memories for a verified resume, but do
        // not repeatedly overwrite a manual shell choice after restoring once.
        return pending ? editor.beforeInputSourceID : nil
    }
}

extension SessionState {
    mutating func remoteFocusTarget(event: EditorEvent?, verified: Bool, pane: Pane,
                                    session: EditorSession, entering: Bool, observed: String?,
                                    ordinaryTarget: String?) throws -> String? {
        var desired = ordinaryTarget
        if let event, verified {
            let previous = editors[pane.paneID]
            let target = try receiveRemoteEditor(event, pane: pane, session: session,
                                                 observed: entering ? nil : observed)
            if let target { desired = target }
            if editors[pane.paneID]?.lifecycle == .active {
                if let observed, entering || editors[pane.paneID]?.appliedMode != editors[pane.paneID]?.mode {
                    desired = editors[pane.paneID]?.targetOnFocus(baseInputSourceID: desired ?? observed)
                }
            } else if editors[pane.paneID]?.appliedMode != nil {
                desired = editors[pane.paneID]?.beforeInputSourceID ?? desired
            }
            if previous != editors[pane.paneID], let before = editors[pane.paneID]?.beforeInputSourceID {
                panes[pane.paneID] = PaneMemory(inputSourceID: before, workspaceID: pane.workspaceID, tabID: pane.tabID)
            }
        } else {
            if !entering, let observed { editors[pane.paneID]?.rememberEditingSource(observed) }
            desired = releaseRemoteEditor(paneID: pane.paneID) ?? desired
        }
        return desired
    }
}
