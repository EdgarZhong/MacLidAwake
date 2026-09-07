import Darwin
import Foundation

public protocol AgentNotifying: Sendable {
    func kick() throws
}

public enum AgentNotifierError: Error, CustomStringConvertible {
    case commandFailed(CommandResult)

    public var description: String {
        switch self {
        case let .commandFailed(result):
            return "Cannot wake the LidGo agent (\(result.status)): \(result.output); run lidgo setup"
        }
    }
}

public struct LaunchAgentNotifier: AgentNotifying {
    private let runner: any CommandRunning
    private let userID: uid_t

    public init(
        runner: any CommandRunning = ProcessCommandRunner(),
        userID: uid_t = getuid()
    ) {
        self.runner = runner
        self.userID = userID
    }

    public func kick() throws {
        let result = runner.run(
            executable: "/bin/launchctl",
            arguments: ["kickstart", "gui/\(userID)/\(SetupManager.label)"]
        )
        guard result.status == 0 else { throw AgentNotifierError.commandFailed(result) }
    }
}

public struct NoopAgentNotifier: AgentNotifying {
    public init() {}
    public func kick() throws {}
}

public enum HoldSessionError: Error, CustomStringConvertible {
    case cannotCreateSignalPipe(Int32)
    case invalidOwner
    case unsafe(SafetyStopReason)
    case notStarted

    public var description: String {
        switch self {
        case let .cannotCreateSignalPipe(code):
            return "Cannot create signal pipe: \(String(cString: strerror(code)))"
        case .invalidOwner:
            return "Cannot verify the identity of the current Hold process"
        case let .unsafe(reason):
            return "Safety conditions do not allow starting a Hold: \(reason.rawValue)"
        case .notStarted:
            return "Hold has not started"
        }
    }
}

private nonisolated(unsafe) var lidGoSignalWriteFD: Int32 = -1

private func lidGoSignalHandler(_ signalNumber: Int32) {
    let savedErrno = errno
    var byte = UInt8(truncatingIfNeeded: signalNumber)
    if lidGoSignalWriteFD >= 0 {
        _ = Darwin.write(lidGoSignalWriteFD, &byte, 1)
    }
    errno = savedErrno
}

public final class HoldSession: @unchecked Sendable {
    private let store: StateStore
    private let processInspector: any ProcessInspecting
    private let safetyReader: any SafetyReading
    private let agentNotifier: any AgentNotifying
    private let pid: Int32
    private let now: @Sendable () -> Date
    private let holdID: UUID

    private var originalHold: HoldLease?
    private var readFD: Int32 = -1
    private var writeFD: Int32 = -1

