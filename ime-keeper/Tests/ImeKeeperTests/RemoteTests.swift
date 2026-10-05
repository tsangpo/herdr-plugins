import Darwin
import Foundation
import Testing
@testable import ImeKeeper

private func tokens(sequence: UInt64 = 1, instance: String = "nvim-1", event: String = "mode", mode: String = "command") -> [String: String] {
    ["ime_keeper_version": "1", "ime_keeper_instance": instance, "ime_keeper_pid": "123",
     "ime_keeper_sequence": String(sequence), "ime_keeper_event": event, "ime_keeper_mode": mode]
}

@Test func remoteMetadataValidatesCompleteAtomicState() throws {
    #expect(try remoteEditorEvent(tokens: [:]) == nil)
    #expect(try remoteEditorEvent(tokens: ["other_plugin": "ok"]) == nil)
    let event = try #require(try remoteEditorEvent(tokens: tokens()))
    #expect(event.mode == .command && event.sequence == 1 && event.pid == 123)
    for replacement in [["ime_keeper_mode": "insert"], ["ime_keeper_pid": "-1"],
                        ["ime_keeper_version": "2"], ["ime_keeper_sequence": "0"],
                        ["ime_keeper_instance": String(repeating: "a", count: 81)]] {
        #expect(throws: Error.self) { try remoteEditorEvent(tokens: tokens().merging(replacement) { _, new in new }) }
    }
    #expect(throws: Error.self) { try remoteEditorEvent(tokens: ["ime_keeper_mode": "edit"]) }
}

@Test func remoteInstancesBootstrapFromModeAndKeepIndependentMemories() throws {
    let a = Pane(paneID: "w:p1", workspaceID: "w", tabID: "t")
    let b = Pane(paneID: "w:p2", workspaceID: "w", tabID: "t")
    let session = EditorSession(sourceID: "ssh:host", sessionID: "s")
    var state = SessionState.empty
    let startA = try #require(try remoteEditorEvent(tokens: tokens()))
    #expect(try state.receiveRemoteEditor(startA, pane: a, session: session, observed: "pinyin") == EditorMemory.commandInputSourceID)
    state.editorSwitchSucceeded(paneID: a.paneID)
    let startB = try #require(try remoteEditorEvent(tokens: tokens(instance: "nvim-2", mode: "edit")))
    #expect(try state.receiveRemoteEditor(startB, pane: b, session: session, observed: nil) == nil)
    #expect(state.editors[b.paneID]?.beforeInputSourceID == nil)
    #expect(state.editors[a.paneID]?.editingInputSourceID == "pinyin")
    let edit = try #require(try remoteEditorEvent(tokens: tokens(sequence: 2, mode: "edit")))
    #expect(try state.receiveRemoteEditor(edit, pane: a, session: session, observed: EditorMemory.commandInputSourceID) == "pinyin")
    #expect(try state.receiveRemoteEditor(startA, pane: a, session: session, observed: "wrong") == nil)
    #expect(state.editors[a.paneID]?.editingInputSourceID == "pinyin")
    #expect(state.releaseRemoteEditor(paneID: a.paneID) == "pinyin")
    #expect(state.panes[a.paneID]?.inputSourceID == "pinyin")
    #expect(state.editors[b.paneID] != nil)
}

