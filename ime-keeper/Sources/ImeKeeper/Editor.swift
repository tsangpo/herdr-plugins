import Foundation

/// Transport-independent identities. Local transport uses sourceID "local" and
/// the existing socket hash; a future SSH adapter must supply its own namespace.
struct EditorSession: Codable, Equatable {
    let sourceID: String
    let sessionID: String
}

enum EditorMode: String, Codable { case edit, command }
enum EditorEventKind: String, Codable { case start, mode, snapshot, suspend, resume, exit }
enum EditorLifecycle: String, Codable { case active, suspended, exited }

struct EditorEvent: Codable, Equatable {
    let version: Int
    let instanceID: String
    let pid: Int32
    let sequence: UInt64
    let event: EditorEventKind
    let mode: EditorMode

    func validate() throws {
        guard version == 1, !instanceID.isEmpty, instanceID.utf8.count <= 128,
              pid > 0, sequence > 0 else {
            throw KeeperError.message("invalid editor event or unsupported protocol version")
        }
    }
}

struct EditorContext: Codable, Equatable {
    let session: EditorSession
    let pane: Pane
}

struct EditorMemory: Codable, Equatable {
    let session: EditorSession
    let instanceID: String
    let pid: Int32
    var pane: Pane
    var sequence: UInt64
    var mode: EditorMode
    var lifecycle: EditorLifecycle
    var beforeInputSourceID: String?
    var editingInputSourceID: String?
    // Only successful application permits subsequent sampling of editing IME.
    var appliedMode: EditorMode?

    static let commandInputSourceID = "com.apple.keylayout.ABC"

    mutating func rememberEditingSource(_ source: String) {
        if lifecycle == .active, appliedMode == .edit {
            editingInputSourceID = source
        }
    }

    mutating func targetOnFocus(baseInputSourceID: String) -> String? {
        guard lifecycle == .active else { return nil }
        if beforeInputSourceID == nil { beforeInputSourceID = baseInputSourceID }
        if editingInputSourceID == nil { editingInputSourceID = baseInputSourceID }
        return mode == .command ? Self.commandInputSourceID : editingInputSourceID
    }
}

extension SessionState {
    /// nil observation means this pane is in the background: never sample the
    /// global IME or request a switch. Process/pane validation belongs to transport.
    mutating func receiveEditor(
        _ event: EditorEvent, context: EditorContext, expectedSession: EditorSession,
        observedInputSourceID: String?
    ) throws -> String? {
        try event.validate()
        guard context.session == expectedSession else { return nil }
        let paneID = context.pane.paneID
        var memory: EditorMemory
        if let previous = editors[paneID], previous.instanceID == event.instanceID {
            guard previous.session == context.session, previous.pid == event.pid,
                  event.sequence > previous.sequence, previous.lifecycle != .exited else { return nil }
            memory = previous
        } else {
            guard event.event == .start || event.event == .snapshot else { return nil }
            memory = EditorMemory(
                session: context.session, instanceID: event.instanceID, pid: event.pid,
                pane: context.pane, sequence: 0, mode: event.mode, lifecycle: .active
            )
        }

        if let observedInputSourceID {
            memory.rememberEditingSource(observedInputSourceID)
            if memory.beforeInputSourceID == nil {
                memory.beforeInputSourceID = observedInputSourceID
            }
            if memory.editingInputSourceID == nil {
                memory.editingInputSourceID = observedInputSourceID
            }
            if event.event == .resume, memory.lifecycle == .suspended {
                memory.beforeInputSourceID = observedInputSourceID
            }
        }
        memory.sequence = event.sequence
        memory.pane = context.pane
        memory.mode = event.mode
        // Keep the physical policy until switching succeeds or departure is
        // sampled. Incoming modes alone must not acknowledge a TIS operation.
        let target: String?
        switch event.event {
        case .suspend, .exit:
            memory.lifecycle = event.event == .exit ? .exited : .suspended
            target = observedInputSourceID == nil ? nil : memory.beforeInputSourceID
        default:
            // A late mode notification must not undo a suspend.
            if memory.lifecycle == .suspended, event.event != .resume {
                target = nil
            } else {
                memory.lifecycle = .active
                target = observedInputSourceID == nil ? nil : memory.targetOnFocus(
                    baseInputSourceID: observedInputSourceID!
                )
            }
        }
        editors[paneID] = memory
        return target
    }

    mutating func editorSwitchSucceeded(paneID: String) {
        let mode = editors[paneID]?.lifecycle == .active ? editors[paneID]?.mode : nil
        editors[paneID]?.appliedMode = mode
    }

    mutating func forgetPane(_ paneID: String) {
        panes.removeValue(forKey: paneID)
        // Retain identity and sequence so a delayed event cannot resurrect old
        // memory. The next focused event establishes a fresh baseline.
        editors[paneID]?.beforeInputSourceID = nil
        editors[paneID]?.editingInputSourceID = nil
        editors[paneID]?.appliedMode = nil
    }
}