    public init(
        store: StateStore,
        processInspector: any ProcessInspecting,
        safetyReader: any SafetyReading,
        agentNotifier: any AgentNotifying,
        pid: Int32 = getpid(),
        holdID: UUID = UUID(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.processInspector = processInspector
        self.safetyReader = safetyReader
        self.agentNotifier = agentNotifier
        self.pid = pid
        self.holdID = holdID
        self.now = now
    }

    deinit {
        closeSignalPipe()
    }

    @discardableResult
    public func begin() throws -> HoldLease {
        guard let owner = processInspector.snapshot(pid: pid), owner.status.canOwnHold else {
            throw HoldSessionError.invalidOwner
        }
        let safety = safetyReader.snapshot()
        let instant = now()
        let result: Result<HoldLease, HoldSessionError> = try store.withLock { state, config in
            var coordinator = LeaseCoordinator(state: state)
            _ = coordinator.reconcile(now: instant, inspect: processInspector.snapshot(pid:))
            if let reason = SafetyPolicy.stopReason(snapshot: safety, config: config) {
                _ = coordinator.tripSafety(reason: reason, now: instant)
                state = coordinator.state
                return .failure(.unsafe(reason))
            }
            let hold = coordinator.addHold(
                id: holdID,
                pid: owner.pid,
                processStartTime: owner.startTime,
                now: instant
            )
            state = coordinator.state
            return .success(hold)
        }
        switch result {
        case let .success(hold):
            originalHold = hold
            do {
                try agentNotifier.kick()
            } catch {
                try? release()
                throw error
            }
            return hold
        case let .failure(error):
            try? agentNotifier.kick()
            throw error
        }
    }

    public func release() throws {
        guard let originalHold else { return }
        let changed = try store.withLock { state, _ in
            var coordinator = LeaseCoordinator(state: state)
            let removed = coordinator.removeHold(id: originalHold.id)
            state = coordinator.state
            return removed
        }
        if changed { try agentNotifier.kick() }
    }

    @discardableResult
    public func resume() throws -> HoldResumeResult {
        guard let originalHold else { throw HoldSessionError.notStarted }
        guard let owner = processInspector.snapshot(pid: pid) else {
            return .invalidOwner
        }
        let safety = safetyReader.snapshot()
        let instant = now()
        let result = try store.withLock { state, config in
            var coordinator = LeaseCoordinator(state: state)
            _ = coordinator.reconcile(now: instant, inspect: processInspector.snapshot(pid:))
            if let reason = SafetyPolicy.stopReason(snapshot: safety, config: config) {
                _ = coordinator.tripSafety(reason: reason, now: instant)
                state = coordinator.state
                return HoldResumeResult.revoked
            }
            let resumed = coordinator.resumeHold(originalHold, now: instant, snapshot: owner)
            state = coordinator.state
            return resumed
        }
        if case .resumed = result { try agentNotifier.kick() }
        if case .revoked = result { try? agentNotifier.kick() }
        return result
    }

    public func run() throws -> Int32 {
        try installSignalPipe()
        _ = try begin()
        print("LidGo Hold started")
        print("Press Ctrl-C to end")
        fflush(stdout)
        defer { try? release() }

        while true {
            var descriptor = pollfd(fd: readFD, events: Int16(POLLIN), revents: 0)
            let pollResult = Darwin.poll(&descriptor, 1, 250)
            if pollResult < 0 {
                if errno == EINTR { continue }
                throw HoldSessionError.cannotCreateSignalPipe(errno)
            }
            if pollResult > 0, descriptor.revents & Int16(POLLIN) != 0 {
                var bytes = [UInt8](repeating: 0, count: 32)
                let count = Darwin.read(readFD, &bytes, bytes.count)
                if count > 0 {
                    for byte in bytes.prefix(Int(count)) {
                        if let status = try handleSignal(Int32(byte)) { return status }
                    }
                }
            }

            var pending = pollfd(fd: readFD, events: Int16(POLLIN), revents: 0)
            if Darwin.poll(&pending, 1, 0) > 0,
               pending.revents & Int16(POLLIN) != 0 {
                continue
            }
            if try leaseWasRevoked() {
                print("LidGo Hold was globally revoked")
                return 0
            }
        }
    }

    private func handleSignal(_ signalNumber: Int32) throws -> Int32? {
        switch signalNumber {
        case SIGINT, SIGTERM, SIGHUP, SIGQUIT:
            try release()
            return 0
        case SIGTSTP:
            try release()
            _ = kill(pid, SIGSTOP)
            return try restoreAfterContinue()
        case SIGCONT:
            return try restoreAfterContinue()
        default:
            return nil
        }
    }

    private func restoreAfterContinue() throws -> Int32? {
        switch try resume() {
        case .resumed:
            print("LidGo Hold resumed")
            return nil
        case .alreadyActive:
            return nil
        case .revoked:
            print("LidGo Hold was globally revoked and cannot resume")
            return 0
        case .invalidOwner:
            throw HoldSessionError.invalidOwner
        }
    }

    private func leaseWasRevoked() throws -> Bool {
        guard let originalHold else { return true }
        return try store.withLock { state, _ in
            guard state.generation == originalHold.generation else { return true }
            return !state.holds.contains(where: { $0.id == originalHold.id })
        }
    }

    private func installSignalPipe() throws {
        var descriptors: [Int32] = [-1, -1]
        guard pipe(&descriptors) == 0 else {
            throw HoldSessionError.cannotCreateSignalPipe(errno)
        }
        readFD = descriptors[0]
        writeFD = descriptors[1]
        _ = fcntl(readFD, F_SETFD, FD_CLOEXEC)
        _ = fcntl(writeFD, F_SETFD, FD_CLOEXEC)
        let flags = fcntl(writeFD, F_GETFL)
        if flags >= 0 { _ = fcntl(writeFD, F_SETFL, flags | O_NONBLOCK) }
        lidGoSignalWriteFD = writeFD

        for signalNumber in [SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGTSTP, SIGCONT] {
            _ = Darwin.signal(signalNumber, lidGoSignalHandler)
        }
    }

    private func closeSignalPipe() {
        if lidGoSignalWriteFD == writeFD { lidGoSignalWriteFD = -1 }
        if readFD >= 0 { close(readFD); readFD = -1 }
        if writeFD >= 0 { close(writeFD); writeFD = -1 }
    }
}
