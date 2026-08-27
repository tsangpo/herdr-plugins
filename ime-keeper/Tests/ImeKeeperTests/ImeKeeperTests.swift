import Foundation
import Testing
@testable import ImeKeeper

@Test func ruleOrderAndBasenameMatching() {
    let rules = [
        Rule(command: "codex", inputSourceID: "first"),
        Rule(command: "nvim", inputSourceID: "second"),
        Rule(command: "codex", inputSourceID: "third"),
    ]
    #expect(matchingInputSource(
        rules: rules,
        processes: [ForegroundProcess(name: nil, argv0: "/opt/homebrew/bin/nvim"), ForegroundProcess(name: "codex", argv0: nil)]
    ) == "first")
    #expect(matchingInputSource(rules: rules, processes: [ForegroundProcess(name: "Codex", argv0: nil)]) == nil)
    #expect(matchingInputSource(rules: rules, processes: []) == nil)
}

@Test func savedMemoryBeatsRule() {
    let memory = PaneMemory(inputSourceID: "user", workspaceID: "w", tabID: "t")
    #expect(desiredInputSource(saved: memory, ruleInputSourceID: "rule") == "user")
    #expect(desiredInputSource(saved: nil, ruleInputSourceID: "rule") == "rule")
    #expect(desiredInputSource(saved: nil, ruleInputSourceID: nil) == nil)
}

@Test func userOverrideIsRememberedButUnchangedEntryIsNot() {
    let pane = Pane(paneID: "p", workspaceID: "w", tabID: "t")
    var state = SessionState(currentPane: pane, entryInputSourceID: "ABC", panes: [:])
    state.rememberLeavingPane(currentInputSourceID: "ABC")
    #expect(state.panes.isEmpty)
    state.rememberLeavingPane(currentInputSourceID: "Pinyin")
    #expect(state.panes["p"]?.inputSourceID == "Pinyin")

    state.panes["p"]?.inputSourceID = "ABC"
    state.rememberLeavingPane(currentInputSourceID: "Pinyin")
    #expect(state.panes["p"]?.inputSourceID == "Pinyin")
}

@Test func closeAndMoveMaintainState() {
    var state = SessionState(
        currentPane: Pane(paneID: "old", workspaceID: "w1", tabID: "t1"),
        entryInputSourceID: "ABC",
        panes: [
            "old": PaneMemory(inputSourceID: "ABC", workspaceID: "w1", tabID: "t1"),
            "other": PaneMemory(inputSourceID: "Pinyin", workspaceID: "w2", tabID: "t2"),
        ]
    )
    state.movePane(from: "old", to: Pane(paneID: "new", workspaceID: "w2", tabID: "t3"))
    #expect(state.panes["old"] == nil)
    #expect(state.panes["new"] == PaneMemory(inputSourceID: "ABC", workspaceID: "w2", tabID: "t3"))
    #expect(state.currentPane?.paneID == "new")
    state.closePane("other")
    #expect(state.panes["other"] == nil)
    state.closeTab("t3")
    #expect(state.panes["new"] == nil)
    state.closeWorkspace("w2")
    #expect(state.panes.isEmpty)
}

@Test func corruptAndUnsupportedConfigFail() throws {
    #expect(throws: (any Error).self) { try Configuration.decode(Data("{".utf8)) }
    let unsupported = Data(#"{"version":2,"rules":[]}"#.utf8)
    #expect(throws: (any Error).self) { try Configuration.decode(unsupported) }
}

@Test func herdrCLIResponsePayloadIsUnwrapped() {
    let response: [String: Any] = [
        "id": "cli:pane:current",
        "result": ["type": "pane_current", "pane": ["pane_id": "w1:p1"]],
    ]
    #expect(responsePayload(response, named: "pane")?["pane_id"] as? String == "w1:p1")
}
