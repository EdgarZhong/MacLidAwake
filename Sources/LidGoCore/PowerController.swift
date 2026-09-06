import Darwin
import Foundation

public struct CommandResult: Equatable, Sendable {
    public let status: Int32
    public let output: String

    public init(status: Int32, output: String) {
        self.status = status
        self.output = output
    }
}

public protocol CommandRunning: Sendable {
    func run(executable: String, arguments: [String]) -> CommandResult
}

public final class ProcessCommandRunner: CommandRunning, @unchecked Sendable {
    public init() {}

    public func run(executable: String, arguments: [String]) -> CommandResult {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return CommandResult(status: -1, output: String(describing: error))
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandResult(
            status: process.terminationStatus,
            output: String(data: data, encoding: .utf8) ?? ""
        )
    }
}

public protocol PowerControlling: Sendable {
    func setAwake(_ awake: Bool) throws
}

public enum PowerControllerError: Error, CustomStringConvertible {
    case cannotOpenLock(URL, Int32)
    case unsafeLock(URL)
    case cannotLock(URL, Int32)
    case commandFailed(arguments: [String], result: CommandResult)

    public var description: String {
        switch self {
        case let .cannotOpenLock(url, code):
            return "无法打开全局参与锁 \(url.path)：\(String(cString: strerror(code)))"
        case let .unsafeLock(url):
            return "全局参与锁不安全：\(url.path)"
        case let .cannotLock(url, code):
            return "无法取得全局参与锁 \(url.path)：\(String(cString: strerror(code)))"
        case let .commandFailed(arguments, result):
            return "特权命令失败（\(result.status)）：\(arguments.joined(separator: " ")) \(result.output)"
        }
    }
}

public final class GlobalPowerController: PowerControlling, @unchecked Sendable {
    public static let sudoPath = "/usr/bin/sudo"
    public static let pmsetPath = "/usr/bin/pmset"

    private let lockPath: URL
    private let runner: any CommandRunning
    private let lockFD: Int32
    private let processLock = NSLock()
    private var participating = false
    private var lastTarget: Bool?

    public init(lockPath: URL, runner: any CommandRunning = ProcessCommandRunner()) throws {
        self.lockPath = lockPath
        self.runner = runner
        lockFD = open(lockPath.path, O_RDWR | O_NOFOLLOW)
        guard lockFD >= 0 else {
            throw PowerControllerError.cannotOpenLock(lockPath, errno)
        }

        var metadata = stat()
        guard fstat(lockFD, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
            close(lockFD)
            throw PowerControllerError.unsafeLock(lockPath)
        }
        if lockPath.path == "/var/db/maclidawake.lock" {
            let permissions = metadata.st_mode & 0o777
            let adminGroupID = getgrnam("admin").map { $0.pointee.gr_gid }
            guard metadata.st_uid == 0,
                  metadata.st_gid == adminGroupID,
                  permissions == 0o660
            else {
                close(lockFD)
                throw PowerControllerError.unsafeLock(lockPath)
            }
        }
    }

    deinit {
        if participating {
            _ = flock(lockFD, LOCK_UN)
        }
        close(lockFD)
    }

    public func setAwake(_ awake: Bool) throws {
        processLock.lock()
        defer { processLock.unlock() }
        guard lastTarget != awake else { return }

        if awake {
            guard flock(lockFD, LOCK_SH) == 0 else {
                throw PowerControllerError.cannotLock(lockPath, errno)
            }
            participating = true
            let arguments = ["-n", Self.pmsetPath, "-a", "disablesleep", "1"]
            let result = runner.run(executable: Self.sudoPath, arguments: arguments)
            guard result.status == 0 else {
                _ = flock(lockFD, LOCK_UN)
                participating = false
                lastTarget = nil
                throw PowerControllerError.commandFailed(arguments: arguments, result: result)
            }
            lastTarget = true
            return
        }

        if participating {
            _ = flock(lockFD, LOCK_UN)
            participating = false
        }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK || errno == EAGAIN {
                lastTarget = false
                return
            }
            lastTarget = nil
            throw PowerControllerError.cannotLock(lockPath, errno)
        }
        defer { flock(lockFD, LOCK_UN) }

        let arguments = ["-n", Self.pmsetPath, "-a", "disablesleep", "0"]
        let result = runner.run(executable: Self.sudoPath, arguments: arguments)
        guard result.status == 0 else {
            lastTarget = nil
            throw PowerControllerError.commandFailed(arguments: arguments, result: result)
        }
        lastTarget = false
    }
}
