import Foundation
import LidGoCore

final class FakeProcessInspector: ProcessInspecting, @unchecked Sendable {
    var snapshots: [Int32: ProcessSnapshot] = [:]

    func snapshot(pid: Int32) -> ProcessSnapshot? {
        snapshots[pid]
    }
}

final class FakeSafetyReader: SafetyReading, @unchecked Sendable {
    var value = SafetySnapshot(batteryPercent: 80, thermalState: .nominal)

    func snapshot() -> SafetySnapshot {
        value
    }
}

final class FakePowerController: PowerControlling, @unchecked Sendable {
    var targets: [Bool] = []

    func setAwake(_ awake: Bool) throws {
        targets.append(awake)
    }
}

final class MutableClock: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
}

@MainActor
final class AgentRuntimeTests {
    private let now = Date(timeIntervalSince1970: 2_100_000_000)

    func testTimerExpiresWhileLiveHoldRemainsActive() throws {
        try withFixture { fixture in
            let owner = ProcessSnapshot(pid: 51, startTime: 501, status: .running)
            fixture.processes.snapshots[owner.pid] = owner
            try fixture.store.withLock { state, _ in
                state.timer = TimerLease(
                    createdAt: now.addingTimeInterval(-100),
                    deadline: now.addingTimeInterval(-1),
                    generation: state.generation
                )
                state.holds = [HoldLease(
                    pid: owner.pid,
                    processStartTime: owner.startTime,
                    generation: state.generation,
                    createdAt: now.addingTimeInterval(-50)
                )]
            }

            let result = try fixture.runtime.tick()
            let state = try fixture.store.withLock { state, _ in state }
            XCTAssertTrue(result.hasValidLeases)
            XCTAssertNil(state.timer)
            XCTAssertEqual(state.holds.count, 1)
            XCTAssertEqual(fixture.power.targets.last, true)
        }
    }

    func testStoppedOrReusedProcessCannotKeepAwake() throws {
        try withFixture { fixture in
            let hold = HoldLease(
                pid: 61,
                processStartTime: 601,
                generation: 0,
                createdAt: now
            )
            try fixture.store.withLock { state, _ in state.holds = [hold] }
            fixture.processes.snapshots[61] = ProcessSnapshot(
                pid: 61,
                startTime: 601,
                status: .stopped
            )

            let stopped = try fixture.runtime.tick()
            XCTAssertFalse(stopped.hasValidLeases)
            XCTAssertEqual(fixture.power.targets.last, false)

            try fixture.store.withLock { state, _ in state.holds = [hold] }
            fixture.processes.snapshots[61] = ProcessSnapshot(
                pid: 61,
                startTime: 999,
                status: .running
            )
            let reused = try fixture.runtime.tick()
            XCTAssertFalse(reused.hasValidLeases)
        }
    }

    func testBatteryTripClearsAllLeasesAndDoesNotAutoResume() throws {
        try withFixture { fixture in
            try fixture.store.withLock { state, config in
                config.batteryCutoffPercent = 15
                state.timer = TimerLease(now: now, duration: 3_600, generation: 0)
            }
            fixture.safety.value = SafetySnapshot(batteryPercent: 15, thermalState: .nominal)

            let tripped = try fixture.runtime.tick()
            let stateAfterTrip = try fixture.store.withLock { state, _ in state }
            XCTAssertEqual(tripped.safetyStopReason, .battery)
            XCTAssertFalse(stateAfterTrip.timer != nil || !stateAfterTrip.holds.isEmpty)
            XCTAssertEqual(stateAfterTrip.generation, 1)
            XCTAssertEqual(fixture.power.targets.last, false)

            fixture.safety.value = SafetySnapshot(batteryPercent: 90, thermalState: .nominal)
            let recoveredConditions = try fixture.runtime.tick()
            XCTAssertFalse(recoveredConditions.hasValidLeases)
            XCTAssertFalse(fixture.power.targets.contains(true))
        }
    }

    func testCriticalThermalTripClearsLeasesPermanently() throws {
        try withFixture { fixture in
            try fixture.store.withLock { state, _ in
                state.timer = TimerLease(now: now, duration: 3_600, generation: 0)
            }
            fixture.safety.value = SafetySnapshot(batteryPercent: 80, thermalState: .critical)

            let result = try fixture.runtime.tick()
            let state = try fixture.store.withLock { state, _ in state }
            XCTAssertEqual(result.safetyStopReason, .thermal)
            XCTAssertFalse(result.hasValidLeases)
            XCTAssertEqual(state.generation, 1)
            XCTAssertEqual(state.lastSafetyStop?.reason, .thermal)
        }
    }

    func testUnreadableBatteryFailsSafeAndLatchesOff() throws {
        try withFixture { fixture in
            try fixture.store.withLock { state, _ in
                state.timer = TimerLease(now: now, duration: 3_600, generation: 0)
            }
            fixture.safety.value = SafetySnapshot(batteryPercent: nil, thermalState: .nominal)

            let result = try fixture.runtime.tick()
            let state = try fixture.store.withLock { state, _ in state }
            XCTAssertEqual(result.safetyStopReason, .batteryUnavailable)
            XCTAssertFalse(result.hasValidLeases)
            XCTAssertEqual(state.generation, 1)
            XCTAssertEqual(state.lastSafetyStop?.reason, .batteryUnavailable)
        }
    }

    func testEmptyAndCorruptStateFailSafeToSleep() throws {
        try withFixture { fixture in
            let empty = try fixture.runtime.tick()
            XCTAssertFalse(empty.hasValidLeases)
            XCTAssertEqual(fixture.power.targets.last, false)

            try Data("bad-state".utf8).write(to: fixture.store.paths.stateFile)
            let corrupt = try fixture.runtime.tick()
            XCTAssertFalse(corrupt.hasValidLeases)
            XCTAssertEqual(fixture.power.targets.last, false)
        }
    }

    private func withFixture(_ body: (AgentFixture) throws -> Void) throws {
        let fixture = try AgentFixture(now: now)
        defer { fixture.cleanup() }
        try body(fixture)
    }
}

final class AgentFixture {
    let root: URL
    let store: StateStore
    let processes = FakeProcessInspector()
    let safety = FakeSafetyReader()
    let power = FakePowerController()
    let clock: MutableClock
    let runtime: AgentRuntime

    init(now: Date) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lidgo-agent-tests-\(UUID().uuidString)", isDirectory: true)
        store = StateStore(paths: .testing(root: root))
        clock = MutableClock(now)
        runtime = AgentRuntime(
            store: store,
            processInspector: processes,
            safetyReader: safety,
            powerController: power,
            now: { [clock] in clock.now }
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
