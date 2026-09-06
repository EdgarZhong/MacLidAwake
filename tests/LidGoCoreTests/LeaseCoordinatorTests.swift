import Foundation
import LidGoCore

@MainActor
final class LeaseCoordinatorTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func inspector(_ snapshots: [Int32: ProcessSnapshot]) -> (Int32) -> ProcessSnapshot? {
        { snapshots[$0] }
    }

    func testDefaultCreatesTimerThenRemainsIdempotent() throws {
        var coordinator = LeaseCoordinator()

        let first = coordinator.activateDefault(
            now: now,
            config: .default,
            inspect: inspector([:])
        )
        guard case let .created(timer) = first else {
            return XCTFail("OFF 时应创建 Timer")
        }
        XCTAssertEqual(timer.deadline, now.addingTimeInterval(3_600))

        let second = coordinator.activateDefault(
            now: now.addingTimeInterval(600),
            config: .default,
            inspect: inspector([:])
        )
        guard case let .unchanged(summary) = second else {
            return XCTFail("已有 Timer 时默认命令必须幂等")
        }
        XCTAssertEqual(summary.timer?.deadline, timer.deadline)
    }

    func testRefreshCreatesOrRefreshesOnlyPureTimerState() {
        var off = LeaseCoordinator()
        guard case let .created(created) = off.refresh(
            now: now,
            config: .default,
            inspect: inspector([:])
        ) else {
            return XCTFail("OFF refresh 应创建 Timer")
        }
        XCTAssertEqual(created.deadline, now.addingTimeInterval(3_600))

        guard case let .refreshed(refreshed) = off.refresh(
            now: now.addingTimeInterval(300),
            config: LidGoConfig(defaultDurationSeconds: 7_200, batteryCutoffPercent: 15),
            inspect: inspector([:])
        ) else {
            return XCTFail("纯 Timer 应刷新")
        }
        XCTAssertEqual(refreshed.deadline, now.addingTimeInterval(7_500))

        let owner = ProcessSnapshot(pid: 42, startTime: 123, status: .running)
        _ = off.addHold(pid: owner.pid, processStartTime: owner.startTime, now: now)
        let before = off.state
        XCTAssertEqual(
            off.refresh(now: now, config: .default, inspect: inspector([42: owner])),
            .rejectedBecauseHold
        )
        XCTAssertEqual(off.state, before)
    }

    func testTimerAndMultipleHoldsComposeAndReleaseIndependently() {
        let a = ProcessSnapshot(pid: 101, startTime: 11, status: .running)
        let b = ProcessSnapshot(pid: 202, startTime: 22, status: .sleeping)
        var coordinator = LeaseCoordinator()
        _ = coordinator.activateDefault(now: now, config: .default, inspect: inspector([:]))
        let holdA = coordinator.addHold(pid: a.pid, processStartTime: a.startTime, now: now)
        let holdB = coordinator.addHold(pid: b.pid, processStartTime: b.startTime, now: now)

        XCTAssertEqual(coordinator.summary(now: now).holdCount, 2)
        XCTAssertNotNil(coordinator.state.timer)

        XCTAssertTrue(coordinator.removeHold(id: holdA.id))
        XCTAssertEqual(coordinator.summary(now: now).holdCount, 1)
        XCTAssertTrue(coordinator.removeHold(id: holdB.id))
        XCTAssertNotNil(coordinator.state.timer)

        _ = coordinator.reconcile(
            now: now.addingTimeInterval(3_601),
            inspect: inspector([:])
        )
        XCTAssertFalse(coordinator.hasValidLeases)
    }

    func testExpiredTimerDoesNotRemoveLiveHold() {
        let owner = ProcessSnapshot(pid: 303, startTime: 33, status: .running)
        var coordinator = LeaseCoordinator()
        _ = coordinator.activateDefault(now: now, config: .default, inspect: inspector([:]))
        _ = coordinator.addHold(pid: owner.pid, processStartTime: owner.startTime, now: now)

        let result = coordinator.reconcile(
            now: now.addingTimeInterval(3_601),
            inspect: inspector([owner.pid: owner])
        )

        XCTAssertNil(coordinator.state.timer)
        XCTAssertEqual(coordinator.state.holds.count, 1)
        XCTAssertTrue(result.hasValidLeases)
    }

    func testStoppedZombieDeadAndReusedPIDsAreRemoved() {
        let running = ProcessSnapshot(pid: 1, startTime: 10, status: .running)
        let stopped = ProcessSnapshot(pid: 2, startTime: 20, status: .stopped)
        let zombie = ProcessSnapshot(pid: 3, startTime: 30, status: .zombie)
        let reused = ProcessSnapshot(pid: 4, startTime: 999, status: .running)
        var coordinator = LeaseCoordinator()
        _ = coordinator.addHold(pid: 1, processStartTime: 10, now: now)
        _ = coordinator.addHold(pid: 2, processStartTime: 20, now: now)
        _ = coordinator.addHold(pid: 3, processStartTime: 30, now: now)
        _ = coordinator.addHold(pid: 4, processStartTime: 40, now: now)
        _ = coordinator.addHold(pid: 5, processStartTime: 50, now: now)

        _ = coordinator.reconcile(
            now: now,
            inspect: inspector([1: running, 2: stopped, 3: zombie, 4: reused])
        )

        XCTAssertEqual(coordinator.state.holds.map(\.pid), [1])
    }

    func testForceClearAndSafetyTripRevokeOldHolds() {
        let owner = ProcessSnapshot(pid: 77, startTime: 707, status: .running)
        var forced = LeaseCoordinator()
        let oldHold = forced.addHold(pid: owner.pid, processStartTime: owner.startTime, now: now)
        let oldGeneration = forced.state.generation

        XCTAssertEqual(
            forced.forceToggle(now: now, config: .default, inspect: inspector([77: owner])),
            .turnedOff
        )
        XCTAssertEqual(forced.state.generation, oldGeneration + 1)
        XCTAssertEqual(
            forced.resumeHold(oldHold, now: now, snapshot: owner),
            .revoked
        )

        var tripped = LeaseCoordinator()
        _ = tripped.activateDefault(now: now, config: .default, inspect: inspector([:]))
        let generation = tripped.state.generation
        XCTAssertTrue(tripped.tripSafety(reason: .battery, now: now))
        XCTAssertFalse(tripped.hasValidLeases)
        XCTAssertEqual(tripped.state.generation, generation + 1)
        XCTAssertEqual(tripped.state.lastSafetyStop?.reason, .battery)
        XCTAssertFalse(tripped.tripSafety(reason: .battery, now: now.addingTimeInterval(1)))
        XCTAssertEqual(tripped.state.generation, generation + 1)

        var off = LeaseCoordinator()
        guard case let .turnedOn(timer) = off.forceToggle(
            now: now,
            config: .default,
            inspect: inspector([:])
        ) else {
            return XCTFail("OFF force 应创建 Timer")
        }
        XCTAssertEqual(off.state.generation, 1)
        XCTAssertEqual(timer.generation, 1)
    }

    func testSuspendedHoldCanResumeOnlyWithinSameGeneration() {
        let owner = ProcessSnapshot(pid: 88, startTime: 808, status: .running)
        var coordinator = LeaseCoordinator()
        let hold = coordinator.addHold(pid: owner.pid, processStartTime: owner.startTime, now: now)
        XCTAssertTrue(coordinator.removeHold(id: hold.id))
        guard case let .resumed(resumed) = coordinator.resumeHold(
            hold,
            now: now.addingTimeInterval(1),
            snapshot: owner
        ) else {
            return XCTFail("同 generation 的有效 owner 应恢复")
        }
        XCTAssertEqual(resumed.id, hold.id)

        XCTAssertTrue(coordinator.removeHold(id: resumed.id))
        let wrongOwner = ProcessSnapshot(pid: owner.pid, startTime: 999, status: .running)
        XCTAssertEqual(
            coordinator.resumeHold(hold, now: now, snapshot: wrongOwner),
            .invalidOwner
        )

        var safetyDuringSuspend = LeaseCoordinator()
        let suspended = safetyDuringSuspend.addHold(
            pid: owner.pid,
            processStartTime: owner.startTime,
            now: now
        )
        XCTAssertTrue(safetyDuringSuspend.removeHold(id: suspended.id))
        XCTAssertTrue(safetyDuringSuspend.tripSafety(reason: .thermal, now: now))
        XCTAssertEqual(
            safetyDuringSuspend.resumeHold(suspended, now: now, snapshot: owner),
            .revoked
        )
    }
}
