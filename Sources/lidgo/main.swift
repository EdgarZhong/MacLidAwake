import Darwin
import Foundation
import LidGoCore

private enum CLIError: Error, CustomStringConvertible {
    case unsafe(SafetyStopReason)

    var description: String {
        switch self {
        case let .unsafe(reason):
            switch reason {
            case .battery:
                return "Battery has reached the safety cutoff; LidGo stays off"
            case .batteryUnavailable:
                return "Battery status is unavailable; LidGo stays off as a safety precaution"
            case .thermal:
                return "Thermal pressure is too high; LidGo stays off"
            }
        }
    }
}

private struct EnvironmentSafetyReader: SafetyReading {
    let environment: [String: String]

    func snapshot() -> SafetySnapshot {
        let rawBattery = environment["LIDGO_TEST_BATTERY"] ?? "80"
        let battery = rawBattery == "unavailable" ? nil : Int(rawBattery)
        let thermal = LidGoThermalState(
            rawValue: environment["LIDGO_TEST_THERMAL"] ?? "nominal"
        ) ?? .critical
        return SafetySnapshot(batteryPercent: battery, thermalState: thermal)
    }
}

private final class TestingPowerController: PowerControlling, @unchecked Sendable {
    private let logURL: URL
    private let lock = NSLock()

    init(logURL: URL) {
        self.logURL = logURL
    }

