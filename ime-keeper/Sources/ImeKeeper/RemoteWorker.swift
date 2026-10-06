import Foundation

struct RemoteFocusObservation {
    let selected: Bool
    var error: String? = nil
}

enum RemoteQueryReason: String {
    case health, focus, event
}

/// The production connection worker. Dependencies also allow deterministic tests
/// of pauses and wake deadlines without selecting a desktop input source.
struct RemoteWorker {
    let inbox: RemoteInbox
    let diagnostics: RemoteDiagnostics
    var now: () -> Date = Date.init
    var wait: (UInt64, Date) -> Void
    var stopped: () -> Bool
    var focus: () -> RemoteFocusObservation
    var relinquish: () -> Void
    var reconcile: (RemoteInbox.View, RemoteQueryReason) throws -> Bool
    var status: (RemoteFocusObservation) -> Void

    func run() throws {
        var handled: UInt64 = 0
        var observation = RemoteFocusObservation(selected: false)
        var health = RemoteHealthSchedule()
        var terminalCheckAt = Date.distantPast
        // Retain activation across the focus debounce and rejected candidates.
        var needsActivation = false
        while !stopped() {
            if now() >= terminalCheckAt {
                let next = focus()
                terminalCheckAt = now().addingTimeInterval(0.1)
                if next.selected != observation.selected {
                    if next.selected {
                        needsActivation = true
                        // Background focus callbacks cannot supply the new foreground baseline.
                        inbox.cancelFocusObservation(preserveFocusWindow: true)
                    } else {
                        needsActivation = false
                        relinquish()
                        inbox.cancelFocusObservation()
                    }
                }
                observation = next
            }
            let view = inbox.view()
            if let failure = view.failure { throw KeeperError.message(failure) }
            if view.stopped { return }
            if !observation.selected {
                // Consume notification generations, not editor policy. On return,
                // an authoritative snapshot reconciles all intervening changes.
                inbox.consumed(view.revision)
                status(observation)
                wait(view.revision, terminalCheckAt)
                continue
            }
            let stableAt = view.focusAt.addingTimeInterval(0.1)
            if view.focusSamplePending || now() < stableAt {
                wait(view.revision, view.focusSamplePending ? terminalCheckAt : min(stableAt, terminalCheckAt))
                continue
            }
            let healthDue = health.isDue(at: now())
            if handled != view.revision || needsActivation || healthDue {
                let reason: RemoteQueryReason = healthDue ? .health : needsActivation ? .focus : .event
                let started = now()
                diagnostics.update { $0.reconcileAttempts += 1 }
                defer { diagnostics.update { $0.lastReconcileMs = now().timeIntervalSince(started) * 1000 } }
                let completed = try reconcile(view, reason)
                if healthDue { health.checked(at: now()) }
                if !completed, inbox.view().revision != view.revision {
                    diagnostics.update { $0.revisionDiscards += 1 }
                }
                if completed {
                    handled = view.revision
                    needsActivation = false
                    inbox.consumed(view.revision)
                }
            }
            status(observation)
            wait(view.revision, min(terminalCheckAt, health.deadline))
        }
    }
}
