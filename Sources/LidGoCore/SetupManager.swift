import Darwin
import Foundation

public struct SetupCommand: Equatable, Sendable {
    public let executable: String
    public let arguments: [String]

    public init(executable: String, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }
}

public enum SetupError: Error, CustomStringConvertible {
    case unsupportedSystem
    case missingPmset
    case rootRequired
    case commandFailed(SetupCommand, CommandResult)
    case unsafePath(URL)
    case selfCheckFailed(String)

    public var description: String {
        switch self {
        case .unsupportedSystem:
            return "MacLidAwake 只支持 macOS"
        case .missingPmset:
            return "找不到 /usr/bin/pmset；当前系统不受支持"
        case .rootRequired:
            return "内部 root setup 只能通过 lidgo setup 调用"
        case let .commandFailed(command, result):
            return "命令失败（\(result.status)）：\(command.executable) \(command.arguments.joined(separator: " "))\n\(result.output)"
        case let .unsafePath(url):
            return "拒绝写入不安全路径：\(url.path)"
        case let .selfCheckFailed(reason):
            return "setup 自检失败：\(reason)"
        }
    }
}

public final class SetupManager: @unchecked Sendable {
    public static let label = "com.maclidawake.lidgo.agent"
    public static let sudoersPath = URL(fileURLWithPath: "/etc/sudoers.d/maclidawake")

    public static let sudoersRuleText = """
    # MacLidAwake \(LidGoProduct.version), installed by `lidgo setup`
    # Grants exactly the two pmset commands required by MacLidAwake.
    %admin ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0

    """

    private let paths: LidGoPaths
    private let executablePath: String
    private let isTesting: Bool
    private let runner: any CommandRunning
    private let fileManager: FileManager

    public init(
        paths: LidGoPaths,
        executablePath: String,
        isTesting: Bool = false,
        runner: any CommandRunning = ProcessCommandRunner(),
        fileManager: FileManager = .default
    ) {
        self.paths = paths
        self.executablePath = executablePath
        self.isTesting = isTesting
        self.runner = runner
        self.fileManager = fileManager
    }

    public static func rootSetupCommands(
        temporaryRule: URL,
        temporaryLock: URL,
        sudoersRule: URL,
        globalLock: URL
    ) -> [SetupCommand] {
        [
            SetupCommand(
                executable: "/usr/sbin/visudo",
                arguments: ["-cf", temporaryRule.path]
            ),
            SetupCommand(
                executable: "/usr/bin/install",
                arguments: [
                    "-m", "0660", "-o", "root", "-g", "admin",
                    temporaryLock.path, globalLock.path,
                ]
            ),
            SetupCommand(
                executable: "/usr/bin/install",
                arguments: [
                    "-m", "0440", "-o", "root", "-g", "wheel",
                    temporaryRule.path, sudoersRule.path,
                ]
            ),
        ]
    }

    public func setup() throws {
#if !os(macOS)
        throw SetupError.unsupportedSystem
#else
        if !isTesting, !fileManager.isExecutableFile(atPath: GlobalPowerController.pmsetPath) {
            throw SetupError.missingPmset
        }

        _ = try StateStore(paths: paths, fileManager: fileManager).withLock { _, _ in () }
        if isTesting {
            try createTestingGlobalLock()
        } else {
            let command = SetupCommand(
                executable: "/usr/bin/sudo",
                arguments: [executablePath, "__root-setup"]
            )
            try runRequired(command)
        }

        try writeLaunchAgentPlist()
        if !isTesting {
            try reloadLaunchAgent()
        }
        try selfCheck()
#endif
    }

