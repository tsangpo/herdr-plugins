import Foundation

struct Rule: Codable, Equatable {
    let command: String
    let inputSourceID: String
}

struct Configuration: Codable, Equatable {
    let version: Int
    let rules: [Rule]
    /// Selected when an editor or agent TUI returns to the shell; nil restores
    /// the editor's pre-editor source and leaves agent exits unchanged.
    var exitInputSourceID: String? = nil

    static func decode(_ data: Data) throws -> Configuration {
        let value = try JSONDecoder().decode(Configuration.self, from: data)
        guard value.version == 1 else { throw KeeperError.message("unsupported config version \(value.version)") }
        return value
    }
}

struct ForegroundProcess: Equatable {
    let name: String?
    let argv0: String?
    var pid: Int32? = nil
}

struct Pane: Codable, Equatable {
    let paneID: String
    let workspaceID: String
    let tabID: String
}

struct PaneMemory: Codable, Equatable {
    var inputSourceID: String
    var workspaceID: String
    var tabID: String
}

extension PaneMemory {
    init(_ source: String, pane: Pane) {
        self.init(inputSourceID: source, workspaceID: pane.workspaceID, tabID: pane.tabID)
    }
}

struct SessionState: Codable, Equatable {
    var currentPane: Pane?
    var entryInputSourceID: String?
    var panes: [String: PaneMemory]
    var editors: [String: EditorMemory] = [:]
    /// Copied from configuration after loading; never persisted.
    var exitInputSourceID: String? = nil

    static let empty = SessionState(currentPane: nil, entryInputSourceID: nil, panes: [:])

    /// The shell's source once an editor exits or suspends. Editor memories
    /// are unchanged, so a resume still restores its editing source.
    func shellInputSource(_ editor: EditorMemory) -> String? {
        exitInputSourceID ?? editor.beforeInputSourceID
    }

    /// A Herdr-detected agent TUI released its pane. Returns the source to
    /// select if the pane is focused; an active editor keeps its own policy.
    mutating func agentReleased(pane: Pane) -> String? {
        guard let exit = exitInputSourceID, editors[pane.paneID]?.lifecycle != .active else { return nil }
        panes[pane.paneID] = PaneMemory(exit, pane: pane)
        return exit
    }

    mutating func rememberLeavingPane(currentInputSourceID: String) {
        guard let pane = currentPane else { return }
        if var editor = editors[pane.paneID], editor.lifecycle == .active || editor.appliedMode != nil {
            editor.rememberEditingSource(currentInputSourceID)
            editor.appliedMode = nil
            editors[pane.paneID] = editor
            return
        }
        if panes[pane.paneID] != nil || currentInputSourceID != entryInputSourceID {
            panes[pane.paneID] = PaneMemory(currentInputSourceID, pane: pane)
        }
    }

    mutating func closePane(_ paneID: String) {
        panes.removeValue(forKey: paneID)
        editors.removeValue(forKey: paneID)
        if currentPane?.paneID == paneID {
            currentPane = nil
            entryInputSourceID = nil
        }
    }

    mutating func closeTab(_ tabID: String) {
        panes = panes.filter { $0.value.tabID != tabID }
        editors = editors.filter { $0.value.pane.tabID != tabID }
        if currentPane?.tabID == tabID {
            currentPane = nil
            entryInputSourceID = nil
        }
    }

    mutating func closeWorkspace(_ workspaceID: String) {
        panes = panes.filter { $0.value.workspaceID != workspaceID }
        editors = editors.filter { $0.value.pane.workspaceID != workspaceID }
        if currentPane?.workspaceID == workspaceID {
            currentPane = nil
            entryInputSourceID = nil
        }
    }

    mutating func movePane(from oldID: String, to pane: Pane) {
        if var editor = editors.removeValue(forKey: oldID) {
            editor.pane = pane
            editors[pane.paneID] = editor
        }
        if var memory = panes.removeValue(forKey: oldID) {
            memory.workspaceID = pane.workspaceID
            memory.tabID = pane.tabID
            panes[pane.paneID] = memory
        }
        if currentPane?.paneID == oldID { currentPane = pane }
    }
}

extension SessionState {
    private enum CodingKeys: String, CodingKey {
        case currentPane, entryInputSourceID, panes, editors
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        currentPane = try values.decodeIfPresent(Pane.self, forKey: .currentPane)
        entryInputSourceID = try values.decodeIfPresent(String.self, forKey: .entryInputSourceID)
        panes = try values.decode([String: PaneMemory].self, forKey: .panes)
        editors = try values.decodeIfPresent([String: EditorMemory].self, forKey: .editors) ?? [:]
    }
}

func matchingInputSource(rules: [Rule], processes: [ForegroundProcess]) -> String? {
    let commands = processes.flatMap { process in
        [process.name, process.argv0].compactMap { $0 }.map { ($0 as NSString).lastPathComponent }
    }
    return rules.first { commands.contains($0.command) }?.inputSourceID
}

func desiredInputSource(saved: PaneMemory?, ruleInputSourceID: String?) -> String? {
    saved?.inputSourceID ?? ruleInputSourceID
}

struct KeeperError: Error, CustomStringConvertible {
    let description: String
    static func message(_ description: String) -> Self { Self(description: description) }
}
