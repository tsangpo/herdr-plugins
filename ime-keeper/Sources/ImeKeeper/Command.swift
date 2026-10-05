import Darwin
import Foundation

private final class CommandOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    func set(_ data: Data) { lock.lock(); defer { lock.unlock() }; storage = data }
    func get() -> Data { lock.lock(); defer { lock.unlock() }; return storage }
}

/// Drain both streams while the child runs: waiting first can deadlock once a
/// CLI response fills a pipe. Bound external queries so an editor cannot hang.
func runCommand(executable: String, arguments: [String], environment: [String: String], timeout: TimeInterval = 1) throws -> Data {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.environment = environment
    process.standardInput = FileHandle.nullDevice
    let output = Pipe(), errors = Pipe()
    process.standardOutput = output
    process.standardError = errors
    let finished = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in finished.signal() }
    try process.run()
    let readers = DispatchGroup()
    let stdout = CommandOutput(), stderr = CommandOutput()
    for (pipe, buffer) in [(output, stdout), (errors, stderr)] {
        readers.enter()
        DispatchQueue.global().async {
            buffer.set(pipe.fileHandleForReading.readDataToEndOfFile())
            readers.leave()
        }
    }
    if finished.wait(timeout: .now() + timeout) == .timedOut {
        process.terminate()
        if finished.wait(timeout: .now() + 0.1) == .timedOut {
            kill(process.processIdentifier, SIGKILL)
            _ = finished.wait(timeout: .now() + 0.1)
        }
        throw KeeperError.message("\(executable) timed out")
    }
    guard readers.wait(timeout: .now() + 0.1) == .success else {
        throw KeeperError.message("\(executable) output did not close")
    }
    guard process.terminationStatus == 0 else {
        throw KeeperError.message("\(executable) \(arguments.joined(separator: " ")) failed: \(String(decoding: stderr.get(), as: UTF8.self))")
    }
    return stdout.get()
}
