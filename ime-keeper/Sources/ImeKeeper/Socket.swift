import Darwin
import Foundation

/// Bounded newline JSON framing shared by requests and long-lived subscriptions.
struct JSONLines {
    var buffer = Data()
    let limit: Int

    mutating func append(_ data: Data) throws {
        buffer.append(data)
        for line in buffer.split(separator: 10, omittingEmptySubsequences: false) {
            guard line.count <= limit else { throw KeeperError.message("socket frame exceeds \(limit) bytes") }
        }
    }

    mutating func next() throws -> [String: Any]? {
        guard let end = buffer.firstIndex(of: 10) else { return nil }
        let data = buffer[..<end]
        buffer.removeSubrange(...end)
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw KeeperError.message("socket frame is not a JSON object")
        }
        return value
    }
}

final class JSONSocket {
    let fd: Int32
    private var lines = JSONLines(limit: 8 * 1024 * 1024)

    init(path: String, deadline: Date = Date().addingTimeInterval(2)) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw KeeperError.message("Unix socket path is too long")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw KeeperError.message("cannot create Unix socket") }
        var connected = false
        defer { if !connected { Darwin.close(descriptor) } }
        _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        guard Date() < deadline else { throw KeeperError.message("socket deadline exceeded") }
        var yes: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result != 0 {
            guard errno == EINPROGRESS || errno == EAGAIN || errno == EINTR else {
                throw KeeperError.message("cannot connect to \(path): \(String(cString: strerror(errno)))")
            }
            guard try Self.ready(descriptor, Int16(POLLOUT), until: deadline) else { throw KeeperError.message("socket connect timed out") }
            var error: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else {
                throw KeeperError.message("cannot connect to \(path): \(String(cString: strerror(error)))")
            }
        }
        fd = descriptor
        connected = true
    }

    deinit { Darwin.close(fd) }

    private static func ready(_ fd: Int32, _ events: Int16, until deadline: Date) throws -> Bool {
        var descriptor = pollfd(fd: fd, events: events, revents: 0)
        while true {
            let remaining = deadline.timeIntervalSinceNow * 1000
            guard remaining > 0 else { return false }
            let result = poll(&descriptor, 1, Int32(min(remaining, 2000)))
            if result < 0 && errno == EINTR { continue }
            guard result >= 0 else { throw KeeperError.message("socket poll failed") }
            return result > 0
        }
    }

    func send(_ value: [String: Any], deadline: Date = Date().addingTimeInterval(2)) throws {
        var data = try JSONSerialization.data(withJSONObject: value)
        data.append(10)
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                guard try Self.ready(fd, Int16(POLLOUT), until: deadline), Date() < deadline else {
                    throw KeeperError.message("socket write timed out")
                }
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && (errno == EAGAIN || errno == EINTR) { continue }
                guard count > 0 else { throw KeeperError.message("socket write failed") }
                offset += count
            }
        }
    }

    /// nil is an idle timeout, not a disconnect.
    func read(timeout: TimeInterval = 2) throws -> [String: Any]? {
        try read(until: Date().addingTimeInterval(timeout))
    }

    func read(until deadline: Date) throws -> [String: Any]? {
        while Date() < deadline {
            if let line = try lines.next() { return line }
            guard try Self.ready(fd, Int16(POLLIN), until: deadline) else { return nil }
            var buffer = [UInt8](repeating: 0, count: 16384)
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && (errno == EAGAIN || errno == EINTR) {
                if Date() >= deadline { return nil }
                continue
            }
            guard count > 0 else { throw KeeperError.message("socket disconnected") }
            try lines.append(Data(buffer.prefix(count)))
            if Date() >= deadline, !lines.buffer.contains(10) { return nil }
        }
        return nil
    }
}

struct HerdrAPI {
    let path: String
    var deadline: Date? = nil

    static func result(_ response: [String: Any]) throws -> [String: Any] {
        if let error = response["error"] { throw KeeperError.message("Herdr API: \(error)") }
        guard let result = response["result"] as? [String: Any] else {
            throw KeeperError.message("Herdr response has no result")
        }
        return result
    }

    func request(_ method: String, _ params: [String: Any] = [:]) throws -> [String: Any] {
        let deadline = deadline ?? Date().addingTimeInterval(2)
        let socket = try JSONSocket(path: path, deadline: deadline)
        let id = UUID().uuidString
        try socket.send(["id": id, "method": method, "params": params], deadline: deadline)
        guard let response = try socket.read(until: deadline), response["id"] as? String == id else {
            throw KeeperError.message("Herdr request timed out or response ID mismatched")
        }
        return try Self.result(response)
    }

    func currentPane(callerPaneID: String? = nil) throws -> Pane {
        let params = callerPaneID.map { ["caller_pane_id": $0] } ?? [:]
        guard let row = try request("pane.current", params)["pane"] as? [String: Any] else {
            throw KeeperError.message("pane.current response is missing pane")
        }
        return try parsePane(row)
    }

    func foregroundProcesses(paneID: String) throws -> [ForegroundProcess] {
        guard let row = try request("pane.process_info", ["pane_id": paneID])["process_info"] as? [String: Any] else {
            throw KeeperError.message("pane.process_info response is missing process_info")
        }
        return parseProcesses(row)
    }

    func subscribe() throws -> JSONSocket {
        let socket = try JSONSocket(path: path)
        let names = ["pane.focused", "pane.updated", "pane.closed", "pane.moved", "pane.exited", "tab.closed", "workspace.closed"]
        try socket.send(["id": "ime-events", "method": "events.subscribe",
                         "params": ["subscriptions": names.map { ["type": $0] }]])
        guard let response = try socket.read(),
              try Self.result(response)["type"] as? String == "subscription_started" else {
            throw KeeperError.message("Herdr did not acknowledge event subscription")
        }
        return socket
    }
}