@Test func remoteExitUsesShellMemoryRatherThanEditingMemory() throws {
    let pane = Pane(paneID: "p", workspaceID: "w", tabID: "t")
    let session = EditorSession(sourceID: "ssh:h", sessionID: "s")
    var state = SessionState.empty
    _ = try state.receiveRemoteEditor(#require(try remoteEditorEvent(tokens: tokens(mode: "edit"))), pane: pane, session: session, observed: "shell-source")
    state.editorSwitchSucceeded(paneID: pane.paneID)
    _ = try state.receiveRemoteEditor(#require(try remoteEditorEvent(tokens: tokens(sequence: 2))), pane: pane, session: session, observed: "editing-source")
    state.editorSwitchSucceeded(paneID: pane.paneID)
    let result = try state.receiveRemoteEditor(#require(try remoteEditorEvent(tokens: tokens(sequence: 3, event: "exit"))), pane: pane, session: session, observed: EditorMemory.commandInputSourceID)
    #expect(result == "shell-source")
    #expect(state.editors[pane.paneID]?.editingInputSourceID == "editing-source")
}

@Test func framingHandlesFragmentsMultipleMessagesAndLimits() throws {
    var frames = JSONLines(limit: 20)
    try frames.append(Data("{\"x\":".utf8))
    #expect(try frames.next() == nil)
    try frames.append(Data("1}\n{\"x\":2}\n".utf8))
    #expect(try frames.next()?["x"] as? Int == 1)
    #expect(try frames.next()?["x"] as? Int == 2)
    #expect(try frames.next() == nil)
    #expect(throws: Error.self) { try frames.append(Data(repeating: 65, count: 21)) }
    var malformed = JSONLines(limit: 20)
    try malformed.append(Data("invalid\n".utf8))
    #expect(throws: Error.self) { try malformed.next() }
    #expect(throws: Error.self) { try HerdrAPI.result(["error": ["message": "denied"]]) }
}

@Test func remoteNamespaceAndDirectoriesAreIndependentOfCheckout() throws {
    let a = try RemoteOptions(arguments: ["ubuntu", "--session", "a"])
    let b = try RemoteOptions(arguments: ["ubuntu", "--session", "b"])
    let c = try RemoteOptions(arguments: ["other", "--session", "a"])
    #expect(a.namespace(socket: "/same") != b.namespace(socket: "/same"))
    #expect(a.namespace(socket: "/same") != c.namespace(socket: "/same"))
    #expect(a.namespace(socket: "/same") != a.namespace(socket: "/other"))
    #expect(throws: Error.self) { try RemoteOptions(arguments: ["-oProxyCommand=bad"]) }
    #expect(throws: Error.self) { try RemoteOptions(arguments: ["ubuntu", "--unknown", "x"]) }
    #expect(shellQuote("a'b") == "'a'\\''b'")
    let dirs = PluginDirectories(environment: ["HOME": "/home/test", "XDG_STATE_HOME": "/state"])
    #expect(dirs.config.path == "/home/test/.config/herdr/plugins/config/tsangpo.ime-keeper")
    #expect(dirs.state.path == "/state/herdr/plugins/tsangpo.ime-keeper")
}

@Test func focusBurstKeepsFirstDepartureAndRejectsStaleAcknowledgement() {
    let inbox = RemoteInbox()
    inbox.invalidate(focus: true, source: "pinyin")
    let old = inbox.view()
    inbox.invalidate(focus: true, source: "ABC")
    inbox.consumed(old.revision)
    #expect(inbox.view().departure == "pinyin")
    #expect(inbox.view().revision > old.revision)
    inbox.consumed(inbox.view().revision)
    #expect(inbox.view().departure == nil)
    inbox.fail("events_lost")
    #expect(inbox.view().failure == "events_lost")
}

@Test func controllerOwnershipIsExclusiveAndReleased() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try Store(directory: directory, key: "test")
    var lease = try localControlLease(store: store)
    #expect(lease != nil)
    #expect(try localControlLease(store: store) == nil)
    withExtendedLifetime(lease) {}
    lease = nil
    #expect(try localControlLease(store: store) != nil)
}

@Test func inactiveApplicationCannotSeedEditorMemoryWithABC() throws {
    let pane = Pane(paneID: "p", workspaceID: "w", tabID: "t")
    let session = EditorSession(sourceID: "ssh:h", sessionID: "s")
    let event = try #require(try remoteEditorEvent(tokens: tokens()))
    var state = SessionState.empty
    #expect(try state.remoteFocusTarget(event: event, verified: true, pane: pane, session: session,
        entering: true, observed: nil, ordinaryTarget: nil) == nil)
    #expect(state.editors[pane.paneID]?.beforeInputSourceID == nil)
    #expect(state.editors[pane.paneID]?.editingInputSourceID == nil)
    #expect(try state.remoteFocusTarget(event: event, verified: true, pane: pane, session: session,
        entering: true, observed: "pinyin", ordinaryTarget: nil) == EditorMemory.commandInputSourceID)
    #expect(state.editors[pane.paneID]?.editingInputSourceID == "pinyin")
}

@Test func remoteFailedSwitchRetriesWithoutNewMetadata() throws {
    let pane = Pane(paneID: "p", workspaceID: "w", tabID: "t")
    let session = EditorSession(sourceID: "ssh:h", sessionID: "s")
    var state = SessionState.empty
    let command = try #require(try remoteEditorEvent(tokens: tokens()))
    _ = try state.remoteFocusTarget(event: command, verified: true, pane: pane, session: session,
                                    entering: true, observed: "pinyin", ordinaryTarget: nil)
    state.editorSwitchSucceeded(paneID: pane.paneID)
    let edit = try #require(try remoteEditorEvent(tokens: tokens(sequence: 2, mode: "edit")))
    for _ in 0..<2 {
        #expect(try state.remoteFocusTarget(event: edit, verified: true, pane: pane, session: session,
            entering: false, observed: EditorMemory.commandInputSourceID, ordinaryTarget: nil) == "pinyin")
    }
    #expect(state.editors[pane.paneID]?.editingInputSourceID == "pinyin")
    let exit = try #require(try remoteEditorEvent(tokens: tokens(sequence: 3, event: "exit")))
    for _ in 0..<2 {
        #expect(try state.remoteFocusTarget(event: exit, verified: true, pane: pane, session: session,
            entering: false, observed: EditorMemory.commandInputSourceID, ordinaryTarget: nil) == "pinyin")
    }
}

