import Foundation

public enum StatusFormatter {
    public static let help = """
    MacLidAwake — temporarily keep a MacBook running with the lid closed.

    Usage:
      lidgo                     Start or show current state
      lidgo -r, --refresh       Refresh the timer
      lidgo --hold              Hold until Ctrl-C
      lidgo switch -f           Force toggle global state
      lidgo config              Show configuration
      lidgo config -d 45       Set duration (bare value = minutes; h/m; --duration)
      lidgo config -b 10       Set battery cutoff percentage (--battery)
      lidgo setup               Install or repair privileges
      lidgo help                Show help
    """

    public static func active(
        _ summary: LeaseSummary,
        now: Date,
        timeZone: TimeZone = .current
    ) -> String {
        guard summary.isActive else {
            return "LidGo off\nNormal sleep enabled"
        }

        var lines = ["LidGo on"]
        if let timer = summary.timer {
            let remaining = max(0, Int(ceil(timer.deadline.timeIntervalSince(now) / 60)))
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            formatter.dateFormat = "HH:mm"
            lines.append("Timer: \(remaining) min remaining, sleep resumes at \(formatter.string(from: timer.deadline))")
        }
        if summary.holdCount > 0 {
            lines.append("Hold: \(summary.holdCount) terminal session(s) holding")
        }
        return lines.joined(separator: "\n")
    }

    public static func timerCreated(_ timer: TimerLease, now: Date) -> String {
        "LidGo on\n" + timerLine(timer, now: now)
    }

    public static func timerRefreshed(_ timer: TimerLease, now: Date) -> String {
        "LidGo timer refreshed\n" + timerLine(timer, now: now)
    }

    public static func configuration(_ config: LidGoConfig) -> String {
        """
        Default duration : \(duration(config.defaultDurationSeconds))
        Battery cutoff   : \(config.batteryCutoffPercent)%
        Thermal safety   : enabled
        """
    }

    private static func timerLine(_ timer: TimerLease, now: Date) -> String {
        active(LeaseSummary(timer: timer, holdCount: 0), now: now)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .dropFirst()
            .joined(separator: "\n")
    }

    private static func duration(_ seconds: Int) -> String {
        if seconds == 3_600 { return "60m" }
        if seconds >= 7_200, seconds % 3_600 == 0 { return "\(seconds / 3_600)h" }
        if seconds % 60 == 0 { return "\(seconds / 60)m" }
        return "\(seconds)s"
    }
}
