import Foundation

struct Rule: Codable, Equatable {
    let command: String
    let inputSourceID: String
}

struct Configuration: Codable, Equatable {
    let version: Int
    let rules: [Rule]

    static func decode(_ data: Data) throws -> Configuration {
        let value = try JSONDecoder().decode(Configuration.self, from: data)
        guard value.version == 1 else { throw KeeperError.message("unsupported config version \(value.version)") }
        return value
    }
}

struct ForegroundProcess: Equatable {
    let name: String?
    let argv0: String?
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

struct SessionState: Codable, Equatable {
    var currentPane: Pane?
    var entryInputSourceID: String?
    var panes: [String: PaneMemory]

    static let empty = SessionState(currentPane: nil, entryInputSourceID: nil, panes: [:])

    mutating func rememberLeavingPane(currentInputSourceID: String) {
        guard let pane = currentPane else { return }
        if panes[pane.paneID] != nil || currentInputSourceID != entryInputSourceID {
            panes[pane.paneID] = PaneMemory(
                inputSourceID: currentInputSourceID,
                workspaceID: pane.workspaceID,
                tabID: pane.tabID
            )
        }
    }

    mutating func closePane(_ paneID: String) {
        panes.removeValue(forKey: paneID)
        if currentPane?.paneID == paneID {
            currentPane = nil
            entryInputSourceID = nil
        }
    }

    mutating func closeTab(_ tabID: String) {
        panes = panes.filter { $0.value.tabID != tabID }
        if currentPane?.tabID == tabID {
            currentPane = nil
            entryInputSourceID = nil
        }
    }

    mutating func closeWorkspace(_ workspaceID: String) {
        panes = panes.filter { $0.value.workspaceID != workspaceID }
        if currentPane?.workspaceID == workspaceID {
            currentPane = nil
            entryInputSourceID = nil
        }
    }

    mutating func movePane(from oldID: String, to pane: Pane) {
        if var memory = panes.removeValue(forKey: oldID) {
            memory.workspaceID = pane.workspaceID
            memory.tabID = pane.tabID
            panes[pane.paneID] = memory
        }
        if currentPane?.paneID == oldID { currentPane = pane }
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

func responsePayload(_ value: Any, named key: String) -> [String: Any]? {
    guard let envelope = value as? [String: Any] else { return nil }
    let result = (envelope["result"] as? [String: Any]) ?? envelope
    return (result[key] as? [String: Any]) ?? result
}

struct KeeperError: Error, CustomStringConvertible {
    let description: String
    static func message(_ description: String) -> Self { Self(description: description) }
}
