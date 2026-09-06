import AppKit
import Foundation
import IOKit.ps

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
        exit(0)
    }

    deinit {
        timer?.invalidate()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        if let batterySource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), batterySource, .defaultMode)
        }
    }

    private func performTick() {
        do {
            _ = try tick()
        } catch {
            let message = "lidgo agent: \(error)\n"
            FileHandle.standardError.write(Data(message.utf8))
        }
    }
}
