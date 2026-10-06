import Foundation
import Testing
@testable import ImeKeeper

private func observationRow() -> [String: Any] {
    ["pane_id": "w:p1", "workspace_id": "w", "tab_id": "t", "terminal_id": "terminal", "focused": true,
     "tokens": ["ime_keeper_version": "1", "ime_keeper_instance": "nvim-1", "ime_keeper_pid": "123",
                "ime_keeper_sequence": "1", "ime_keeper_event": "mode", "ime_keeper_mode": "command"]]
}

@Test func remoteIgnoresHeartbeatsAndUnrelatedMetadataButKeepsIdentityAndExpiry() throws {
    var filter = RemoteEventFilter()
    func accepts(_ row: [String: Any]) -> Bool {
        filter.accepts(kind: "pane_updated", data: ["pane": row])
    }
    let original = observationRow()
    #expect(accepts(original))
    var changed = original
    changed["title"] = "new title"
    changed["cwd"] = "/tmp"
    changed["agent_status"] = "running"
    changed["revision"] = 999
    var tokens = try #require(original["tokens"] as? [String: String])
    tokens["other_plugin"] = "new"
    changed["tokens"] = tokens
    #expect(!accepts(changed))
    #expect(RemotePaneObservation(original) == RemotePaneObservation(changed))
    for key in ["pane_id", "workspace_id", "tab_id", "terminal_id", "focused"] {
        var moved = original
        moved[key] = key == "focused" ? false : "different" as Any
        #expect(accepts(moved))
        #expect(RemotePaneObservation(original) != RemotePaneObservation(moved))
        _ = filter.accepts(kind: "pane_updated", data: ["pane": original])
    }
    tokens["ime_keeper_sequence"] = "2"
    changed["tokens"] = tokens
    #expect(accepts(changed))
    changed.removeValue(forKey: "tokens")
    #expect(accepts(changed))
    #expect(!accepts(changed))
    for kind in ["pane_closed", "pane_moved", "workspace_closed", "pane_focused"] {
        let structuralAccepted = filter.accepts(kind: kind, data: [:])
        #expect(structuralAccepted)
        #expect(accepts(changed))
    }
    #expect(accepts(["pane_id": "w:p1"]))
    #expect(accepts(changed))
    var malformed = original
    malformed["tokens"] = ["ime_keeper_mode": "command"]
    #expect(accepts(malformed))
    #expect(accepts(malformed))
    #expect(accepts(changed))
    var reconnected = RemoteEventFilter()
    let firstAfterReconnect = reconnected.accepts(kind: "pane_updated", data: ["pane": changed])
    #expect(firstAfterReconnect)
}

@Test func remoteWaitCoalescesAndCannotLoseAnEarlyNotification() {
    let inbox = RemoteInbox()
    let old = inbox.view().revision
    for _ in 0..<1000 { inbox.invalidate() }
    let start = Date()
    inbox.wait(after: old, until: start.addingTimeInterval(1))
    #expect(Date().timeIntervalSince(start) < 0.2)
    let latest = inbox.view().revision
    let quiet = Date()
    inbox.wait(after: latest, until: quiet.addingTimeInterval(0.04))
    #expect(Date().timeIntervalSince(quiet) >= 0.035) // No 999 queued permits.
    let waking = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        inbox.wait(after: latest, until: Date().addingTimeInterval(2))
        waking.signal()
    }
    inbox.stop()
    #expect(waking.wait(timeout: .now() + 0.5) == .success)
}

@Test func remoteHealthIsIndependentOfContinuousModeTraffic() {
    let start = Date()
    var health = RemoteHealthSchedule()
    var checks = 0
    for tick in 0..<300 {
        let now = start.addingTimeInterval(Double(tick) / 10)
        // Every iteration represents a mode reconcile; only real health advances the deadline.
        if health.isDue(at: now) { checks += 1; health.checked(at: now) }
    }
    #expect(checks == 15)
}

@Test func remoteIdentityHitsCannotExtendKernelVerificationAndFailuresAreNotCached() {
    var cache = RemoteIdentityCache()
    let now = Date()
    var lookups = 0
    func lookup() -> LocalProcessIdentity? {
        lookups += 1
        return LocalProcessIdentity(parentPID: 42, executableName: "nvim")
    }
    _ = cache.identity(key: "pane:instance:pid", fresh: false, now: now, lookup: lookup)
    _ = cache.identity(key: "pane:instance:pid", fresh: false, now: now.addingTimeInterval(0.9), lookup: lookup)
    #expect(lookups == 1)
    _ = cache.identity(key: "pane:instance:pid", fresh: false, now: now.addingTimeInterval(1.1), lookup: lookup)
    #expect(lookups == 2)
    _ = cache.identity(key: "pane:instance:pid", fresh: true, now: now.addingTimeInterval(1.2), lookup: lookup)
    _ = cache.identity(key: "pane:new-instance:pid", fresh: false, now: now.addingTimeInterval(1.3), lookup: lookup)
    #expect(lookups == 4)
    cache.clear()
    let failedLookupIsEmpty = (cache.identity(key: "pane:new-instance:pid", fresh: false, now: now) { nil } == nil)
    #expect(failedLookupIsEmpty)
    _ = cache.identity(key: "pane:new-instance:pid", fresh: false, now: now, lookup: lookup)
    #expect(lookups == 5)
}

@Test func remotePersistenceSkipsEqualWritesAndRetriesFailures() throws {
    var cache = RemoteWriteCache<String>()
    var writes = 0
    cache.save("a") { writes += 1 }
    cache.save("a") { writes += 1 }
    #expect(writes == 1)
    #expect(throws: Error.self) {
        try cache.save("b") { throw KeeperError.message("disk unavailable") }
    }
    #expect(cache.saved == "a")
    cache.save("b") { writes += 1 }
    #expect(cache.saved == "b" && writes == 2)
    let start = Date()
    var schedule = RemoteStatusSchedule()
    #expect(schedule.shouldWrite(businessChanged: false, now: start))
    schedule.succeeded(at: start)
    #expect(!schedule.shouldWrite(businessChanged: false, now: start.addingTimeInterval(1)))
    #expect(schedule.shouldWrite(businessChanged: true, now: start.addingTimeInterval(1)))
    #expect(schedule.shouldWrite(businessChanged: false, now: start.addingTimeInterval(2)))
}

@Test func remoteModeLatencyKeepsReceiptAcrossRetriesAndConsumesOnlyMatchingApplication() throws {
    let inbox = RemoteInbox()
    let observation = try #require(RemotePaneObservation(observationRow()))
    inbox.invalidate(observation: observation)
    let first = inbox.view()
    inbox.consumed(first.revision) // Receiving/reconciling alone is not a successful switch.
    let retryAt = Date()
    inbox.invalidate(observation: observation)
    var newerRow = observationRow()
    var newerTokens = observation.tokens
    newerTokens["ime_keeper_sequence"] = "2"
    newerRow["tokens"] = newerTokens
    #expect(inbox.modeApplied(try #require(RemotePaneObservation(newerRow))) == nil)
    let received = try #require(inbox.modeApplied(observation))
    #expect(received <= retryAt)
    #expect(inbox.modeApplied(observation) == nil)
    inbox.invalidate(observation: observation)
    inbox.invalidate(structural: true)
    #expect(inbox.modeApplied(observation) == nil)
}