    public func rootSetup() throws {
        guard isTesting || geteuid() == 0 else { throw SetupError.rootRequired }
        if isTesting {
            try createTestingGlobalLock()
            return
        }

        let temporaryDirectory = fileManager.temporaryDirectory.appendingPathComponent(
            "maclidawake-setup-\(getpid())-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? fileManager.removeItem(at: temporaryDirectory) }

        let temporaryRule = temporaryDirectory.appendingPathComponent("sudoers")
        let temporaryLock = temporaryDirectory.appendingPathComponent("global.lock")
        try Self.sudoersRuleText.write(to: temporaryRule, atomically: false, encoding: .utf8)
        guard fileManager.createFile(atPath: temporaryLock.path, contents: Data()) else {
            throw SetupError.unsafePath(temporaryLock)
        }
        guard chmod(temporaryRule.path, 0o440) == 0,
              chmod(temporaryLock.path, 0o600) == 0
        else {
            throw SetupError.unsafePath(temporaryDirectory)
        }

        let commands = Self.rootSetupCommands(
            temporaryRule: temporaryRule,
            temporaryLock: temporaryLock,
            sudoersRule: Self.sudoersPath,
            globalLock: paths.globalParticipationLock
        )
        for command in commands { try runRequired(command) }
    }

    public func launchAgentPlistData() throws -> Data {
        let plist: [String: Any] = [
            "Label": Self.label,
            "ProgramArguments": [executablePath, "__agent"],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Background",
            "StandardOutPath": paths.agentLog.path,
            "StandardErrorPath": paths.agentLog.path,
        ]
        return try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
    }

    public func selfCheck() throws {
        try checkRegularFile(paths.launchAgentPlist, mode: 0o600)
        let data = try Data(contentsOf: paths.launchAgentPlist)
        let object = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard let plist = object as? [String: Any],
              plist["Label"] as? String == Self.label,
              plist["ProgramArguments"] as? [String] == [executablePath, "__agent"],
              plist["RunAtLoad"] as? Bool == true,
              plist["KeepAlive"] as? Bool == true
        else {
            throw SetupError.selfCheckFailed("LaunchAgent 内容不匹配")
        }
        try checkDirectory(paths.applicationSupport, mode: 0o700)
        if isTesting {
            try checkRegularFile(paths.globalParticipationLock, mode: 0o660)
        } else {
            try checkProductionRootFiles()
        }
    }

    private func createTestingGlobalLock() throws {
        let descriptor = open(
            paths.globalParticipationLock.path,
            O_RDWR | O_CREAT | O_NOFOLLOW,
            0o660
        )
        guard descriptor >= 0 else {
            throw SetupError.unsafePath(paths.globalParticipationLock)
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              fchmod(descriptor, 0o660) == 0
        else {
            throw SetupError.unsafePath(paths.globalParticipationLock)
        }
    }

    private func writeLaunchAgentPlist() throws {
        let parent = paths.launchAgentPlist.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let data = try launchAgentPlistData()
        let temporary = parent.appendingPathComponent(
            ".\(paths.launchAgentPlist.lastPathComponent).\(getpid()).\(UUID().uuidString).tmp"
        )
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw SetupError.unsafePath(temporary) }
        var failure: Int32?
        data.withUnsafeBytes { buffer in
            guard var cursor = buffer.baseAddress else { return }
            var remaining = buffer.count
            while remaining > 0 {
                let count = Darwin.write(descriptor, cursor, remaining)
                if count < 0 {
                    failure = errno
                    return
                }
                remaining -= count
                cursor = cursor.advanced(by: count)
            }
        }
        if failure == nil, fsync(descriptor) != 0 { failure = errno }
        if close(descriptor) != 0, failure == nil { failure = errno }
        if let failure {
            _ = unlink(temporary.path)
            throw SetupError.selfCheckFailed("无法写入 LaunchAgent：\(String(cString: strerror(failure)))")
        }
        guard rename(temporary.path, paths.launchAgentPlist.path) == 0 else {
            let failure = errno
            _ = unlink(temporary.path)
            throw SetupError.selfCheckFailed("无法安装 LaunchAgent：\(String(cString: strerror(failure)))")
        }
        guard chmod(paths.launchAgentPlist.path, 0o600) == 0 else {
            throw SetupError.unsafePath(paths.launchAgentPlist)
        }
    }

    private func reloadLaunchAgent() throws {
        let domain = "gui/\(getuid())"
        _ = runner.run(
            executable: "/bin/launchctl",
            arguments: ["bootout", domain, paths.launchAgentPlist.path]
        )
        try runRequired(SetupCommand(
            executable: "/bin/launchctl",
            arguments: ["bootstrap", domain, paths.launchAgentPlist.path]
        ))
        try runRequired(SetupCommand(
            executable: "/bin/launchctl",
            arguments: ["kickstart", "-k", "\(domain)/\(Self.label)"]
        ))
    }

    private func checkProductionRootFiles() throws {
        var lockInfo = stat()
        guard lstat(paths.globalParticipationLock.path, &lockInfo) == 0,
              lockInfo.st_mode & S_IFMT == S_IFREG,
              lockInfo.st_uid == 0,
              lockInfo.st_gid == getgrnam("admin")?.pointee.gr_gid,
              lockInfo.st_mode & 0o777 == 0o660
        else {
            throw SetupError.selfCheckFailed("全局锁的 owner/group/mode 不正确")
        }

        var ruleInfo = stat()
        guard lstat(Self.sudoersPath.path, &ruleInfo) == 0,
              ruleInfo.st_mode & S_IFMT == S_IFREG,
              ruleInfo.st_uid == 0,
              ruleInfo.st_gid == getgrnam("wheel")?.pointee.gr_gid,
              ruleInfo.st_mode & 0o777 == 0o440
        else {
            throw SetupError.selfCheckFailed("sudoers 的 owner/group/mode 不正确")
        }
        let listing = runner.run(executable: "/usr/bin/sudo", arguments: ["-n", "-l"])
        let normalizedListing = listing.output
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        let expectedGrant = "NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0"
        guard listing.status == 0,
              normalizedListing.contains(expectedGrant)
        else {
            throw SetupError.selfCheckFailed("未找到两条精确的 NOPASSWD pmset 授权")
        }
    }

    private func checkDirectory(_ url: URL, mode: mode_t) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR,
              info.st_mode & 0o777 == mode
        else {
            throw SetupError.selfCheckFailed("目录不安全：\(url.path)")
        }
    }

    private func checkRegularFile(_ url: URL, mode: mode_t) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o777 == mode
        else {
            throw SetupError.selfCheckFailed("文件不安全：\(url.path)")
        }
    }

    private func runRequired(_ command: SetupCommand) throws {
        let result = runner.run(executable: command.executable, arguments: command.arguments)
        guard result.status == 0 else { throw SetupError.commandFailed(command, result) }
    }
}
