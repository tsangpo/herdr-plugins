import Darwin
import Foundation
import Testing
@testable import ImeKeeper

@Test func hookAndEditorDirectoryResolutionAgree() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let paneEnv = ["HOME": root.path, "XDG_CONFIG_HOME": root.appendingPathComponent("config").path,
                   "XDG_STATE_HOME": root.appendingPathComponent("state").path, "HERDR_SOCKET_PATH": "/tmp/named.sock"]
    let dirs = PluginDirectories(environment: paneEnv)
    var hookEnv = paneEnv
    hookEnv["HERDR_PLUGIN_CONFIG_DIR"] = dirs.config.path
    hookEnv["HERDR_PLUGIN_STATE_DIR"] = dirs.state.path
    let editor = try Store(environment: paneEnv), hook = try Store(environment: hookEnv)
    #expect(editor.stateURL == hook.stateURL)
    #expect(editor.switchLockPath == hook.switchLockPath)
    #expect(editor.ownerID == hook.ownerID)
    #expect(PluginDirectories(environment: hookEnv).config == dirs.config)
    var otherSession = paneEnv
    otherSession["HERDR_SOCKET_PATH"] = "/tmp/other.sock"
    #expect(try Store(environment: otherSession).stateURL != editor.stateURL)
    hookEnv["HERDR_PLUGIN_STATE_DIR"] = root.appendingPathComponent("explicit-state").path
    #expect(try Store(environment: hookEnv).directory.path == hookEnv["HERDR_PLUGIN_STATE_DIR"])
    #expect(PluginDirectories(environment: ["HOME": root.path]).config.path == root.path + "/.config/herdr/plugins/config/tsangpo.ime-keeper")
    try FileManager.default.createDirectory(at: dirs.config, withIntermediateDirectories: true)
    #expect(try loadConfiguration(directory: dirs.config).rules.isEmpty)
    let corrupt = Data("not JSON".utf8)
    try corrupt.write(to: configPath(directory: dirs.config))
    #expect(throws: Error.self) { try loadConfiguration(directory: dirs.config) }
    #expect(try Data(contentsOf: configPath(directory: dirs.config)) == corrupt)
}

@Test func scopedLockSurvivesBodyAndReleasesOnError() throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    defer { try? FileManager.default.removeItem(atPath: path) }
    #expect(throws: KeeperError.self) {
        try FileLock.with(path: path) {
            #expect(try FileLock.tryAcquire(path: path) == nil)
            throw KeeperError.message("body failed")
        }
    }
    let acquired = try #require(try FileLock.tryAcquire(path: path))
    #expect(fcntl(acquired.descriptor, F_GETFD) & FD_CLOEXEC != 0)
    withExtendedLifetime(acquired) {}
    #expect(throws: Error.self) { try FileLock.tryAcquire(path: path + "/missing") }
}

@Test func sharedProcessParserSupportsArgvFallback() {
    let rows = parseProcesses(["foreground_processes": [
        ["name": "other", "argv": ["/usr/local/bin/codex", "--help"], "pid": 7],
        ["argv0": "/preferred", "argv": ["/ignored"]],
    ]])
    #expect(rows.first?.pid == 7)
    #expect(matchingInputSource(rules: [Rule(command: "codex", inputSourceID: "ABC")], processes: rows) == "ABC")
    #expect(rows.last?.argv0 == "/preferred")
}
