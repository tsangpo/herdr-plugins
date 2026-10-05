import Foundation
import Testing
@testable import ImeKeeper

private let pane = Pane(paneID: "p", workspaceID: "w", tabID: "t")
private let session = EditorSession(sourceID: "local", sessionID: "session")
private let context = EditorContext(session: session, pane: pane)
private let abc = EditorMemory.commandInputSourceID

private func event(_ sequence: UInt64, _ kind: EditorEventKind, _ mode: EditorMode = .command, instance: String = "nvim-1") -> EditorEvent {
    EditorEvent(version: 1, instanceID: instance, pid: 123, sequence: sequence, event: kind, mode: mode)
}

private func receive(_ state: inout SessionState, _ event: EditorEvent, _ source: String?) throws -> String? {
    try state.receiveEditor(event, context: context, expectedSession: session, observedInputSourceID: source)
}

@Test func modeTransitionsRememberManualEditingChangesWithoutSavingABC() throws {
    var state = SessionState.empty
    #expect(try receive(&state, event(1, .start), "Pinyin") == abc)
    state.editorSwitchSucceeded(paneID: "p")
    #expect(try receive(&state, event(2, .mode, .edit), abc) == "Pinyin")
    state.editorSwitchSucceeded(paneID: "p")
    #expect(try receive(&state, event(3, .mode), "Japanese") == abc)
    state.editorSwitchSucceeded(paneID: "p")
    #expect(try receive(&state, event(4, .snapshot), abc) == abc)
    #expect(state.editors["p"]?.editingInputSourceID == "Japanese")
    #expect(try receive(&state, event(5, .mode, .edit), abc) == "Japanese")
    state.editorSwitchSucceeded(paneID: "p")
    #expect(try receive(&state, event(6, .exit), "Japanese") == "Pinyin")
}

@Test func failedEditingRestoreDoesNotReplaceMemoryWithABC() throws {
    var state = SessionState.empty
    _ = try receive(&state, event(1, .start), "Pinyin")
    state.editorSwitchSucceeded(paneID: "p")
    _ = try receive(&state, event(2, .mode, .edit), abc)
    // No success acknowledgement: TIS failed and physical source is still ABC.
    _ = try receive(&state, event(3, .mode), abc)
    #expect(state.editors["p"]?.editingInputSourceID == "Pinyin")
    #expect(try receive(&state, event(4, .mode, .edit), abc) == "Pinyin")
}

@Test func backgroundSnapshotsNeverCaptureAnotherPanesSource() throws {
    var state = SessionState.empty
    #expect(try receive(&state, event(1, .start), nil) == nil)
    #expect(state.editors["p"]?.beforeInputSourceID == nil)
    #expect(try receive(&state, event(2, .mode, .edit), nil) == nil)
    #expect(state.editors["p"]?.editingInputSourceID == nil)
    #expect(state.editors["p"]?.targetOnFocus(baseInputSourceID: "Pinyin") == "Pinyin")
    state.editorSwitchSucceeded(paneID: "p")
    state.currentPane = pane
    state.rememberLeavingPane(currentInputSourceID: "Japanese")
    #expect(state.editors["p"]?.editingInputSourceID == "Japanese")
    #expect(state.panes.isEmpty)
}

@Test func failedExitRestoreDoesNotSaveForcedABCAsShellMemory() throws {
    var state = SessionState.empty
    state.currentPane = pane
    state.panes["p"] = PaneMemory(inputSourceID: "Pinyin", workspaceID: "w", tabID: "t")
    _ = try receive(&state, event(1, .start), "Pinyin")
    state.editorSwitchSucceeded(paneID: "p")
    #expect(try receive(&state, event(2, .exit), abc) == "Pinyin")
    // Restoration failed: do not acknowledge it and do not remember forced ABC.
    state.rememberLeavingPane(currentInputSourceID: abc)
    #expect(state.panes["p"]?.inputSourceID == "Pinyin")
}

@Test func duplicateOutOfOrderAndPostExitEventsAreIgnored() throws {
    var state = SessionState.empty
    _ = try receive(&state, event(1, .start), "Pinyin")
    _ = try receive(&state, event(3, .mode, .edit), abc)
    let accepted = state
    #expect(try receive(&state, event(3, .mode), "wrong") == nil)
    #expect(try receive(&state, event(2, .mode), "wrong") == nil)
    #expect(state == accepted)
    _ = try receive(&state, event(4, .exit), "Pinyin")
    let exited = state
    #expect(try receive(&state, event(5, .snapshot), "wrong") == nil)
    #expect(state == exited)
    #expect(try receive(&state, event(1, .start, instance: "new-instance"), "Japanese") == abc)
}

