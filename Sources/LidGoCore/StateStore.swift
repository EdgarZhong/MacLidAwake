import Darwin
import Foundation

public enum StateStoreError: Error, CustomStringConvertible {
    case unsafeDirectory(URL)
    case cannotCreateDirectory(URL, Error)
    case cannotOpenLock(URL, Int32)
    case cannotLock(URL, Int32)
    case invalidSchema(Int)
    case cannotWrite(URL, Int32)
    case cannotReplace(URL, Int32)

    public var description: String {
        switch self {
        case let .unsafeDirectory(url):
            return "状态目录不是安全的普通目录：\(url.path)"
        case let .cannotCreateDirectory(url, error):
            return "无法创建状态目录 \(url.path)：\(error)"
        case let .cannotOpenLock(url, code):
            return "无法打开状态锁 \(url.path)：\(String(cString: strerror(code)))"
        case let .cannotLock(url, code):
            return "无法取得状态锁 \(url.path)：\(String(cString: strerror(code)))"
        case let .invalidSchema(version):
            return "不支持的状态 schema：\(version)"
        case let .cannotWrite(url, code):
            return "无法写入 \(url.path)：\(String(cString: strerror(code)))"
        case let .cannotReplace(url, code):
            return "无法原子替换 \(url.path)：\(String(cString: strerror(code)))"
        }
    }
}

public final class StateStore: @unchecked Sendable {
    public let paths: LidGoPaths

    private let fileManager: FileManager
    private let processLock = NSLock()
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(paths: LidGoPaths, fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    public func withLock<T>(
        _ body: (inout RuntimeState, inout LidGoConfig) throws -> T
    ) throws -> T {
        processLock.lock()
        defer { processLock.unlock() }

        try ensureDirectory()
        let lockFD = open(paths.stateLock.path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard lockFD >= 0 else {
            throw StateStoreError.cannotOpenLock(paths.stateLock, errno)
        }
        defer { close(lockFD) }
        _ = chmod(paths.stateLock.path, 0o600)

        guard flock(lockFD, LOCK_EX) == 0 else {
            throw StateStoreError.cannotLock(paths.stateLock, errno)
        }
        defer { flock(lockFD, LOCK_UN) }

        var config = try loadConfig()
        var state = try loadState()
        let result = try body(&state, &config)
        try config.validated()
        guard state.schemaVersion == RuntimeState.currentSchemaVersion else {
            throw StateStoreError.invalidSchema(state.schemaVersion)
        }
        try atomicWrite(config, to: paths.configFile)
        try atomicWrite(state, to: paths.stateFile)
        return result
    }

    private func ensureDirectory() throws {
        var metadata = stat()
        if lstat(paths.applicationSupport.path, &metadata) == 0 {
            let type = metadata.st_mode & S_IFMT
            guard type == S_IFDIR else {
                throw StateStoreError.unsafeDirectory(paths.applicationSupport)
            }
        } else if errno == ENOENT {
            do {
                try fileManager.createDirectory(
                    at: paths.applicationSupport,
                    withIntermediateDirectories: true
                )
            } catch {
                throw StateStoreError.cannotCreateDirectory(paths.applicationSupport, error)
            }
        } else {
            throw StateStoreError.unsafeDirectory(paths.applicationSupport)
        }
        _ = chmod(paths.applicationSupport.path, 0o700)
    }

    private func loadConfig() throws -> LidGoConfig {
        guard fileManager.fileExists(atPath: paths.configFile.path) else { return .default }
        do {
            let value = try decoder.decode(LidGoConfig.self, from: Data(contentsOf: paths.configFile))
            return try value.validated()
        } catch {
            try quarantine(paths.configFile, prefix: "config")
            return .default
        }
    }

    private func loadState() throws -> RuntimeState {
        guard fileManager.fileExists(atPath: paths.stateFile.path) else { return RuntimeState() }
        do {
            let state = try decoder.decode(RuntimeState.self, from: Data(contentsOf: paths.stateFile))
            guard state.schemaVersion == RuntimeState.currentSchemaVersion else {
                throw StateStoreError.invalidSchema(state.schemaVersion)
            }
            return state
        } catch {
            try quarantine(paths.stateFile, prefix: "state")
            return RuntimeState()
        }
    }

    private func quarantine(_ url: URL, prefix: String) throws {
        let stamp = Int(Date().timeIntervalSince1970)
        let destination = paths.applicationSupport.appendingPathComponent(
            "\(prefix).corrupt-\(stamp)-\(UUID().uuidString).json"
        )
        guard rename(url.path, destination.path) == 0 else {
            throw StateStoreError.cannotReplace(destination, errno)
        }
        _ = chmod(destination.path, 0o600)
    }

    private func atomicWrite<T: Encodable>(_ value: T, to destination: URL) throws {
        let data = try encoder.encode(value)
        let temporary = paths.applicationSupport.appendingPathComponent(
            ".\(destination.lastPathComponent).\(getpid()).\(UUID().uuidString).tmp"
        )
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else {
            throw StateStoreError.cannotWrite(temporary, errno)
        }

        var writeError: Int32?
        data.withUnsafeBytes { rawBuffer in
            guard var cursor = rawBuffer.baseAddress else { return }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let count = Darwin.write(fd, cursor, remaining)
                if count < 0 {
                    writeError = errno
                    return
                }
                remaining -= count
                cursor = cursor.advanced(by: count)
            }
        }
        if writeError == nil, fsync(fd) != 0 {
            writeError = errno
        }
        let closeResult = close(fd)
        if writeError == nil, closeResult != 0 {
            writeError = errno
        }
        if let code = writeError {
            try? fileManager.removeItem(at: temporary)
            throw StateStoreError.cannotWrite(temporary, code)
        }

        guard rename(temporary.path, destination.path) == 0 else {
            let code = errno
            try? fileManager.removeItem(at: temporary)
            throw StateStoreError.cannotReplace(destination, code)
        }
        _ = chmod(destination.path, 0o600)
        let directoryFD = open(paths.applicationSupport.path, O_RDONLY | O_NOFOLLOW)
        guard directoryFD >= 0 else {
            throw StateStoreError.cannotWrite(paths.applicationSupport, errno)
        }
        defer { close(directoryFD) }
        guard fsync(directoryFD) == 0 else {
            throw StateStoreError.cannotWrite(paths.applicationSupport, errno)
        }
    }
}
