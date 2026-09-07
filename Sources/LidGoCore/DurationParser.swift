public enum DurationParser {
    public static func parse(_ value: String) -> Int? {
        guard !value.isEmpty else { return nil }

        if let hourMarker = value.firstIndex(of: "h") {
            let hourText = String(value[..<hourMarker])
            guard let hours = positiveInt(hourText) else { return nil }

            let remainderStart = value.index(after: hourMarker)
            let remainder = String(value[remainderStart...])
            let minutes: Int
            if remainder.isEmpty {
                minutes = 0
            } else {
                guard remainder.hasSuffix("m") else { return nil }
                let minuteText = String(remainder.dropLast())
                guard let parsedMinutes = positiveInt(minuteText) else { return nil }
                minutes = parsedMinutes
            }

            let (hourSeconds, hourOverflow) = hours.multipliedReportingOverflow(by: 3_600)
            let (minuteSeconds, minuteOverflow) = minutes.multipliedReportingOverflow(by: 60)
            let (total, totalOverflow) = hourSeconds.addingReportingOverflow(minuteSeconds)
            guard !hourOverflow, !minuteOverflow, !totalOverflow, total > 0 else { return nil }
            return total
        }

        let minuteText = value.hasSuffix("m") ? String(value.dropLast()) : value
        guard let minutes = positiveInt(minuteText) else { return nil }
        let (seconds, overflow) = minutes.multipliedReportingOverflow(by: 60)
        return overflow ? nil : seconds
    }

    private static func positiveInt(_ value: String) -> Int? {
        guard !value.isEmpty, value.allSatisfy(\.isNumber), let parsed = Int(value), parsed > 0 else {
            return nil
        }
        return parsed
    }
}
