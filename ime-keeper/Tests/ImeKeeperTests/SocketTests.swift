import Darwin
import Foundation
import Testing
@testable import ImeKeeper

@Test func localRequestsShareDeadlineAndRejectWrongSocket() throws {
    let path = "/tmp/ik-deadline-" + UUID().uuidString.prefix(8)
    let listener = socket(AF_UNIX, SOCK_STREAM, 0)
    #expect(listener >= 0)
    defer { Darwin.close(listener); unlink(path) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    try #require(bound == 0 && listen(listener, 4) == 0)
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        defer { done.signal() }
        // Answer the first request immediately, leave the second unanswered.
        for index in 0..<2 {
            var descriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, 2000) > 0 else { return }
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            defer { Darwin.close(client) }
            var bytes = [UInt8](repeating: 0, count: 4096)
            var data = Data()
            repeat {
                var ready = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
                guard poll(&ready, 1, 2000) > 0 else { return }
                let count = Darwin.read(client, &bytes, bytes.count)
                guard count > 0 else { return }
                data.append(contentsOf: bytes.prefix(count))
            } while !data.contains(10)
            if index == 0, let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let id = request["id"], var response = try? JSONSerialization.data(withJSONObject: ["id": id, "result": ["ok": true]]) {
                response.append(10)
                _ = response.withUnsafeBytes { Darwin.write(client, $0.baseAddress, $0.count) }
            } else {
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
    }
    defer { _ = done.wait(timeout: .now() + 3) }
    let deadline = Date().addingTimeInterval(0.3)
    let api = HerdrAPI(path: path, deadline: deadline)
    #expect(try api.request("first")["ok"] as? Bool == true)
    Thread.sleep(forTimeInterval: 0.15)
    let began = Date()
    #expect(throws: Error.self) { try api.request("second") }
    #expect(Date().timeIntervalSince(began) < 0.3)
    #expect(throws: Error.self) { try api.request("expired") }
    #expect(throws: Error.self) { try HerdrAPI(path: path + "-missing").currentPane() }
}

@Test func completedOversizedFramesAreStillRejected() throws {
    var frames = JSONLines(limit: 20)
    #expect(throws: Error.self) { try frames.append(Data((String(repeating: "a", count: 21) + "\n").utf8)) }
}

@Test func subscriptionErrorFrameInvalidatesBeforeEOF() throws {
    for code in ["events_lost", "permission_denied"] {
        var frames = JSONLines(limit: 1024)
        var wire = try JSONSerialization.data(withJSONObject: ["id": "ime-events",
            "error": ["code": code, "message": "subscription failed"]])
        wire.append(10)
        try frames.append(wire)
        let inbox = RemoteInbox()
        let revision = inbox.view().revision
        let frame = try #require(try frames.next())
        #expect(throws: Error.self) { try inbox.checkSubscriptionFrame(frame) }
        #expect(inbox.view().revision > revision)
        #expect(inbox.view().failure?.contains(code) == true)
        #expect(inbox.view().failure?.contains("subscription failed") == true)
        // No EOF or second frame is required to invalidate an in-flight switch.
        #expect(try frames.next() == nil)
    }
}