@Test func backgroundTransitionBeforeDebouncedFocusKeepsDepartureMemory() throws {
    var state = SessionState.empty
    state.currentPane = pane
    _ = try receive(&state, event(1, .start, .edit), "Pinyin")
    state.editorSwitchSucceeded(paneID: "p")
    _ = try receive(&state, event(2, .mode), nil)
    state.rememberLeavingPane(currentInputSourceID: "Japanese")
    #expect(state.editors["p"]?.editingInputSourceID == "Japanese")
    #expect(state.editors["p"]?.appliedMode == nil)
    #expect(state.panes.isEmpty)

    // Exiting in the background must not promote the previously forced ABC to
    // ordinary shell memory before the focus worker processes departure.
    _ = try receive(&state, event(3, .snapshot), "Japanese")
    state.editorSwitchSucceeded(paneID: "p")
    state.panes["p"] = PaneMemory(inputSourceID: "Pinyin", workspaceID: "w", tabID: "t")
    _ = try receive(&state, event(4, .exit), nil)
    state.rememberLeavingPane(currentInputSourceID: abc)
    #expect(state.panes["p"]?.inputSourceID == "Pinyin")
}

@Test func suspendAndResumePreserveEditingMemoryAndTrackShellSource() throws {
    var state = SessionState.empty
    _ = try receive(&state, event(1, .start, .edit), "Pinyin")
    state.editorSwitchSucceeded(paneID: "p")
    #expect(try receive(&state, event(2, .suspend), "Japanese") == "Pinyin")
    #expect(state.editors["p"]?.lifecycle == .suspended)
    #expect(try receive(&state, event(3, .mode), "Korean") == nil)
    #expect(try receive(&state, event(4, .resume, .edit), "Korean") == "Japanese")
    #expect(state.editors["p"]?.beforeInputSourceID == "Korean")
    #expect(try receive(&state, event(5, .exit), "Japanese") == "Korean")
}

@Test func sourceNamespacesAndSnapshotRecoveryAreIsolated() throws {
    var state = SessionState.empty
    let remoteSession = EditorSession(sourceID: "ssh:workbox", sessionID: "session")
    let remoteContext = EditorContext(session: remoteSession, pane: pane)
    let snapshot = event(10, .snapshot, .edit)
    #expect(try state.receiveEditor(snapshot, context: remoteContext, expectedSession: session, observedInputSourceID: "Pinyin") == nil)
    #expect(state.editors.isEmpty)
    #expect(try state.receiveEditor(snapshot, context: remoteContext, expectedSession: remoteSession, observedInputSourceID: nil) == nil)
    #expect(state.editors["p"]?.session == remoteSession)
    #expect(state.editors["p"]?.targetOnFocus(baseInputSourceID: "Pinyin") == "Pinyin")
    let recovered = state
    _ = try state.receiveEditor(event(9, .mode), context: remoteContext, expectedSession: remoteSession, observedInputSourceID: "wrong")
    #expect(state == recovered)
}

@Test func editorMemoriesFollowPaneMovesAndCleanup() throws {
    var state = SessionState.empty
    _ = try receive(&state, event(1, .start), "Pinyin")
    let moved = Pane(paneID: "new", workspaceID: "w2", tabID: "t2")
    state.movePane(from: "p", to: moved)
    #expect(state.editors["p"] == nil)
    #expect(state.editors["new"]?.pane == moved)
    state.forgetPane("new")
    #expect(state.editors["new"]?.beforeInputSourceID == nil)
    #expect(state.editors["new"]?.editingInputSourceID == nil)
    #expect(state.editors["new"]?.sequence == 1)
    var tabCopy = state, workspaceCopy = state
    state.closePane("new")
    tabCopy.closeTab("t2")
    workspaceCopy.closeWorkspace("w2")
    #expect(state.editors.isEmpty && tabCopy.editors.isEmpty && workspaceCopy.editors.isEmpty)
}

@Test func oldStateAndNewStateRoundTrip() throws {
    let old = Data(#"{"panes":{},"currentPane":null,"entryInputSourceID":null}"#.utf8)
    var state = try JSONDecoder().decode(SessionState.self, from: old)
    #expect(state == .empty)
    _ = try receive(&state, event(1, .start), "Pinyin")
    #expect(try JSONDecoder().decode(SessionState.self, from: JSONEncoder().encode(state)) == state)
    #expect(throws: (any Error).self) {
        try JSONDecoder().decode(SessionState.self, from: Data(#"{"panes":{},"editors":{"p":{}}}"#.utf8))
    }
}

@Test func malformedEditorEventsFailWithoutMutatingState() throws {
    var state = SessionState.empty
    let invalid = EditorEvent(version: 2, instanceID: "x", pid: 1, sequence: 1, event: .start, mode: .command)
    #expect(throws: (any Error).self) { try receive(&state, invalid, "Pinyin") }
    #expect(state == .empty)
}

@Test func commandRunnerDrainsBothStreamsAndBoundsExecution() throws {
    let output = try runCommand(executable: "/bin/sh", arguments: ["-c", "i=0; while [ $i -lt 3000 ]; do echo 'stdout payload payload payload'; echo 'stderr payload payload payload' >&2; i=$((i+1)); done"], environment: [:], timeout: 3)
    #expect(output.count > 65536)
    #expect(throws: (any Error).self) {
        try runCommand(executable: "/bin/sleep", arguments: ["5"], environment: [:], timeout: 0.05)
    }
    #expect(throws: (any Error).self) {
        try runCommand(executable: "/bin/sh", arguments: ["-c", "echo failure >&2; exit 7"], environment: [:])
    }
}
