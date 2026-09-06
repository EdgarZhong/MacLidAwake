import Foundation

public enum LidGoProduct {
    public static let name = "MacLidAwake"
    public static let command = "lidgo"
    public static let version = "0.1.0"
}

public struct LidGoConfig: Codable, Equatable, Sendable {
    public enum ValidationError: Error, Equatable, CustomStringConvertible {
        case invalidDuration
        case invalidBatteryCutoff

        public var description: String {
            switch self {
            case .invalidDuration:
                return "默认时长必须大于 0"
            case .invalidBatteryCutoff:
                return "低电量阈值必须是 1 到 99"
            }
        }
    }

    public static let `default` = LidGoConfig(
        defaultDurationSeconds: 3_600,
        batteryCutoffPercent: 15
    )

    public var defaultDurationSeconds: Int
    public var batteryCutoffPercent: Int

    public init(defaultDurationSeconds: Int, batteryCutoffPercent: Int) {
        self.defaultDurationSeconds = defaultDurationSeconds
        self.batteryCutoffPercent = batteryCutoffPercent
    }

    @discardableResult
    public func validated() throws -> LidGoConfig {
        guard defaultDurationSeconds > 0 else {
            throw ValidationError.invalidDuration
        }
        guard (1...99).contains(batteryCutoffPercent) else {
            throw ValidationError.invalidBatteryCutoff
        }
        return self
    }
}

public struct TimerLease: Codable, Equatable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public var deadline: Date
    public let generation: UInt64

    public init(
        id: UUID = UUID(),
        createdAt: Date,
        deadline: Date,
        generation: UInt64
    ) {
        self.id = id
        self.createdAt = createdAt
        self.deadline = deadline
        self.generation = generation
    }

    public init(now: Date, duration: Int, generation: UInt64) {
        self.init(
            createdAt: now,
            deadline: now.addingTimeInterval(TimeInterval(duration)),
            generation: generation
        )
    }
}

public struct HoldLease: Codable, Equatable, Sendable {
    public let id: UUID
    public let pid: Int32
    public let processStartTime: UInt64
    public let generation: UInt64
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        pid: Int32,
        processStartTime: UInt64,
        generation: UInt64,
        createdAt: Date
    ) {
        self.id = id
        self.pid = pid
        self.processStartTime = processStartTime
        self.generation = generation
        self.createdAt = createdAt
    }
}

public enum SafetyStopReason: String, Codable, Equatable, Sendable {
    case battery
    case batteryUnavailable
    case thermal
}

public struct SafetyStop: Codable, Equatable, Sendable {
    public let reason: SafetyStopReason
    public let occurredAt: Date

    public init(reason: SafetyStopReason, occurredAt: Date) {
        self.reason = reason
        self.occurredAt = occurredAt
    }
}

public struct RuntimeState: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var generation: UInt64
    public var timer: TimerLease?
    public var holds: [HoldLease]
    public var lastSafetyStop: SafetyStop?

    public init(
        schemaVersion: Int = RuntimeState.currentSchemaVersion,
        generation: UInt64 = 0,
        timer: TimerLease? = nil,
        holds: [HoldLease] = [],
        lastSafetyStop: SafetyStop? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.generation = generation
        self.timer = timer
        self.holds = holds
        self.lastSafetyStop = lastSafetyStop
    }
}

public enum ProcessStatus: String, Codable, Equatable, Sendable {
    case running
    case sleeping
    case stopped
    case zombie
    case unknown

    public var canOwnHold: Bool {
        self == .running || self == .sleeping
    }
}

public struct ProcessSnapshot: Codable, Equatable, Sendable {
    public let pid: Int32
    public let startTime: UInt64
    public let status: ProcessStatus

    public init(pid: Int32, startTime: UInt64, status: ProcessStatus) {
        self.pid = pid
        self.startTime = startTime
        self.status = status
    }
}

public struct LeaseSummary: Equatable, Sendable {
    public let timer: TimerLease?
    public let holdCount: Int

    public init(timer: TimerLease?, holdCount: Int) {
        self.timer = timer
        self.holdCount = holdCount
    }

    public var isActive: Bool {
        timer != nil || holdCount > 0
    }
}

public enum DefaultCommandResult: Equatable, Sendable {
    case created(TimerLease)
    case unchanged(LeaseSummary)
}

public enum RefreshResult: Equatable, Sendable {
    case created(TimerLease)
    case refreshed(TimerLease)
    case rejectedBecauseHold
}

public enum ForceToggleResult: Equatable, Sendable {
    case turnedOn(TimerLease)
    case turnedOff
}

public enum HoldResumeResult: Equatable, Sendable {
    case resumed(HoldLease)
    case alreadyActive
    case revoked
    case invalidOwner
}

public struct ReconcileResult: Equatable, Sendable {
    public let changed: Bool
    public let hasValidLeases: Bool

    public init(changed: Bool, hasValidLeases: Bool) {
        self.changed = changed
        self.hasValidLeases = hasValidLeases
    }
}
