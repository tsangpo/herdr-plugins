import Darwin
import Foundation

struct PluginDirectories {
    let config: URL
    let state: URL

    init(environment: [String: String]) {
        let home = environment["HOME"] ?? NSHomeDirectory()
        config = URL(fileURLWithPath: environment["HERDR_PLUGIN_CONFIG_DIR"] ??
            (environment["XDG_CONFIG_HOME"] ?? home + "/.config") + "/herdr/plugins/config/tsangpo.ime-keeper")
        state = URL(fileURLWithPath: environment["HERDR_PLUGIN_STATE_DIR"] ??
            (environment["XDG_STATE_HOME"] ?? home + "/.local/state") + "/herdr/plugins/tsangpo.ime-keeper")
    }
}

/// Held through a local operation, or for the lifetime of a remote wrapper.
func localControlLease(store: Store) throws -> FileLock? {
    do { return try FileLock(path: store.directory.appendingPathComponent("control-owner.lock").path, nonblocking: true) }
    catch let error as KeeperError where error.description == "lock busy" { return nil }
}

final class RemoteSSH {
    let options: RemoteOptions
    let directory: URL
    let localSocket: String
    let control: String
    private var tunnel: Process?

    init(options: RemoteOptions) throws {
        self.options = options
        directory = URL(fileURLWithPath: "/tmp/ik-" + UUID().uuidString.prefix(12))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        localSocket = directory.appendingPathComponent("api").path
        control = directory.appendingPathComponent("ssh").path
    }

    deinit { stop(); try? FileManager.default.removeItem(at: directory) }

    func command(_ command: String, multiplex: Bool = true) throws -> Data {
        var args = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5"]
        if multiplex { args += ["-S", control, "-o", "ControlMaster=no"] }
        args += ["--", options.target, command]
        return try runCommand(executable: "/usr/bin/ssh", arguments: args, environment: environment, timeout: 8)
    }

    func discover() throws -> String {
        let args = [options.herdr] + options.sessionArguments + ["status", "server", "--json"]
        let data = try command(args.map(shellQuote).joined(separator: " "), multiplex: false)
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              value["running"] as? Bool == true, let socket = value["socket"] as? String,
              socket.hasPrefix("/"), !socket.contains(":"), !socket.contains("\n") else {
            throw KeeperError.message("remote Herdr is not running or did not return a usable API socket")
        }
        return socket
    }

    func start(socket: String) throws {
        stop()
        // Only paths inside this invocation's private directory are removed.
        for path in [localSocket, control] { try? FileManager.default.removeItem(atPath: path) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-N", "-T", "-M", "-S", control, "-o", "BatchMode=yes",
            "-o", "ControlPersist=no", "-o", "ExitOnForwardFailure=yes", "-o", "ConnectTimeout=5",
            "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=2",
            "-L", localSocket + ":" + socket, "--", options.target]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errorPath = directory.appendingPathComponent("ssh.log")
        FileManager.default.createFile(atPath: errorPath.path, contents: nil)
        process.standardError = try FileHandle(forWritingTo: errorPath)
        try process.run()
        tunnel = process
        let deadline = Date().addingTimeInterval(6)
        while !FileManager.default.fileExists(atPath: localSocket) {
            guard process.isRunning, Date() < deadline else {
                let message = (try? String(contentsOf: errorPath, encoding: .utf8)) ?? "SSH forwarding timed out"
                stop()
                throw KeeperError.message(message)
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    func identity(pid: Int32) -> LocalProcessIdentity? {
        guard pid > 0, let data = try? command("ps -p \(pid) -o ppid= -o comm="),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let fields = text.split(whereSeparator: { $0.isWhitespace })
        guard fields.count == 2, let parent = Int32(fields[0]) else { return nil }
        return LocalProcessIdentity(parentPID: parent, executableName: String(fields[1]))
    }

    func stop() {
        guard let process = tunnel else { return }
        if process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(0.5)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
        (process.standardError as? FileHandle)?.closeFile()
        tunnel = nil
    }
}
