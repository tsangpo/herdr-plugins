import Foundation

/// The same projection is used at subscription ingress and before applying a snapshot.
/// Missing tokens means TTL removal; malformed pane data must never be deduplicated.
struct RemotePaneObservation: Equatable {
    let pane: Pane
    let terminalID: String
    let focused: Bool
    let tokens: [String: String]

    init?(_ row: [String: Any]) {
        guard let pane = try? parsePane(row), let terminal = row["terminal_id"] as? String,
              let focused = row["focused"] as? Bool,
              row["tokens"] == nil || row["tokens"] is [String: String] else { return nil }
        self.pane = pane
        terminalID = terminal
        self.focused = focused
        tokens = (row["tokens"] as? [String: String] ?? [:]).filter { $0.key.hasPrefix("ime_keeper_") }
    }
}

/// Owned only by the subscription reader, never seeded from applied snapshots.
struct RemoteEventFilter {
    private var panes: [String: RemotePaneObservation] = [:]

    mutating func accepts(kind: String, data: [String: Any]) -> Bool {
        guard kind == "pane_updated" else {
            panes.removeAll()
            return true
        }
        guard let row = data["pane"] as? [String: Any], let next = RemotePaneObservation(row) else {
            panes.removeAll()
            return true
        }
        // Invalid editor reports are stable pane state too. Validate during
        // reconciliation; repeated bad tokens must not evict other panes here.
        let previous = panes.updateValue(next, forKey: next.pane.paneID)
        return previous != next
    }
}

struct RemoteHealthSchedule {
    private(set) var deadline = Date.distantPast
    func isDue(at now: Date) -> Bool { now >= deadline }
    mutating func checked(at now: Date) { deadline = now.addingTimeInterval(2) }
}

/// Keep the last successful write, so a failed write remains eligible for retry.
struct RemoteWriteCache<Value: Equatable> {
    private(set) var saved: Value?
    mutating func save(_ value: Value, write: () throws -> Void) rethrows {
        guard saved != value else { return }
        try write()
        saved = value
    }
}

struct RemoteMetrics: Codable, Equatable {
    var receivedEvents = 0
    var ignoredEvents = 0
    var reconcileAttempts = 0
    var revisionDiscards = 0
    var snapshotQueries = 0
    var processQueries = 0
    var currentQueries = 0
    var identityQueries = 0
    var identityCacheHits = 0
    var identityQueriesByReason: [String: Int] = [:]
    var identityQueryTotalMsByReason: [String: Double] = [:]
    var appliedModeEvents = 0
    var lastReconcileMs: Double?
    var lastModeApplyMs: Double?
}

final class RemoteDiagnostics {
    private let lock = NSLock()
    private var metrics = RemoteMetrics()
    func update(_ operation: (inout RemoteMetrics) -> Void) {
        lock.lock(); defer { lock.unlock() }
        operation(&metrics)
    }
    func snapshot() -> RemoteMetrics {
        lock.lock(); defer { lock.unlock() }
        return metrics
    }
}

/// A cache hit never renews the timestamp of the kernel lookup.
struct RemoteIdentityCache {
    private var key: String?
    private var value: (Date, LocalProcessIdentity)?
    mutating func clear() { key = nil; value = nil }
    mutating func identity(key: String, now: Date = Date(), onHit: () -> Void = {},
                           lookup: () -> LocalProcessIdentity?) -> LocalProcessIdentity? {
        if self.key == key, let (checked, identity) = value, now.timeIntervalSince(checked) < 2 {
            onHit()
            return identity
        }
        self.key = key
        guard let identity = lookup() else { value = nil; return nil }
        value = (now, identity)
        return identity
    }
}

struct RemoteStatusSchedule {
    private var writtenAt = Date.distantPast
    func shouldWrite(businessChanged: Bool, now: Date) -> Bool {
        businessChanged || now.timeIntervalSince(writtenAt) >= 2
    }
    mutating func succeeded(at now: Date) { writtenAt = now }
}

/// Bad editor metadata affects one pane, never the connection or other memories.
struct RemoteMetadata {
    private(set) var errors: [String: String] = [:]

    mutating func parse(tokens: [String: String], paneID: String) -> EditorEvent? {
        do {
            let event = try remoteEditorEvent(tokens: tokens)
            errors.removeValue(forKey: paneID)
            return event
        } catch {
            errors[paneID] = String(describing: error)
            return nil
        }
    }

    mutating func retain(panes: Set<String>) {
        errors = errors.filter { panes.contains($0.key) }
    }
}
