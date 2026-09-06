import Foundation

public struct LeaseCoordinator {
    public private(set) var state: RuntimeState

    public init(state: RuntimeState = RuntimeState()) {
        self.state = state
    }

    public var hasValidLeases: Bool {
        state.timer != nil || !state.holds.isEmpty
    }

    public func summary(now: Date) -> LeaseSummary {
        LeaseSummary(timer: state.timer, holdCount: state.holds.count)
    }

    @discardableResult
    public mutating func reconcile(
        now: Date,
        inspect: (Int32) -> ProcessSnapshot?
    ) -> ReconcileResult {
        let previousTimer = state.timer
        let previousHolds = state.holds

        if let timer = state.timer, timer.deadline <= now {
            state.timer = nil
        }
        state.holds.removeAll { hold in
            guard hold.generation == state.generation,
                  let snapshot = inspect(hold.pid),
                  snapshot.pid == hold.pid,
                  snapshot.startTime == hold.processStartTime,
                  snapshot.status.canOwnHold
            else {
                return true
            }
            return false
        }

        return ReconcileResult(
            changed: state.timer != previousTimer || state.holds != previousHolds,
            hasValidLeases: hasValidLeases
        )
    }

    public mutating func activateDefault(
        now: Date,
        config: LidGoConfig,
        inspect: (Int32) -> ProcessSnapshot?
    ) -> DefaultCommandResult {
        _ = reconcile(now: now, inspect: inspect)
        if hasValidLeases {
            return .unchanged(summary(now: now))
        }
        let timer = TimerLease(
            now: now,
            duration: config.defaultDurationSeconds,
            generation: state.generation
        )
        state.timer = timer
        state.lastSafetyStop = nil
        return .created(timer)
    }

    public mutating func refresh(
        now: Date,
        config: LidGoConfig,
        inspect: (Int32) -> ProcessSnapshot?
    ) -> RefreshResult {
        _ = reconcile(now: now, inspect: inspect)
        guard state.holds.isEmpty else { return .rejectedBecauseHold }

        if var timer = state.timer {
            timer.deadline = now.addingTimeInterval(TimeInterval(config.defaultDurationSeconds))
            state.timer = timer
            state.lastSafetyStop = nil
            return .refreshed(timer)
        }

        let timer = TimerLease(
            now: now,
            duration: config.defaultDurationSeconds,
            generation: state.generation
        )
        state.timer = timer
        state.lastSafetyStop = nil
        return .created(timer)
    }

    @discardableResult
    public mutating func addHold(
        id: UUID = UUID(),
        pid: Int32,
        processStartTime: UInt64,
        now: Date
    ) -> HoldLease {
        let hold = HoldLease(
            id: id,
            pid: pid,
            processStartTime: processStartTime,
            generation: state.generation,
            createdAt: now
        )
        state.holds.removeAll { $0.id == id }
        state.holds.append(hold)
        state.lastSafetyStop = nil
        return hold
    }

    @discardableResult
    public mutating func removeHold(id: UUID) -> Bool {
        let oldCount = state.holds.count
        state.holds.removeAll { $0.id == id }
        return state.holds.count != oldCount
    }

    public mutating func resumeHold(
        _ original: HoldLease,
        now: Date,
        snapshot: ProcessSnapshot
    ) -> HoldResumeResult {
        guard original.generation == state.generation else { return .revoked }
        if state.holds.contains(where: { $0.id == original.id }) {
            return .alreadyActive
        }
        guard snapshot.pid == original.pid,
              snapshot.startTime == original.processStartTime,
              snapshot.status.canOwnHold
        else {
            return .invalidOwner
        }
        let resumed = HoldLease(
            id: original.id,
            pid: original.pid,
            processStartTime: original.processStartTime,
            generation: original.generation,
            createdAt: now
        )
        state.holds.append(resumed)
        state.lastSafetyStop = nil
        return .resumed(resumed)
    }

    public mutating func forceToggle(
        now: Date,
        config: LidGoConfig,
        inspect: (Int32) -> ProcessSnapshot?
    ) -> ForceToggleResult {
        _ = reconcile(now: now, inspect: inspect)
        if hasValidLeases {
            state.timer = nil
            state.holds.removeAll()
            state.generation &+= 1
            return .turnedOff
        }
        state.generation &+= 1
        let timer = TimerLease(
            now: now,
            duration: config.defaultDurationSeconds,
            generation: state.generation
        )
        state.timer = timer
        state.lastSafetyStop = nil
        return .turnedOn(timer)
    }

    @discardableResult
    public mutating func tripSafety(reason: SafetyStopReason, now: Date) -> Bool {
        if let previous = state.lastSafetyStop, previous.reason == reason {
            return false
        }
        state.timer = nil
        state.holds.removeAll()
        state.generation &+= 1
        state.lastSafetyStop = SafetyStop(reason: reason, occurredAt: now)
        return true
    }
}