@Test func expiredLeaseStopsControlButPreservesEditingMemoryOnRecovery() throws {
    let pane = Pane(paneID: "p", workspaceID: "w", tabID: "t")
    let session = EditorSession(sourceID: "ssh:h", sessionID: "s")
    var state = SessionState.empty
    let start = try #require(try remoteEditorEvent(tokens: tokens(mode: "edit")))
    _ = try state.remoteFocusTarget(event: start, verified: true, pane: pane, session: session,
                                    entering: true, observed: "shell", ordinaryTarget: nil)
    state.editorSwitchSucceeded(paneID: pane.paneID)
    let normal = try #require(try remoteEditorEvent(tokens: tokens(sequence: 2)))
    _ = try state.remoteFocusTarget(event: normal, verified: true, pane: pane, session: session,
                                    entering: false, observed: "pinyin", ordinaryTarget: nil)
    state.editorSwitchSucceeded(paneID: pane.paneID)
    #expect(state.releaseRemoteEditor(paneID: pane.paneID) == "shell")
    state.editorSwitchSucceeded(paneID: pane.paneID)
    #expect(state.releaseRemoteEditor(paneID: pane.paneID) == nil)
    #expect(try state.remoteFocusTarget(event: normal, verified: true, pane: pane, session: session,
        entering: false, observed: "new-shell", ordinaryTarget: nil) == EditorMemory.commandInputSourceID)
    #expect(state.editors[pane.paneID]?.editingInputSourceID == "pinyin")
    #expect(state.editors[pane.paneID]?.beforeInputSourceID == "new-shell")
}

@Test func repeatedExitMetadataDoesNotOverrideManualShellMemory() throws {
    let pane = Pane(paneID: "p", workspaceID: "w", tabID: "t")
    let session = EditorSession(sourceID: "ssh:h", sessionID: "s")
    var state = SessionState.empty
    let start = try #require(try remoteEditorEvent(tokens: tokens()))
    _ = try state.remoteFocusTarget(event: start, verified: true, pane: pane, session: session,
                                    entering: true, observed: "shell", ordinaryTarget: nil)
    state.editorSwitchSucceeded(paneID: pane.paneID)
    let exit = try #require(try remoteEditorEvent(tokens: tokens(sequence: 2, event: "exit")))
    _ = try state.remoteFocusTarget(event: exit, verified: true, pane: pane, session: session,
                                    entering: false, observed: EditorMemory.commandInputSourceID, ordinaryTarget: nil)
    state.editorSwitchSucceeded(paneID: pane.paneID)
    state.currentPane = pane
    state.entryInputSourceID = "shell"
    state.rememberLeavingPane(currentInputSourceID: "manual-shell")
    #expect(try state.remoteFocusTarget(event: exit, verified: true, pane: pane, session: session,
        entering: true, observed: "other-pane", ordinaryTarget: "manual-shell") == "manual-shell")
    #expect(state.releaseRemoteEditor(paneID: pane.paneID) == nil)
    #expect(state.panes[pane.paneID]?.inputSourceID == "manual-shell")
}

@Test func leaseExpirySamplesTheLastManualEditingChoiceBeforeRestoringShell() throws {
    let pane = Pane(paneID: "p", workspaceID: "w", tabID: "t")
    let session = EditorSession(sourceID: "ssh:h", sessionID: "s")
    var state = SessionState.empty
    let edit = try #require(try remoteEditorEvent(tokens: tokens(mode: "edit")))
    _ = try state.remoteFocusTarget(event: edit, verified: true, pane: pane, session: session,
                                    entering: true, observed: "shell", ordinaryTarget: nil)
    state.editorSwitchSucceeded(paneID: pane.paneID)
    #expect(try state.remoteFocusTarget(event: nil, verified: false, pane: pane, session: session,
        entering: false, observed: "manual-pinyin", ordinaryTarget: nil) == "shell")
    #expect(state.editors[pane.paneID]?.editingInputSourceID == "manual-pinyin")
}
