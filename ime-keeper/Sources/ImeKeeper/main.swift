import AppKit
import Carbon
import Darwin
import Foundation

private func runHerdr(_ arguments: [String], focused: Bool = false) throws -> Any {
    var childEnvironment = environment
    // pane.current otherwise resolves the inherited caller pane, not UI focus.
    if focused { childEnvironment.removeValue(forKey: "HERDR_PANE_ID") }
    let data = try runCommand(
        executable: environment["HERDR_BIN_PATH"] ?? "/opt/homebrew/bin/herdr",
        arguments: arguments, environment: childEnvironment
    )
    do { return try JSONSerialization.jsonObject(with: data) }
    catch { throw KeeperError.message("herdr \(arguments.joined(separator: " ")) returned invalid JSON: \(error)") }
}

private func currentPane() throws -> Pane {
    guard let value = responsePayload(try runHerdr(["pane", "current"], focused: true), named: "pane"),
          let paneID = value["pane_id"] as? String,
          let workspaceID = value["workspace_id"] as? String,
          let tabID = value["tab_id"] as? String else {
        throw KeeperError.message("pane.current response is missing pane_id, workspace_id, or tab_id")
    }
    return Pane(paneID: paneID, workspaceID: workspaceID, tabID: tabID)
}

private func foregroundProcesses(paneID: String) throws -> [ForegroundProcess] {
    guard let value = responsePayload(
        try runHerdr(["pane", "process-info", "--pane", paneID]),
        named: "process_info"
    ) else {
        throw KeeperError.message("pane.process-info response is not an object")
    }
    let rows = value["foreground_processes"] as? [[String: Any]] ?? []
    return rows.map { row in
        let argv0 = row["argv0"] as? String
        return ForegroundProcess(name: row["name"] as? String, argv0: argv0, pid: (row["pid"] as? NSNumber)?.int32Value)
    }
}

private func focusOnce(store: Store, departureInputSourceID: String) throws {
    let pane = try currentPane()
    let currentSource = try currentInputSourceID()
    let configuration = try loadConfiguration()
    let processes = try foregroundProcesses(paneID: pane.paneID)

    let stateLock = try FileLock(path: store.stateLockPath)
    _ = stateLock
    var state = try store.load()
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
    guard try currentPane().paneID == pane.paneID else { return }
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
            state.panes[pane.paneID] = PaneMemory(
                inputSourceID: desired,
                workspaceID: pane.workspaceID,
                tabID: pane.tabID
            )
        }
    }
    state.currentPane = pane
    state.entryInputSourceID = enteredSource
    try store.save(state)
}

private func handleFocus() throws {
    let store = try Store()
    guard let ownership = try localControlLease(store: store) else { return }
    defer { withExtendedLifetime(ownership) {} }
    try store.markDirty(inputSourceID: currentInputSourceID())
    let focusLock: FileLock
    do { focusLock = try FileLock(path: store.focusLockPath, nonblocking: true) }
    catch let error as KeeperError where error.description == "lock busy" { return }
    _ = focusLock

    while true {
        guard let signal = store.dirtySignal() else { throw KeeperError.message("focus marker is unreadable") }
        Thread.sleep(forTimeInterval: 0.1)
        guard signal == store.dirtySignal() else { continue }
        let switchLock = try FileLock(path: store.switchLockPath)
        _ = switchLock
        try focusOnce(store: store, departureInputSourceID: signal.inputSourceID)
        if signal == store.dirtySignal() { return }
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
    let lock = try FileLock(path: store.stateLockPath)
    _ = lock
    var state = try store.load()
    try mutation(&state)
    try store.save(state)
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
              let moved = data["pane"] as? [String: Any],
              let newID = moved["pane_id"] as? String,
              let workspaceID = moved["workspace_id"] as? String,
              let tabID = moved["tab_id"] as? String else { throw KeeperError.message("pane.moved is missing pane identity") }
        try mutateState { $0.movePane(from: oldID, to: Pane(paneID: newID, workspaceID: workspaceID, tabID: tabID)) }
    default: throw KeeperError.message("unsupported event \(name)")
    }
}

private func printJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    FileHandle.standardOutput.write(try encoder.encode(value))
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
    let lock = try FileLock(path: store.stateLockPath)
    _ = lock
    let state = try store.load()
    try printJSON(Status(
        configPath: try configPath().path,
        session: store.key,
        socketPath: try requireEnvironment("HERDR_SOCKET_PATH"),
        currentPane: try? currentPane(),
        currentInputSourceID: try currentInputSourceID(),
        paneMemories: state.panes,
        editors: state.editors
    ))
}

