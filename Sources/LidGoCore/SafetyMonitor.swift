import Foundation
import IOKit.ps

public enum LidGoThermalState: String, Codable, Equatable, Sendable {
    case nominal
    case fair
    case serious
    case critical
}

public struct SafetySnapshot: Equatable, Sendable {
    public let batteryPercent: Int?
    public let thermalState: LidGoThermalState

    public init(batteryPercent: Int?, thermalState: LidGoThermalState) {
        self.batteryPercent = batteryPercent
        self.thermalState = thermalState
    }
}

public protocol SafetyReading: Sendable {
    func snapshot() -> SafetySnapshot
}

public enum SafetyPolicy {
    public static func stopReason(
        snapshot: SafetySnapshot,
        config: LidGoConfig
    ) -> SafetyStopReason? {
        guard let battery = snapshot.batteryPercent else {
            return .batteryUnavailable
        }
        if battery <= config.batteryCutoffPercent {
            return .battery
        }
        if snapshot.thermalState == .critical {
            return .thermal
        }
        return nil
    }
}

public struct SystemSafetyReader: SafetyReading {
    public init() {}

    public func snapshot() -> SafetySnapshot {
        SafetySnapshot(
            batteryPercent: batteryPercent(),
            thermalState: thermalState()
        )
    }

    private func batteryPercent() -> Int? {
        guard let information = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(information)?.takeRetainedValue() as? [CFTypeRef]
        else {
            return nil
        }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(information, source)?
                .takeUnretainedValue() as? [String: Any],
                  let current = description[kIOPSCurrentCapacityKey as String] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey as String] as? Int,
                  maximum > 0
            else {
                continue
            }
            return Int((Double(current) / Double(maximum) * 100).rounded())
        }
        return nil
    }

    private func thermalState() -> LidGoThermalState {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:
            return .nominal
        case .fair:
            return .fair
        case .serious:
            return .serious
        case .critical:
            return .critical
        @unknown default:
            return .critical
        }
    }
}
