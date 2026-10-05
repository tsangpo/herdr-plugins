import AppKit
import Carbon
import Darwin
import Foundation

let environment = ProcessInfo.processInfo.environment

func log(_ message: String) {
    FileHandle.standardError.write(Data("ime-keeper: \(message)\n".utf8))
}

func requireEnvironment(_ name: String) throws -> String {
    guard let value = environment[name], !value.isEmpty else { throw KeeperError.message("missing \(name)") }
    return value
}

func sessionKey(_ value: String) -> String {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in value.utf8 {
        hash ^= UInt64(byte)
        hash &*= 1_099_511_628_211
    }
    return String(hash, radix: 16)
}

final class FileLock {
    let descriptor: Int32

    init(path: String, nonblocking: Bool = false) throws {
        descriptor = Darwin.open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw KeeperError.message("cannot open lock \(path): \(String(cString: strerror(errno)))") }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        let operation = LOCK_EX | (nonblocking ? LOCK_NB : 0)
        guard flock(descriptor, operation) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw KeeperError.message(code == EWOULDBLOCK ? "lock busy" : "cannot lock \(path): \(String(cString: strerror(code)))")
        }
    }

    deinit {
        flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }
}

struct Store {
    struct FocusSignal: Codable, Equatable {
        let token: String
        let inputSourceID: String
    }

    let directory: URL
    let key: String

    init() throws {
        directory = URL(fileURLWithPath: try requireEnvironment("HERDR_PLUGIN_STATE_DIR"), isDirectory: true)
        key = sessionKey(try requireEnvironment("HERDR_SOCKET_PATH"))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    init(directory: URL, key: String) throws {
        self.directory = directory
        self.key = key
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    var stateURL: URL { directory.appendingPathComponent("session-\(key).json") }
    var stateLockPath: String { directory.appendingPathComponent("session-\(key).state.lock").path }
    var focusLockPath: String { directory.appendingPathComponent("session-\(key).focus.lock").path }
    var dirtyURL: URL { directory.appendingPathComponent("session-\(key).dirty") }
    var switchLockPath: String { directory.appendingPathComponent("input-source-switch.lock").path }

    func load() throws -> SessionState {
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return .empty }
        do { return try JSONDecoder().decode(SessionState.self, from: Data(contentsOf: stateURL)) }
        catch { throw KeeperError.message("invalid state \(stateURL.path): \(error)") }
    }

    func save(_ state: SessionState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: stateURL, options: .atomic)
    }

    func markDirty(inputSourceID: String) throws {
        let signal = FocusSignal(token: UUID().uuidString, inputSourceID: inputSourceID)
        try JSONEncoder().encode(signal).write(to: dirtyURL, options: .atomic)
    }

    func dirtySignal() -> FocusSignal? {
        guard let data = try? Data(contentsOf: dirtyURL) else { return nil }
        return try? JSONDecoder().decode(FocusSignal.self, from: data)
    }
}

func configPath() throws -> URL {
    URL(fileURLWithPath: try requireEnvironment("HERDR_PLUGIN_CONFIG_DIR"), isDirectory: true)
        .appendingPathComponent("config.json")
}

func loadConfiguration() throws -> Configuration {
    let path = try configPath()
    guard FileManager.default.fileExists(atPath: path.path) else { return Configuration(version: 1, rules: []) }
    do { return try Configuration.decode(Data(contentsOf: path)) }
    catch { throw KeeperError.message("invalid config \(path.path): \(error)") }
}

func sourceProperty<T>(_ source: TISInputSource, _ key: CFString, as type: T.Type) -> T? {
    guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
    return Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue() as? T
}

struct InputSource: Codable {
    let id: String
    let name: String
    let languages: [String]
}

func inputSources() -> [(TISInputSource, InputSource)] {
    guard let unmanaged = TISCreateInputSourceList(nil, false) else { return [] }
    let sources = unmanaged.takeRetainedValue() as NSArray as? [TISInputSource] ?? []
    return sources.compactMap { source in
        guard sourceProperty(source, kTISPropertyInputSourceIsSelectCapable, as: Bool.self) == true,
              let id = sourceProperty(source, kTISPropertyInputSourceID, as: String.self) else { return nil }
        let name = sourceProperty(source, kTISPropertyLocalizedName, as: String.self) ?? id
        let languages = sourceProperty(source, kTISPropertyInputSourceLanguages, as: [String].self) ?? []
        return (source, InputSource(id: id, name: name, languages: languages))
    }
}

func currentInputSourceID() throws -> String {
    guard let unmanaged = TISCopyCurrentKeyboardInputSource() else { throw KeeperError.message("TIS returned no current input source") }
    let source = unmanaged.takeRetainedValue()
    guard let id = sourceProperty(source, kTISPropertyInputSourceID, as: String.self) else {
        throw KeeperError.message("current input source has no ID")
    }
    return id
}

func selectInputSource(_ id: String, settle: Bool = true) throws {
    guard let source = inputSources().first(where: { $0.1.id == id })?.0 else {
        throw KeeperError.message("unknown or unselectable input source \(id)")
    }
    let status = TISSelectInputSource(source)
    guard status == noErr else { throw KeeperError.message("TIS failed to select \(id): OSStatus \(status)") }
    if settle { Thread.sleep(forTimeInterval: 0.15) }
    NSTextInputContext.current?.invalidateCharacterCoordinates()
}
