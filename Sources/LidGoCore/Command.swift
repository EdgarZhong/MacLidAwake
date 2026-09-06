import Foundation

public struct ConfigUpdate: Equatable, Sendable {
    public let defaultDurationSeconds: Int?
    public let batteryCutoffPercent: Int?

    public init(
        defaultDurationSeconds: Int? = nil,
        batteryCutoffPercent: Int? = nil
    ) {
        self.defaultDurationSeconds = defaultDurationSeconds
        self.batteryCutoffPercent = batteryCutoffPercent
    }
}

public enum LidGoCommand: Equatable, Sendable {
    case activate
    case refresh
    case hold
    case switchNeedsForce
    case switchForce
    case config(ConfigUpdate)
    case setup
    case help
    case agent
    case rootSetup

    public static func parse(_ arguments: [String]) throws -> LidGoCommand {
        guard let first = arguments.first else { return .activate }

        switch first {
        case "--hold" where arguments.count == 1:
            return .hold
        case "-r", "--refresh":
            guard arguments.count == 1 else {
                throw CommandParseError.invalidArguments(arguments)
            }
            return .refresh
        case "switch":
            if arguments.count == 1 { return .switchNeedsForce }
            if arguments.count == 2, arguments[1] == "-f" || arguments[1] == "--force" {
                return .switchForce
            }
        case "config":
            return try parseConfig(Array(arguments.dropFirst()))
        case "setup" where arguments.count == 1:
            return .setup
        case "help", "-h", "--help":
            guard arguments.count == 1 else {
                throw CommandParseError.invalidArguments(arguments)
            }
            return .help
        case "__agent" where arguments.count == 1:
            return .agent
        case "__root-setup" where arguments.count == 1:
            return .rootSetup
        default:
            break
        }

        throw CommandParseError.invalidArguments(arguments)
    }

    private static func parseConfig(_ arguments: [String]) throws -> LidGoCommand {
        var duration: Int?
        var battery: Int?
        var index = 0

        while index < arguments.count {
            let option = arguments[index]
            guard index + 1 < arguments.count else {
                throw CommandParseError.missingValue(option)
            }
            let value = arguments[index + 1]
            switch option {
            case "--duration" where duration == nil:
                guard let seconds = DurationParser.parse(value) else {
                    throw CommandParseError.invalidDuration(value)
                }
                duration = seconds
            case "--battery" where battery == nil:
                guard let percent = Int(value), String(percent) == value,
                      (1...99).contains(percent)
                else {
                    throw CommandParseError.invalidBattery(value)
                }
                battery = percent
            default:
                throw CommandParseError.invalidArguments(arguments)
            }
            index += 2
        }

        return .config(ConfigUpdate(
            defaultDurationSeconds: duration,
            batteryCutoffPercent: battery
        ))
    }
}

public enum CommandParseError: Error, Equatable, CustomStringConvertible {
    case invalidArguments([String])
    case missingValue(String)
    case invalidDuration(String)
    case invalidBattery(String)

    public var description: String {
        switch self {
        case let .invalidArguments(arguments):
            return "无法识别参数：\(arguments.joined(separator: " "))。请运行 lidgo help"
        case let .missingValue(option):
            return "\(option) 缺少参数值"
        case let .invalidDuration(value):
            return "无效时长 \(value)；请使用 90m、2h 或 1h30m"
        case let .invalidBattery(value):
            return "无效低电量阈值 \(value)；必须是 1 到 99"
        }
    }
}
