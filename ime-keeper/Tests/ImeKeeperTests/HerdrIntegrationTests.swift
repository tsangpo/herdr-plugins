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
