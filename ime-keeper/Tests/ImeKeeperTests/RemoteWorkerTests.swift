import Foundation
import Testing
@testable import ImeKeeper

@Test func workerPausesQueriesForThirtySecondsAndReconcilesLatestStateOnReturn() throws {
    let inbox = RemoteInbox()
    let metrics = RemoteDiagnostics()
    let start = Date()
    var clock = start
    var queries = 0
    var pauses = 0
    var waits = 0
    var remotePane = "original"
    var appliedPanes: [String] = []
    var oldSample: UInt64?
    var backgroundSample: UInt64?
    var pausedCounts: [Int] = []
    let worker = RemoteWorker(inbox: inbox, diagnostics: metrics, now: { clock },
        wait: { _, deadline in
            #expect(deadline > clock) // An overdue health deadline must not spin while paused.
            clock = deadline
            waits += 1
            let elapsed = clock.timeIntervalSince(start)
            if elapsed > 1, elapsed < 30 {
                // Moves, closes and editor exit happen while paused. Only the latest snapshot matters.
                remotePane = elapsed < 5 ? "moved" : "replacement-shell"
                inbox.invalidate(structural: true)
                if let sample = oldSample { inbox.finishFocusSample(sample, source: "stale-source") }
                if elapsed > 29.5 { backgroundSample = inbox.beginFocusSample() }
            }
        },
        stopped: { clock.timeIntervalSince(start) > 30.5 || waits > 400 },
        focus: {
            let elapsed = clock.timeIntervalSince(start)
            return RemoteFocusObservation(selected: elapsed < 0.1 || elapsed >= 30.2)
        },
        relinquish: {
            pauses += 1
            oldSample = inbox.beginFocusSample()
        },
        reconcile: { view, reason in
            queries += 1 // This is the production worker's only query entry point.
            if let sample = backgroundSample { inbox.finishFocusSample(sample, source: "late-background-source") }
            #expect(inbox.view().departure == nil)
            #expect(view.departure == nil && !view.focusSamplePending)
            #expect(reason == .health || reason == .focus)
            appliedPanes.append(remotePane)
            return true
        },
        status: { focus in if !focus.selected { pausedCounts.append(queries) } })
    try worker.run()
    #expect(pauses == 1)
    #expect(queries == 2)
    #expect(Set(pausedCounts) == [1])
    #expect(appliedPanes == ["original", "replacement-shell"])
    #expect(waits >= 300 && waits < 310)
}

@Test func pausedWorkerStillFailsImmediatelyOnSubscriptionError() throws {
    let inbox = RemoteInbox()
    let oldRevision = inbox.view().revision
    var clock = Date()
    var waits = 0
    let worker = RemoteWorker(inbox: inbox, diagnostics: RemoteDiagnostics(), now: { clock },
        wait: { _, deadline in
            clock = deadline
            waits += 1
            _ = try? inbox.checkSubscriptionFrame(["id": "ime-events", "error": [
                "code": "events_lost", "message": "history overrun"]])
        }, stopped: { waits > 2 }, focus: { RemoteFocusObservation(selected: false) },
        relinquish: {}, reconcile: { _, _ in Issue.record("queried while paused"); return true }, status: { _ in })
    do {
        try worker.run()
        Issue.record("subscription error was ignored")
    } catch {
        #expect(String(describing: error).contains("events_lost"))
    }
    #expect(waits == 1)
    #expect(inbox.view().revision > oldRevision)
}

