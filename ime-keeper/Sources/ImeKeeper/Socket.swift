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

    init(path: String) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw KeeperError.message("Unix socket path is too long")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw KeeperError.message("cannot create Unix socket") }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(fd)
            throw KeeperError.message("cannot connect to \(path): \(String(cString: strerror(errno)))")
        }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    }

    deinit { Darwin.close(fd) }

    private func ready(_ events: Int16, until deadline: Date) throws -> Bool {
        var descriptor = pollfd(fd: fd, events: events, revents: 0)
        while true {
            let remaining = max(0, deadline.timeIntervalSinceNow * 1000)
            let result = poll(&descriptor, 1, Int32(min(remaining, 2000)))
            if result < 0 && errno == EINTR { continue }
            guard result >= 0 else { throw KeeperError.message("socket poll failed") }
            return result > 0
        }
    }

    func send(_ value: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: value)
        data.append(10)
        let deadline = Date().addingTimeInterval(2)
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                guard try ready(Int16(POLLOUT), until: deadline), Date() < deadline else {
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
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let line = try lines.next() { return line }
            guard try ready(Int16(POLLIN), until: deadline) else { return nil }
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
    }
}

struct HerdrAPI {
    let path: String

    static func result(_ response: [String: Any]) throws -> [String: Any] {
        if let error = response["error"] { throw KeeperError.message("Herdr API: \(error)") }
        guard let result = response["result"] as? [String: Any] else {
            throw KeeperError.message("Herdr response has no result")
        }
        return result
    }

    func request(_ method: String, _ params: [String: Any] = [:]) throws -> [String: Any] {
        let socket = try JSONSocket(path: path)
        let id = UUID().uuidString
        try socket.send(["id": id, "method": method, "params": params])
        guard let response = try socket.read(), response["id"] as? String == id else {
            throw KeeperError.message("Herdr request timed out or response ID mismatched")
        }
        return try Self.result(response)
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