    func setAwake(_ awake: Bool) throws {
        lock.lock()
        defer { lock.unlock() }
        let descriptor = open(logURL.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { close(descriptor) }
        var bytes = Array("\(awake ? 1 : 0)\n".utf8)
        _ = Darwin.write(descriptor, &bytes, bytes.count)
    }
}

private enum TransactionOutput {
    case text(String)
    case unsafe(SafetyStopReason)
}

private func executablePath() -> String {
    Bundle.main.executablePath ?? URL(fileURLWithPath: CommandLine.arguments[0]).standardized.path
}

private func activate(
    store: StateStore,
    inspector: any ProcessInspecting,
    safetyReader: any SafetyReading,
    now: Date
) throws -> TransactionOutput {
    let safety = safetyReader.snapshot()
    return try store.withLock { state, config in
        var coordinator = LeaseCoordinator(state: state)
        _ = coordinator.reconcile(now: now, inspect: inspector.snapshot(pid:))
        if let reason = SafetyPolicy.stopReason(snapshot: safety, config: config) {
            _ = coordinator.tripSafety(reason: reason, now: now)
            state = coordinator.state
            return .unsafe(reason)
        }
        let result = coordinator.activateDefault(
            now: now,
            config: config,
            inspect: inspector.snapshot(pid:)
        )
        state = coordinator.state
        switch result {
        case let .created(timer):
            return .text(StatusFormatter.timerCreated(timer, now: now))
        case let .unchanged(summary):
            return .text(StatusFormatter.active(summary, now: now))
        }
    }
}

private func refresh(
    store: StateStore,
    inspector: any ProcessInspecting,
    safetyReader: any SafetyReading,
    now: Date
) throws -> TransactionOutput {
    let safety = safetyReader.snapshot()
    return try store.withLock { state, config in
        var coordinator = LeaseCoordinator(state: state)
        _ = coordinator.reconcile(now: now, inspect: inspector.snapshot(pid:))
        if !coordinator.state.holds.isEmpty {
            state = coordinator.state
            return .text("Cannot refresh: a Hold is active\nEnd the Hold session first")
        }
        if let reason = SafetyPolicy.stopReason(snapshot: safety, config: config) {
            _ = coordinator.tripSafety(reason: reason, now: now)
            state = coordinator.state
            return .unsafe(reason)
        }
        let result = coordinator.refresh(
            now: now,
            config: config,
            inspect: inspector.snapshot(pid:)
        )
        state = coordinator.state
        switch result {
        case let .created(timer):
            return .text(StatusFormatter.timerCreated(timer, now: now))
        case let .refreshed(timer):
            return .text(StatusFormatter.timerRefreshed(timer, now: now))
        case .rejectedBecauseHold:
            return .text("Cannot refresh: a Hold is active\nEnd the Hold session first")
        }
    }
}

private func forceToggle(
    store: StateStore,
    inspector: any ProcessInspecting,
    safetyReader: any SafetyReading,
    now: Date
) throws -> TransactionOutput {
    let safety = safetyReader.snapshot()
    return try store.withLock { state, config in
        var coordinator = LeaseCoordinator(state: state)
        _ = coordinator.reconcile(now: now, inspect: inspector.snapshot(pid:))
        if !coordinator.hasValidLeases,
           let reason = SafetyPolicy.stopReason(snapshot: safety, config: config) {
            _ = coordinator.tripSafety(reason: reason, now: now)
            state = coordinator.state
            return .unsafe(reason)
        }
        let result = coordinator.forceToggle(
            now: now,
            config: config,
            inspect: inspector.snapshot(pid:)
        )
        state = coordinator.state
        switch result {
        case let .turnedOn(timer):
            return .text(StatusFormatter.timerCreated(timer, now: now))
        case .turnedOff:
            return .text("LidGo force-disabled\nNormal sleep restored")
        }
    }
}

private func updateConfig(store: StateStore, update: ConfigUpdate) throws -> String {
    try store.withLock { _, config in
        if let duration = update.defaultDurationSeconds {
            config.defaultDurationSeconds = duration
        }
        if let battery = update.batteryCutoffPercent {
            config.batteryCutoffPercent = battery
        }
        return StatusFormatter.configuration(config)
    }
}

private func printTransaction(_ output: TransactionOutput) throws {
    switch output {
    case let .text(text):
        print(text)
    case let .unsafe(reason):
        throw CLIError.unsafe(reason)
    }
}

private func run() throws -> Int32 {
    let arguments = Array(CommandLine.arguments.dropFirst())
    let command = try LidGoCommand.parse(arguments)
    if command == .help {
        print(StatusFormatter.help)
        return 0
    }
    if command == .switchNeedsForce {
        print("switch force-changes the current global state")
        print("Run lidgo switch -f to confirm")
        return 1
    }

    let environment = ProcessInfo.processInfo.environment
    let isTesting = environment["LIDGO_TESTING"] == "1"
    let paths = LidGoPaths.production(environment: environment)
    let store = StateStore(paths: paths)
    let inspector = DarwinProcessInspector()
    let safetyReader: any SafetyReading = isTesting
        ? EnvironmentSafetyReader(environment: environment)
        : SystemSafetyReader()
    let notifier: any AgentNotifying = isTesting
        ? NoopAgentNotifier()
        : LaunchAgentNotifier()
    let manager = SetupManager(
        paths: paths,
        executablePath: executablePath(),
        isTesting: isTesting
    )

    switch command {
    case .help, .switchNeedsForce:
        return 0
    case .setup:
        try manager.setup()
        print("MacLidAwake setup completed and passed self-checks")
        return 0
    case .rootSetup:
        try manager.rootSetup()
        return 0
    case .agent:
        let power: any PowerControlling = isTesting
            ? TestingPowerController(logURL: paths.applicationSupport.appendingPathComponent("power.log"))
            : try GlobalPowerController(lockPath: paths.globalParticipationLock)
        AgentRuntime(
            store: store,
            processInspector: inspector,
            safetyReader: safetyReader,
            powerController: power
        ).run()
    case let .config(update):
        print(try updateConfig(store: store, update: update))
        if !isTesting { try? notifier.kick() }
        return 0
    case .activate, .refresh, .hold, .switchForce:
        if !isTesting { try manager.selfCheck() }
    }

    let instant = Date()
    switch command {
    case .activate:
        let output = try activate(
            store: store,
            inspector: inspector,
            safetyReader: safetyReader,
            now: instant
        )
        try notifier.kick()
        try printTransaction(output)
    case .refresh:
        let output = try refresh(
            store: store,
            inspector: inspector,
            safetyReader: safetyReader,
            now: instant
        )
        try notifier.kick()
        try printTransaction(output)
    case .switchForce:
        let output = try forceToggle(
            store: store,
            inspector: inspector,
            safetyReader: safetyReader,
            now: instant
        )
        try notifier.kick()
        try printTransaction(output)
    case .hold:
        return try HoldSession(
            store: store,
            processInspector: inspector,
            safetyReader: safetyReader,
            agentNotifier: notifier
        ).run()
    case .config, .setup, .help, .switchNeedsForce, .agent, .rootSetup:
        break
    }
    return 0
}

do {
    exit(try run())
} catch {
    FileHandle.standardError.write(Data("lidgo: \(error)\n".utf8))
    exit(2)
}
