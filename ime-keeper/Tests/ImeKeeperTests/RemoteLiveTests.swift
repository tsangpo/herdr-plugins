import Foundation
import Testing
@testable import ImeKeeper

/// Opt-in transport/identity coverage. Never touches the user's server or desktop IME.
@Test(.enabled(if: ProcessInfo.processInfo.environment["IME_KEEPER_REMOTE_TEST_HOST"] != nil))
func remoteRealTUIsAndIdleEventFiltering() throws {
    let target = try #require(ProcessInfo.processInfo.environment["IME_KEEPER_REMOTE_TEST_HOST"])
    let ssh = try RemoteSSH(options: RemoteOptions(arguments: [target]))
    let root = "/tmp/ik-test-" + UUID().uuidString.prefix(8)
    let prefix = "env XDG_CONFIG_HOME=\(root)/c XDG_STATE_HOME=\(root)/s herdr --session ime-test"
    func remote(_ command: String) throws -> Data { try ssh.command(command, multiplex: false) }
    func cli(_ args: [String]) throws -> Data {
        try remote(prefix + " " + args.map(shellQuote).joined(separator: " "))
    }
    _ = try remote("mkdir -p " + root + "/nvim/lua/ime_keeper")
    defer {
        ssh.stop()
        _ = try? cli(["server", "stop"])
        _ = try? remote("rm -rf -- " + shellQuote(root))
    }
    let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    for file in ["init.lua", "remote_transport.lua"] {
        let source = try String(contentsOf: package.appendingPathComponent("nvim/lua/ime_keeper/" + file), encoding: .utf8)
        _ = try remote("printf %s " + shellQuote(source) + " > " + root + "/nvim/lua/ime_keeper/" + file)
    }
    let initLua = "vim.opt.runtimepath:prepend('\(root)/nvim')\nrequire('ime_keeper').setup()\n"
    _ = try remote("printf %s " + shellQuote(initLua) + " > " + root + "/init.lua")
    _ = try remote("nohup " + prefix + " server > " + root + "/server.log 2>&1 < /dev/null &")
    var socket: String?
    let startup = Date().addingTimeInterval(5)
    while Date() < startup {
        if let data = try? cli(["status", "server", "--json"]),
           let status = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           status["running"] as? Bool == true { socket = status["socket"] as? String; break }
        Thread.sleep(forTimeInterval: 0.1)
    }
    let path = try #require(socket)
    #expect(path.hasPrefix(root + "/"))
    guard path.hasPrefix(root + "/") else { throw KeeperError.message("remote test isolation failed") }
    try ssh.start(socket: path)
    var api = HerdrAPI(path: ssh.localSocket)
    let events = try api.subscribe()
    var panes: [String] = []
    for label in ["Editor A", "Editor B"] {
        let result = try api.request("workspace.create", ["label": label])
        let row = try #require(result["root_pane"] as? [String: Any])
        let id = try #require(row["pane_id"] as? String)
        panes.append(id)
        _ = try cli(["pane", "run", id, "nvim -u \(root)/init.lua -i NONE"])
    }
    func row(_ id: String) throws -> [String: Any] {
        try #require(api.request("pane.get", ["pane_id": id])["pane"] as? [String: Any])
    }
    func waitEvent(_ id: String, phase: String = "mode", _ predicate: (EditorEvent?) -> Bool) throws -> EditorEvent? {
        let deadline = Date().addingTimeInterval(8)
        repeat {
            let event = try remoteEditorEvent(tokens: row(id)["tokens"] as? [String: String] ?? [:])
            if predicate(event) { return event }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        let last = try row(id)["tokens"] ?? [:]
        let processes = try api.request("pane.process_info", ["pane_id": id])
        throw KeeperError.message("remote editor did not reach \(phase): \(id), tokens=\(last), processes=\(processes)")
    }
    let a = try #require(waitEvent(panes[0]) { $0?.mode == .command })
    let b = try #require(waitEvent(panes[1]) { $0?.mode == .command })
    #expect(a.instanceID != b.instanceID)
    let currentRow = try #require(api.request("pane.current")["pane"] as? [String: Any])
    let snapshot = try #require(api.request("session.snapshot")["snapshot"] as? [String: Any])
    let snapshotRows = try #require(snapshot["panes"] as? [[String: Any]])
    let focusedRow = try #require(snapshotRows.first { $0["pane_id"] as? String == currentRow["pane_id"] as? String })
    #expect(RemotePaneObservation(currentRow) != nil)
    #expect(RemotePaneObservation(currentRow) == RemotePaneObservation(focusedRow))
    for (id, editor) in zip(panes, [a, b]) {
        #expect(try editorIsForeground(pid: editor.pid, processes: api.foregroundProcesses(paneID: id), identity: ssh.identity))
    }
    _ = try cli(["pane", "send-keys", panes[0], "i"])
    _ = try waitEvent(panes[0]) { $0?.mode == .edit }
    #expect(try remoteEditorEvent(tokens: row(panes[1])["tokens"] as? [String: String] ?? [:])?.mode == .command)
    _ = try cli(["pane", "send-keys", panes[0], "esc"])
    _ = try waitEvent(panes[0]) { $0?.mode == .command }

    _ = try cli(["pane", "send-keys", panes[0], "ctrl+z"])
    // A stopped Lua loop may not flush its asynchronous suspend report; TTL must release it.
    _ = try waitEvent(panes[0], phase: "suspend") { $0?.event == .suspend || $0 == nil }
    #expect(try !editorIsForeground(pid: a.pid, processes: api.foregroundProcesses(paneID: panes[0]), identity: ssh.identity))
    _ = try cli(["pane", "run", panes[0], "fg"])
    _ = try waitEvent(panes[0], phase: "resume") { $0?.event == .resume || $0?.event == .snapshot }

    // Warm the reader's own cache, then exercise real heartbeat and unrelated metadata traffic.
    var filter = RemoteEventFilter()
    let warmUntil = Date().addingTimeInterval(2)
    while Date() < warmUntil {
        if let event = try events.read(timeout: 0.1) {
            _ = filter.accepts(kind: event["event"] as? String ?? "", data: event["data"] as? [String: Any] ?? [:])
        }
    }
    var received = 0, accepted = 0, healthChecks = 0
    var health = RemoteHealthSchedule()
    let began = Date(), finish = began.addingTimeInterval(30)
    var reportAt = began
    while Date() < finish {
        if Date() >= reportAt {
            _ = try api.request("pane.report_metadata", ["pane_id": panes[0], "source": "ime-test:unrelated",
                "tokens": ["unrelated": String(received)]])
            reportAt = Date().addingTimeInterval(1)
        }
        if let event = try events.read(timeout: 0.1) {
            received += 1
            if filter.accepts(kind: event["event"] as? String ?? "", data: event["data"] as? [String: Any] ?? [:]) { accepted += 1 }
        }
        if health.isDue(at: Date()) { healthChecks += 1; health.checked(at: Date()) }
    }
    #expect(received >= 40)
    #expect(accepted == 0)
    #expect((14...16).contains(healthChecks))
    print("Remote 30s idle: received=\(received), event reconciles=\(accepted), health deadlines=\(healthChecks)")

    // Recreate only our auxiliary tunnel; current metadata must bootstrap both instances.
    ssh.stop()
    try ssh.start(socket: path)
    api = HerdrAPI(path: ssh.localSocket)
    let resumed = try #require(waitEvent(panes[0]) { $0 != nil })
    #expect(resumed.instanceID == a.instanceID)
    _ = try cli(["pane", "send-keys", panes[0], "esc"])
    _ = try cli(["pane", "send-keys", panes[0], ":", "q", "a", "!", "enter"])
    _ = try waitEvent(panes[0], phase: "exit") { $0?.event == .exit || $0 == nil }
    _ = try remote("kill -KILL " + String(b.pid))
    _ = try waitEvent(panes[1], phase: "crash expiry") { $0 == nil }
}
