import Foundation
import LidGoCore

final class FakeAgentNotifier: AgentNotifying, @unchecked Sendable {
    var kickCount = 0

    func kick() throws {
        kickCount += 1
    }
}

@MainActor
final class HoldSessionTests {
    private let now = Date(timeIntervalSince1970: 2_200_000_000)

    func testBeginAndReleaseOwnLease() throws {
        try withFixture { fixture in
            let hold = try fixture.session.begin()
            let active = try fixture.store.withLock { state, _ in state.holds }
            XCTAssertEqual(active, [hold])

            try fixture.session.release()
            let released = try fixture.store.withLock { state, _ in state.holds }
            XCTAssertTrue(released.isEmpty)
            XCTAssertEqual(fixture.notifier.kickCount, 2)
        }
    }

    func testResumeRequiresSameGenerationAndSafeConditions() throws {
        try withFixture { fixture in
            let hold = try fixture.session.begin()
            try fixture.session.release()
            try XCTAssertEqual(try fixture.session.resume(), .resumed(hold))

            try fixture.store.withLock { state, config in
                var coordinator = LeaseCoordinator(state: state)
                _ = coordinator.forceToggle(
                    now: now,
                    config: config,
                    inspect: fixture.processes.snapshot(pid:)
                )
                state = coordinator.state
            }
            try XCTAssertEqual(try fixture.session.resume(), .revoked)
        }

        try withFixture { fixture in
            _ = try fixture.session.begin()
            try fixture.session.release()
            fixture.safety.value = SafetySnapshot(batteryPercent: 80, thermalState: .critical)
            try XCTAssertEqual(try fixture.session.resume(), .revoked)
            let state = try fixture.store.withLock { state, _ in state }
            XCTAssertEqual(state.lastSafetyStop?.reason, .thermal)
            XCTAssertTrue(state.holds.isEmpty)
        }
    }

    private func withFixture(_ body: (HoldFixture) throws -> Void) throws {
        let fixture = HoldFixture(now: now)
        defer { fixture.cleanup() }
        try body(fixture)
    }
}

final class HoldFixture {
    let root: URL
    let store: StateStore
    let processes = FakeProcessInspector()
    let safety = FakeSafetyReader()
    let notifier = FakeAgentNotifier()
    let session: HoldSession

    init(now: Date) {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lidgo-hold-tests-\(UUID().uuidString)", isDirectory: true)
        store = StateStore(paths: .testing(root: root))
        let owner = ProcessSnapshot(pid: 901, startTime: 9_001, status: .running)
        processes.snapshots[owner.pid] = owner
        session = HoldSession(
            store: store,
            processInspector: processes,
            safetyReader: safety,
            agentNotifier: notifier,
            pid: owner.pid,
            now: { now }
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
