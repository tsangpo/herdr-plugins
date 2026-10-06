import Foundation
import Testing
@testable import ImeKeeper

/// Explicit opt-in: only a new named server under a private XDG root is touched.
@Test(.enabled(if: ProcessInfo.processInfo.environment["IME_KEEPER_LIVE_TESTS"] == "1"))
func actualHerdrMetadataPushAndExpiry() throws {
    let root = URL(fileURLWithPath: "/tmp/ik-test-" + UUID().uuidString.prefix(8))
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("HERDR_") }
    env["XDG_CONFIG_HOME"] = root.appendingPathComponent("c").path
    env["XDG_STATE_HOME"] = root.appendingPathComponent("s").path
    let name = "ime-test"
    func cli(_ args: [String]) throws -> Data {
        try runCommand(executable: "/usr/bin/env", arguments: ["herdr", "--session", name] + args,
                       environment: env, timeout: 3)
    }
    let server = Process()
    server.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    server.arguments = ["herdr", "--session", name, "server"]
    server.environment = env
    server.standardInput = FileHandle.nullDevice
    server.standardOutput = FileHandle.nullDevice
    server.standardError = FileHandle.nullDevice
    try server.run()
    defer {
        _ = try? cli(["server", "stop"])
        if server.isRunning { server.terminate(); server.waitUntilExit() }
        try? FileManager.default.removeItem(at: root)
    }
    var socket: String?
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
        if let data = try? cli(["status", "server", "--json"]),
           let status = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           status["running"] as? Bool == true {
            socket = status["socket"] as? String
            break
        }
        Thread.sleep(forTimeInterval: 0.05)
    }
    let path = try #require(socket)
    #expect(path.hasPrefix(root.path + "/"))
    guard path.hasPrefix(root.path + "/") else { throw KeeperError.message("test isolation failed") }
    let api = HerdrAPI(path: path)
    let events = try api.subscribe()
    // A newly started headless server need not contain a workspace yet.
    let created = try api.request("workspace.create", ["label": "IME test"])
    let pane = try #require(created["root_pane"] as? [String: Any])
    let id = try #require(pane["pane_id"] as? String)
    let second = try api.request("workspace.create", ["label": "Other pane"])
    let other = try #require(second["root_pane"] as? [String: Any])
    let otherID = try #require(other["pane_id"] as? String)
    let focused = try api.currentPane()
    let backgroundID = focused.paneID == id ? otherID : id
    #expect(try api.currentPane(callerPaneID: backgroundID).paneID == backgroundID)
    #expect(try api.currentPane().paneID == focused.paneID)
    _ = try api.foregroundProcesses(paneID: backgroundID)

    // Match the old local query path against the new path without changing IME.
    var cliTimes: [Double] = [], socketTimes: [Double] = []
    for _ in 0..<10 {
        var began = Date()
        _ = try cli(["pane", "current"])
        _ = try cli(["pane", "process-info", "--pane", focused.paneID])
        _ = try cli(["pane", "current"])
        cliTimes.append(Date().timeIntervalSince(began) * 1000)
        began = Date()
        let local = HerdrAPI(path: path, deadline: Date().addingTimeInterval(1))
        _ = try local.currentPane()
        _ = try local.foregroundProcesses(paneID: focused.paneID)
        _ = try local.currentPane()
        socketTimes.append(Date().timeIntervalSince(began) * 1000)
    }
    print("Local three-query median (10 samples): CLI \(cliTimes.sorted()[5]) ms; socket \(socketTimes.sorted()[5]) ms (no TIS switch)")

    // A real named server must use the same XDG paths as direct editor calls.
    let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    _ = try cli(["plugin", "link", package.path])
    let configDirectory = String(decoding: try cli(["plugin", "config-dir", "tsangpo.ime-keeper"]), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let dirs = PluginDirectories(environment: env)
    #expect(configDirectory == dirs.config.path)
    var paneEnv = env
    paneEnv["HERDR_SOCKET_PATH"] = path
    let directStore = try Store(environment: paneEnv)
    // Linking a headless server need not run startup hooks. Invoke an action
    // explicitly to exercise Herdr's injected plugin environment.
    _ = try cli(["plugin", "action", "invoke", "forget-session", "--plugin", "tsangpo.ime-keeper"])
    let stateDeadline = Date().addingTimeInterval(3)
    while !FileManager.default.fileExists(atPath: directStore.stateURL.path), Date() < stateDeadline {
        Thread.sleep(forTimeInterval: 0.05)
    }
    #expect(FileManager.default.fileExists(atPath: directStore.stateURL.path))
    _ = try cli(["plugin", "unlink", "tsangpo.ime-keeper"])
    _ = try api.request("pane.report_metadata", ["pane_id": id, "source": "ime-keeper:test",
        "tokens": ["ime_keeper_mode": "command"], "ttl_ms": 200])
    var sawUpdate = false
    let updateDeadline = Date().addingTimeInterval(2)
    while Date() < updateDeadline {
        guard let event = try events.read(timeout: 0.1) else { continue }
        if event["event"] as? String == "pane_updated" || event["event"] as? String == "pane.updated" {
            sawUpdate = true
            break
        }
    }
    #expect(sawUpdate)
    Thread.sleep(forTimeInterval: 0.3)
    let after = try api.request("pane.get", ["pane_id": id])
    let tokens = (after["pane"] as? [String: Any])?["tokens"] as? [String: String] ?? [:]
    #expect(tokens["ime_keeper_mode"] == nil)
}
