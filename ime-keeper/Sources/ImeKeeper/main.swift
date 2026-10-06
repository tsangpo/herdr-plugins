import AppKit
import Carbon
import Darwin
import Foundation

private func localAPI() throws -> HerdrAPI {
    HerdrAPI(path: try requireEnvironment("HERDR_SOCKET_PATH"), deadline: Date().addingTimeInterval(1))
}

private func focusOnce(store: Store, departureInputSourceID: String) throws {
    guard try localInputAllowed(store: store) else { return }
    let api = try localAPI()
    let pane = try api.currentPane()
    let currentSource = try currentInputSourceID()
    let configuration = try loadConfiguration()
    let processes = try api.foregroundProcesses(paneID: pane.paneID)

    try FileLock.with(path: store.stateLockPath) {
        var state = try store.load()
        let owner = InputOwner(directory: store.directory)
        if !owner.isCurrent(store.ownerID) { state.relinquishInputObservation() }
        if state.currentPane?.paneID != pane.paneID {
            state.rememberLeavingPane(currentInputSourceID: departureInputSourceID)
        }
        var desired = desiredInputSource(
            saved: state.panes[pane.paneID],
            ruleInputSourceID: matchingInputSource(rules: configuration.rules, processes: processes)
        )
        var hasActiveEditor = false
        if let editor = state.editors[pane.paneID], editor.lifecycle == .active {
            if editorIsForeground(pid: editor.pid, processes: processes) {
                hasActiveEditor = true
                // A same-pane focus snapshot must preserve a manual editing change.
                if state.currentPane?.paneID == pane.paneID {
                    state.editors[pane.paneID]?.rememberEditingSource(currentSource)
                }
                desired = state.editors[pane.paneID]?.targetOnFocus(baseInputSourceID: desired ?? currentSource)
            } else if kill(editor.pid, 0) != 0 && errno == ESRCH {
                // An ungraceful editor exit must not leave ABC as shell memory.
                desired = editor.beforeInputSourceID ?? desired
                state.editors.removeValue(forKey: pane.paneID)
            } else {
                state.editors[pane.paneID]?.lifecycle = .suspended
                state.editors[pane.paneID]?.appliedMode = nil
            }
        }
        guard try api.currentPane().paneID == pane.paneID, try localInputAllowed(store: store) else { return }
        var enteredSource = currentSource
        if let desired {
            if desired != currentSource {
                do {
                    try selectInputSource(desired, settle: !hasActiveEditor)
                    enteredSource = desired
                } catch { log(String(describing: error)) }
            }
            if enteredSource == desired {
                state.editorSwitchSucceeded(paneID: pane.paneID)
            }
            if enteredSource == desired, state.panes[pane.paneID] == nil, !hasActiveEditor {
                state.panes[pane.paneID] = PaneMemory(desired, pane: pane)
            }
        }
        try owner.claim(store.ownerID)
        state.currentPane = pane
        state.entryInputSourceID = enteredSource
        try store.save(state)
    }
}

private func handleFocus() throws {
    let store = try Store()
    guard try localInputAllowed(store: store) else { return }
    try store.markDirty(inputSourceID: currentInputSourceID())
    guard let focusLock = try FileLock.tryAcquire(path: store.focusLockPath) else { return }
    defer { withExtendedLifetime(focusLock) {} }

    while true {
        guard let signal = store.dirtySignal() else { throw KeeperError.message("focus marker is unreadable") }
        Thread.sleep(forTimeInterval: 0.1)
        guard signal == store.dirtySignal() else { continue }
        let finished = try FileLock.with(path: store.switchLockPath) {
            try focusOnce(store: store, departureInputSourceID: signal.inputSourceID)
            return signal == store.dirtySignal()
        }
        if finished { return }
    }
}

private func eventData() throws -> [String: Any] {
    guard let raw = environment["HERDR_PLUGIN_EVENT_JSON"],
          let data = raw.data(using: .utf8),
          let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let value = envelope["data"] as? [String: Any] else {
        throw KeeperError.message("HERDR_PLUGIN_EVENT_JSON is missing valid event data")
    }
    return value
}

private func mutateState(_ mutation: (inout SessionState) throws -> Void) throws {
    let store = try Store()
    try FileLock.with(path: store.stateLockPath) {
        var state = try store.load()
        try mutation(&state)
        try store.save(state)
    }
}

private func handleEvent() throws {
    let name = try requireEnvironment("HERDR_PLUGIN_EVENT")
    if name == "pane.focused" { try handleFocus(); return }
    let data = try eventData()
    switch name {
    case "pane.closed":
        guard let id = data["pane_id"] as? String else { throw KeeperError.message("pane.closed is missing pane_id") }
        try mutateState { $0.closePane(id) }
    case "tab.closed":
        guard let id = data["tab_id"] as? String else { throw KeeperError.message("tab.closed is missing tab_id") }
        try mutateState { $0.closeTab(id) }
    case "workspace.closed":
        guard let id = data["workspace_id"] as? String else { throw KeeperError.message("workspace.closed is missing workspace_id") }
        try mutateState { $0.closeWorkspace(id) }
    case "pane.moved":
        guard let oldID = data["previous_pane_id"] as? String,
              let moved = data["pane"] as? [String: Any] else { throw KeeperError.message("pane.moved is missing pane identity") }
        let pane = try parsePane(moved)
        try mutateState { $0.movePane(from: oldID, to: pane) }
    default: throw KeeperError.message("unsupported event \(name)")
    }
}

