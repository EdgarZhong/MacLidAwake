import AppKit
import Foundation
import IOKit.ps

private nonisolated(unsafe) var agentSignalWriteFD: Int32 = -1

private func agentSignalHandler(_ signalNumber: Int32) {
    let savedErrno = errno
    var byte = UInt8(truncatingIfNeeded: signalNumber)
    if agentSignalWriteFD >= 0 {
        _ = Darwin.write(agentSignalWriteFD, &byte, 1)
    }
    errno = savedErrno
}

public struct AgentTickResult: Equatable, Sendable {
    public let hasValidLeases: Bool
    public let stateChanged: Bool
    public let safetyStopReason: SafetyStopReason?

    public init(
        hasValidLeases: Bool,
        stateChanged: Bool,
        safetyStopReason: SafetyStopReason?
    ) {
        self.hasValidLeases = hasValidLeases
        self.stateChanged = stateChanged
        self.safetyStopReason = safetyStopReason
    }
}

public final class AgentRuntime: @unchecked Sendable {
    private let store: StateStore
    private let processInspector: any ProcessInspecting
    private let safetyReader: any SafetyReading
    private let powerController: any PowerControlling
    private let now: @Sendable () -> Date

    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var batterySource: CFRunLoopSource?
    private var shutdownSource: DispatchSourceRead?
    private var shutdownReadFD: Int32 = -1
    private var shutdownWriteFD: Int32 = -1

    public init(
        store: StateStore,
        processInspector: any ProcessInspecting,
        safetyReader: any SafetyReading,
        powerController: any PowerControlling,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.processInspector = processInspector
        self.safetyReader = safetyReader
        self.powerController = powerController
        self.now = now
    }

    @discardableResult
    public func tick() throws -> AgentTickResult {
        let instant = now()
        let safety = safetyReader.snapshot()
        let outcome: AgentTickResult
        do {
            outcome = try store.withLock { state, config in
                var coordinator = LeaseCoordinator(state: state)
                let reconcile = coordinator.reconcile(
                    now: instant,
                    inspect: processInspector.snapshot(pid:)
                )
                var stopReason: SafetyStopReason?
                if let unsafeReason = SafetyPolicy.stopReason(snapshot: safety, config: config),
                   coordinator.tripSafety(reason: unsafeReason, now: instant) {
                    stopReason = unsafeReason
                }
                state = coordinator.state
                return AgentTickResult(
                    hasValidLeases: coordinator.hasValidLeases,
                    stateChanged: reconcile.changed || stopReason != nil,
                    safetyStopReason: stopReason
                )
            }
        } catch {
            try? powerController.setAwake(false)
            throw error
        }
        try powerController.setAwake(outcome.hasValidLeases)
        return outcome
    }

    public func run() -> Never {
        guard installShutdownHandling() else {
            try? powerController.setAwake(false)
            FileHandle.standardError.write(Data("lidgo agent: cannot install shutdown signal handling\n".utf8))
            exit(1)
        }
        performTick()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.performTick()
        }

        observers.append(NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.performTick()
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.performTick()
        })

        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let runtime = Unmanaged<AgentRuntime>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { runtime.performTick() }
        }, context)?.takeRetainedValue() {
            batterySource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }

        CFRunLoopRun()
        try? powerController.setAwake(false)
        closeShutdownHandling()
        exit(0)
    }

    deinit {
        timer?.invalidate()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        if let batterySource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), batterySource, .defaultMode)
        }
        closeShutdownHandling()
    }

    private func performTick() {
        do {
            _ = try tick()
        } catch {
            let message = "lidgo agent: \(error)\n"
            FileHandle.standardError.write(Data(message.utf8))
        }
    }

    private func installShutdownHandling() -> Bool {
        var descriptors: [Int32] = [-1, -1]
        guard pipe(&descriptors) == 0 else { return false }
        shutdownReadFD = descriptors[0]
        shutdownWriteFD = descriptors[1]
        _ = fcntl(shutdownReadFD, F_SETFD, FD_CLOEXEC)
        _ = fcntl(shutdownWriteFD, F_SETFD, FD_CLOEXEC)
        let flags = fcntl(shutdownWriteFD, F_GETFL)
        if flags >= 0 { _ = fcntl(shutdownWriteFD, F_SETFL, flags | O_NONBLOCK) }
        agentSignalWriteFD = shutdownWriteFD

        for signalNumber in [SIGINT, SIGTERM, SIGHUP, SIGQUIT] {
            _ = Darwin.signal(signalNumber, agentSignalHandler)
        }

        let source = DispatchSource.makeReadSource(
            fileDescriptor: shutdownReadFD,
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var bytes = [UInt8](repeating: 0, count: 16)
            _ = Darwin.read(self.shutdownReadFD, &bytes, bytes.count)
            CFRunLoopStop(CFRunLoopGetMain())
        }
        shutdownSource = source
        source.resume()
        return true
    }

    private func closeShutdownHandling() {
        shutdownSource?.cancel()
        shutdownSource = nil
        if agentSignalWriteFD == shutdownWriteFD { agentSignalWriteFD = -1 }
        if shutdownReadFD >= 0 {
            close(shutdownReadFD)
            shutdownReadFD = -1
        }
        if shutdownWriteFD >= 0 {
            close(shutdownWriteFD)
            shutdownWriteFD = -1
        }
    }
}