private func forgetCurrentPane() throws {
    let pane = try currentPane()
    try mutateState { $0.forgetPane(pane.paneID) }
}

private func forgetSession() throws {
    try mutateState { state in
        for paneID in Set(state.panes.keys).union(state.editors.keys) { state.forgetPane(paneID) }
    }
}

private func editorContext() throws {
    let store = try Store()
    try printJSON([
        "version": "1",
        "executable": URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path,
        "configDirectory": try configPath().deletingLastPathComponent().path,
        "stateDirectory": store.directory.path,
        "socketPath": try requireEnvironment("HERDR_SOCKET_PATH"),
        "herdrExecutable": environment["HERDR_BIN_PATH"] ?? "/opt/homebrew/bin/herdr",
        "sourceID": "local",
        "sessionID": store.key,
    ])
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
    guard let ownership = try localControlLease(store: store) else { return }
    defer { withExtendedLifetime(ownership) {} }
    let switchLock = try FileLock(path: store.switchLockPath)
    let stateLock = try FileLock(path: store.stateLockPath)
    defer { withExtendedLifetime((switchLock, stateLock)) {} }
    var state = try store.load()
    let session = EditorSession(sourceID: "local", sessionID: store.key)
    // A moved pane keeps its editor instance, even though Neovim's inherited
    // HERDR_PANE_ID still contains the old ID.
    let remembered = state.editors.values.first { $0.instanceID == event.instanceID && $0.pid == event.pid }
    let pane: Pane
    if let remembered {
        pane = remembered.pane
    } else {
        _ = try requireEnvironment("HERDR_PANE_ID")
        guard let value = responsePayload(try runHerdr(["pane", "current", "--current"]), named: "pane"),
              let paneID = value["pane_id"] as? String,
              let workspaceID = value["workspace_id"] as? String,
              let tabID = value["tab_id"] as? String else {
            throw KeeperError.message("editor pane no longer exists")
        }
        pane = Pane(paneID: paneID, workspaceID: workspaceID, tabID: tabID)
    }
    let processes = try foregroundProcesses(paneID: pane.paneID)
    guard editorIsForeground(pid: event.pid, processes: processes) else {
        let foregroundPIDs = processes.compactMap(\.pid).map(String.init).joined(separator: ", ")
        throw KeeperError.message("editor PID \(event.pid) is not the pane's foreground Neovim (foreground PIDs: \(foregroundPIDs))")
    }
    let focused = try currentPane().paneID == pane.paneID
        && (state.currentPane == nil || state.currentPane?.paneID == pane.paneID)
    let observed = focused ? try currentInputSourceID() : nil
    let previousEditor = state.editors[pane.paneID]
    let target = try state.receiveEditor(
        event, context: EditorContext(session: session, pane: pane),
        expectedSession: session, observedInputSourceID: observed
    )
    guard state.editors[pane.paneID] != previousEditor else { return }
    if let before = state.editors[pane.paneID]?.beforeInputSourceID {
        state.panes[pane.paneID] = PaneMemory(inputSourceID: before, workspaceID: pane.workspaceID, tabID: pane.tabID)
    }
    var switchError: Error?
    if let target, try currentPane().paneID == pane.paneID {
        do {
            if target != observed { try selectInputSource(target, settle: false) }
            state.editorSwitchSucceeded(paneID: pane.paneID)
            state.currentPane = pane
            state.entryInputSourceID = target
        } catch { switchError = error }
    }
    try store.save(state)
    if let switchError { throw switchError }
}

do {
    switch CommandLine.arguments.dropFirst().first {
    case "remote": try runRemote(arguments: Array(CommandLine.arguments.dropFirst(2)))
    case "remote-status": try remoteStatus()
    case "focus": try handleFocus()
    case "event": try handleEvent()
    case "status": try status()
    case "editor-context": try editorContext()
    case "editor-event": try handleEditorEvent()
    case "list-input-sources": try printJSON(inputSources().map(\.1))
    case "forget-current-pane": try forgetCurrentPane()
    case "forget-session": try forgetSession()
    default: throw KeeperError.message("usage: ime-keeper remote TARGET [--session NAME] [--remote-herdr PATH]|remote-status|focus|event|status|editor-context|editor-event JSON|list-input-sources|forget-current-pane|forget-session")
    }
} catch {
    log(String(describing: error))
    exit(1)
}