private func printJSON<T: Encodable>(_ value: T) throws {
    FileHandle.standardOutput.write(try encodedJSON(value))
    FileHandle.standardOutput.write(Data("\n".utf8))
}

private struct Status: Encodable {
    let configPath: String
    let session: String
    let socketPath: String
    let currentPane: Pane?
    let currentInputSourceID: String
    let paneMemories: [String: PaneMemory]
    let editors: [String: EditorMemory]
}

private func status() throws {
    let store = try Store()
    try FileLock.with(path: store.stateLockPath) {
        let state = try store.load()
        try printJSON(Status(
            configPath: configPath().path,
            session: store.key,
            socketPath: try requireEnvironment("HERDR_SOCKET_PATH"),
            currentPane: try? localAPI().currentPane(),
            currentInputSourceID: try currentInputSourceID(),
            paneMemories: state.panes,
            editors: state.editors
        ))
    }
}

private func forgetCurrentPane() throws {
    let pane = try localAPI().currentPane()
    try mutateState { $0.forgetPane(pane.paneID) }
}

private func forgetSession() throws {
    try mutateState { state in
        for paneID in Set(state.panes.keys).union(state.editors.keys) { state.forgetPane(paneID) }
    }
}

private func handleEditorEvent() throws {
    // JSON is passed as one argv element; neither the Lua nor Swift adapter uses a shell.
    guard CommandLine.arguments.count == 3,
          let data = CommandLine.arguments[2].data(using: .utf8), data.count <= 4096 else {
        throw KeeperError.message("editor-event requires one JSON argument (at most 4096 bytes)")
    }
    let event = try JSONDecoder().decode(EditorEvent.self, from: data)
    try event.validate()
    _ = try loadConfiguration()
    let store = try Store()
    try FileLock.with(path: store.switchLockPath) {
        try FileLock.with(path: store.stateLockPath) {
            let api = try localAPI()
            var state = try store.load()
            let session = EditorSession(sourceID: "local", sessionID: store.key)
            let mayControl = try localInputAllowed(store: store)
            let owner = InputOwner(directory: store.directory)
            if !mayControl || !owner.isCurrent(store.ownerID) { state.relinquishInputObservation() }
            // A moved pane keeps its editor instance, even though Neovim's inherited
            // HERDR_PANE_ID still contains the old ID.
            let remembered = state.editors.values.first { $0.instanceID == event.instanceID && $0.pid == event.pid }
            let pane: Pane
            if let remembered {
                pane = remembered.pane
            } else {
                pane = try api.currentPane(callerPaneID: requireEnvironment("HERDR_PANE_ID"))
            }
            let processes = try api.foregroundProcesses(paneID: pane.paneID)
            guard editorIsForeground(pid: event.pid, processes: processes) else {
                let foregroundPIDs = processes.compactMap(\.pid).map(String.init).joined(separator: ", ")
                throw KeeperError.message("editor PID \(event.pid) is not the pane's foreground Neovim (foreground PIDs: \(foregroundPIDs))")
            }
            let focused = try mayControl && api.currentPane().paneID == pane.paneID
                && (state.currentPane == nil || state.currentPane?.paneID == pane.paneID)
            let observed = focused ? try currentInputSourceID() : nil
            let previousState = state
            let previousEditor = state.editors[pane.paneID]
            let target = try state.receiveEditor(
                event, session: session, pane: pane, observedInputSourceID: observed
            )
            guard state.editors[pane.paneID] != previousEditor else { return }
            if let before = state.editors[pane.paneID]?.beforeInputSourceID {
                state.panes[pane.paneID] = PaneMemory(before, pane: pane)
            }
            var switchError: Error?
            if let target, try api.currentPane().paneID == pane.paneID {
                guard try localInputAllowed(store: store) else {
                    state = previousState
                    state.relinquishInputObservation()
                    _ = try state.receiveEditor(event, session: session, pane: pane, observedInputSourceID: nil)
                    try store.save(state)
                    return
                }
                do {
                    if target != observed { try selectInputSource(target, settle: false) }
                    state.editorSwitchSucceeded(paneID: pane.paneID)
                    try owner.claim(store.ownerID)
                    state.currentPane = pane
                    state.entryInputSourceID = target
                } catch { switchError = error }
            }
            try store.save(state)
            if let switchError { throw switchError }
        }
    }
}

do {
    switch CommandLine.arguments.dropFirst().first {
    case "remote": try runRemote(arguments: Array(CommandLine.arguments.dropFirst(2)))
    case "remote-status": try remoteStatus()
    case "focus": try handleFocus()
    case "event": try handleEvent()
    case "status": try status()
    case "editor-event": try handleEditorEvent()
    case "list-input-sources": try printJSON(inputSources().map(\.1))
    case "forget-current-pane": try forgetCurrentPane()
    case "forget-session": try forgetSession()
    default: throw KeeperError.message("usage: ime-keeper remote TARGET [--session NAME] [--remote-herdr PATH]|remote-status|focus|event|status|editor-event JSON|list-input-sources|forget-current-pane|forget-session")
    }
} catch {
    log(String(describing: error))
    exit(1)
}