@Test func activationSurvivesDebounceAndRejectedCandidate() throws {
    let inbox = RemoteInbox()
    let sample = inbox.beginFocusSample()
    var clock = Date()
    var selected = true
    var reasons: [RemoteQueryReason] = []
    var waits = 0
    let worker = RemoteWorker(inbox: inbox, diagnostics: RemoteDiagnostics(), now: { clock },
        wait: { _, deadline in
            clock = deadline
            waits += 1
            if waits == 1 { inbox.finishFocusSample(sample, source: "source") }
            if waits == 2 { selected = false }
            if waits == 3 { selected = true }
        }, stopped: { reasons.count >= 3 || waits > 20 },
        focus: { RemoteFocusObservation(selected: selected) }, relinquish: {},
        reconcile: { _, reason in
            reasons.append(reason)
            return reasons.count == 1 || reasons.count == 3
        }, status: { _ in })
    try worker.run()
    #expect(reasons == [.health, .focus, .focus])
}

private func validMetadata() -> [String: String] {
    ["ime_keeper_version": "1", "ime_keeper_instance": "nvim", "ime_keeper_pid": "123",
     "ime_keeper_sequence": "1", "ime_keeper_event": "mode", "ime_keeper_mode": "command"]
}

@Test func malformedFocusedMetadataReleasesOnlyItsEditorAndRecovers() throws {
    let pane = Pane(paneID: "p", workspaceID: "w", tabID: "t")
    let other = Pane(paneID: "other", workspaceID: "w", tabID: "t")
    let session = EditorSession(sourceID: "ssh:h", sessionID: "s")
    var metadata = RemoteMetadata()
    var state = SessionState.empty
    let initialEvent = metadata.parse(tokens: validMetadata(), paneID: pane.paneID)
    let initial = try #require(initialEvent)
    _ = try state.receiveRemoteEditor(initial, pane: pane, session: session, observed: "pinyin")
    state.editorSwitchSucceeded(paneID: pane.paneID)
    state.panes[other.paneID] = PaneMemory("other-source", pane: other)
    var bad = validMetadata()
    bad["ime_keeper_version"] = "2"
    let invalid = metadata.parse(tokens: bad, paneID: pane.paneID)
    #expect(invalid == nil)
    let restore = try state.remoteFocusTarget(event: invalid, verified: false, pane: pane, session: session,
        entering: false, observed: EditorMemory.commandInputSourceID, ordinaryTarget: nil)
    #expect(restore == "pinyin")
    state.editorSwitchSucceeded(paneID: pane.paneID)
    #expect(metadata.errors[pane.paneID] != nil) // Switching successfully cannot erase metadata diagnostics.
    #expect(state.editors[pane.paneID]?.lifecycle == .suspended)
    #expect(state.panes[other.paneID]?.inputSourceID == "other-source")
    let recoveredEvent = metadata.parse(tokens: validMetadata(), paneID: pane.paneID)
    let recovered = try #require(recoveredEvent)
    _ = try state.remoteFocusTarget(event: recovered, verified: true, pane: pane, session: session,
        entering: false, observed: "pinyin", ordinaryTarget: nil)
    #expect(metadata.errors.isEmpty)
    #expect(state.editors[pane.paneID]?.lifecycle == .active)
    _ = metadata.parse(tokens: bad, paneID: pane.paneID)
    _ = metadata.parse(tokens: [:], paneID: pane.paneID)
    #expect(metadata.errors.isEmpty)
    _ = metadata.parse(tokens: bad, paneID: pane.paneID)
    metadata.retain(panes: [other.paneID])
    #expect(metadata.errors.isEmpty)
}

@Test func workerHealthCannotBeStarvedByContinuousModeEvents() throws {
    let start = Date()
    var clock = start
    let inbox = RemoteInbox()
    var health = 0, events = 0
    let worker = RemoteWorker(inbox: inbox, diagnostics: RemoteDiagnostics(), now: { clock },
        wait: { _, deadline in clock = deadline; inbox.invalidate() },
        stopped: { clock.timeIntervalSince(start) >= 5.9 },
        focus: { RemoteFocusObservation(selected: true) }, relinquish: {},
        reconcile: { _, reason in
            if reason == .health { health += 1 } else { events += 1 }
            return true
        }, status: { _ in })
    try worker.run()
    #expect(health == 3)
    #expect(events > 40)
}
