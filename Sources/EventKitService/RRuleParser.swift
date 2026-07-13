import EventKit
import Foundation

/// Errors that can occur during RRULE parsing
public enum RRuleParserError: Error, LocalizedError, Equatable {
    case missingFrequency
    case invalidFrequency(String)
    case invalidInterval(String)
    case invalidCount(String)
    case invalidUntilDate(String)
    case invalidByDay(String)
    case invalidByMonthDay(String)
    case invalidByMonth(String)
    case invalidByWeekNo(String)
    case invalidByYearDay(String)
    case invalidBySetPos(String)

    public var errorDescription: String? {
        switch self {
        case .missingFrequency:
            return "RRULE must contain FREQ component"
        case .invalidFrequency(let value):
            return "Invalid FREQ value: '\(value)'. Must be DAILY, WEEKLY, MONTHLY, or YEARLY"
        case .invalidInterval(let value):
            return "Invalid INTERVAL value: '\(value)'. Must be a positive integer"
        case .invalidCount(let value):
            return "Invalid COUNT value: '\(value)'. Must be a positive integer"
        case .invalidUntilDate(let value):
            return "Invalid UNTIL date: '\(value)'. Use format YYYYMMDD or YYYYMMDDTHHMMSSZ"
        case .invalidByDay(let value):
            return "Invalid BYDAY value: '\(value)'. Use format like MO, TU, 2MO, -1FR"
        case .invalidByMonthDay(let value):
            return "Invalid BYMONTHDAY value: '\(value)'. Must be 1-31 or -31 to -1"
        case .invalidByMonth(let value):
            return "Invalid BYMONTH value: '\(value)'. Must be 1-12"
        case .invalidByWeekNo(let value):
            return "Invalid BYWEEKNO value: '\(value)'. Must be 1-53 or -53 to -1"
        case .invalidByYearDay(let value):
            return "Invalid BYYEARDAY value: '\(value)'. Must be 1-366 or -366 to -1"
        case .invalidBySetPos(let value):
            return "Invalid BYSETPOS value: '\(value)'. Must be 1-366 or -366 to -1"
        }
    }
}

/// Parser and formatter for RRULE strings (RFC 5545) to/from EKRecurrenceRule
public enum RRuleParser {

    // MARK: - Day of Week Mapping

    private static let dayCodeToWeekday: [String: EKWeekday] = [
        "SU": .sunday,
        "MO": .monday,
        "TU": .tuesday,
        "WE": .wednesday,
        "TH": .thursday,
        "FR": .friday,
        "SA": .saturday
    ]

    private static let weekdayToDayCode: [EKWeekday: String] = [
        .sunday: "SU",
        .monday: "MO",
        .tuesday: "TU",
        .wednesday: "WE",
        .thursday: "TH",
        .friday: "FR",
        .saturday: "SA"
    ]

    // MARK: - Parse RRULE String to EKRecurrenceRule

    /// Parse an RRULE string into an EKRecurrenceRule
    /// - Parameter rrule: RRULE string, e.g., "FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE,FR"
    /// - Returns: The corresponding EKRecurrenceRule
    /// - Throws: RRuleParserError if the RRULE is invalid
    public static func parse(_ rrule: String) throws -> EKRecurrenceRule {
        // Remove "RRULE:" prefix if present
        let ruleString = rrule.hasPrefix("RRULE:") ? String(rrule.dropFirst(6)) : rrule

        // Parse components into dictionary
        var components: [String: String] = [:]
        for part in ruleString.split(separator: ";") {
            let keyValue = part.split(separator: "=", maxSplits: 1)
            if keyValue.count == 2 {
                components[String(keyValue[0]).uppercased()] = String(keyValue[1])
            }
        }

        // Parse FREQ (required)
        guard let freqStr = components["FREQ"] else {
            throw RRuleParserError.missingFrequency
        }
        let frequency = try parseFrequency(freqStr)

        // Parse INTERVAL (default: 1)
        let interval = try parseInterval(components["INTERVAL"])

        // Parse end condition (COUNT or UNTIL)
        let recurrenceEnd = try parseEnd(count: components["COUNT"], until: components["UNTIL"])

        // Parse BYDAY
        let daysOfTheWeek = try parseByDay(components["BYDAY"])

        // Parse BYMONTHDAY
        let daysOfTheMonth = try parseIntArray(components["BYMONTHDAY"], name: "BYMONTHDAY", range: -31...31, excludeZero: true)

        // Parse BYMONTH
        let monthsOfTheYear = try parseIntArray(components["BYMONTH"], name: "BYMONTH", range: 1...12, excludeZero: false)

        // Parse BYWEEKNO
        let weeksOfTheYear = try parseIntArray(components["BYWEEKNO"], name: "BYWEEKNO", range: -53...53, excludeZero: true)

        // Parse BYYEARDAY
        let daysOfTheYear = try parseIntArray(components["BYYEARDAY"], name: "BYYEARDAY", range: -366...366, excludeZero: true)

        // Parse BYSETPOS
        let setPositions = try parseIntArray(components["BYSETPOS"], name: "BYSETPOS", range: -366...366, excludeZero: true)

        return EKRecurrenceRule(
            recurrenceWith: frequency,
            interval: interval,
            daysOfTheWeek: daysOfTheWeek,
            daysOfTheMonth: daysOfTheMonth?.map { NSNumber(value: $0) },
            monthsOfTheYear: monthsOfTheYear?.map { NSNumber(value: $0) },
            weeksOfTheYear: weeksOfTheYear?.map { NSNumber(value: $0) },
            daysOfTheYear: daysOfTheYear?.map { NSNumber(value: $0) },
            setPositions: setPositions?.map { NSNumber(value: $0) },
            end: recurrenceEnd
        )
    }

    private static func parseFrequency(_ value: String) throws -> EKRecurrenceFrequency {
        switch value.uppercased() {
        case "DAILY": return .daily
        case "WEEKLY": return .weekly
        case "MONTHLY": return .monthly
        case "YEARLY": return .yearly
        default: throw RRuleParserError.invalidFrequency(value)
        }
    }

    private static func parseInterval(_ value: String?) throws -> Int {
        guard let value = value else { return 1 }
        guard let interval = Int(value), interval > 0 else {
            throw RRuleParserError.invalidInterval(value)
        }
        return interval
    }

    private static func parseEnd(count: String?, until: String?) throws -> EKRecurrenceEnd? {
        if let countStr = count {
            guard let countInt = Int(countStr), countInt > 0 else {
                throw RRuleParserError.invalidCount(countStr)
            }
            return EKRecurrenceEnd(occurrenceCount: countInt)
        }

        if let untilStr = until {
            guard let date = parseUntilDate(untilStr) else {
                throw RRuleParserError.invalidUntilDate(untilStr)
            }
            return EKRecurrenceEnd(end: date)
        }

        return nil
    }

    private static func parseUntilDate(_ value: String) -> Date? {
        // Try YYYYMMDDTHHMMSSZ format
        let isoFormatter = DateFormatter()
        isoFormatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        isoFormatter.timeZone = TimeZone(identifier: "UTC")
        if let date = isoFormatter.date(from: value) {
            return date
        }

        // Try YYYYMMDDTHHMMSS format (local time)
        isoFormatter.dateFormat = "yyyyMMdd'T'HHmmss"
        isoFormatter.timeZone = TimeZone.current
        if let date = isoFormatter.date(from: value) {
            return date
        }

        // Try YYYYMMDD format
        isoFormatter.dateFormat = "yyyyMMdd"
        if let date = isoFormatter.date(from: value) {
            return date
        }

        return nil
    }

    private static func parseByDay(_ value: String?) throws -> [EKRecurrenceDayOfWeek]? {
        guard let value = value else { return nil }

        var days: [EKRecurrenceDayOfWeek] = []
        for dayStr in value.split(separator: ",") {
            let trimmed = String(dayStr).trimmingCharacters(in: .whitespaces)
            guard let day = parseSingleByDay(trimmed) else {
                throw RRuleParserError.invalidByDay(trimmed)
            }
            days.append(day)
        }

        return days.isEmpty ? nil : days
    }

    private static func parseSingleByDay(_ value: String) -> EKRecurrenceDayOfWeek? {
        // Format: [+/-N]DD where DD is day code (MO, TU, etc.)
        // Examples: MO, 2TU, -1FR, +3WE

        let pattern = #"^([+-]?\d*)?([A-Z]{2})$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else {
            return nil
        }

        // Extract week number (optional)
        var weekNumber: Int = 0
        if let numRange = Range(match.range(at: 1), in: value) {
            let numStr = String(value[numRange])
            if !numStr.isEmpty {
                weekNumber = Int(numStr) ?? 0
            }
        }

        // Extract day code (required)
        guard let dayRange = Range(match.range(at: 2), in: value) else { return nil }
        let dayCode = String(value[dayRange]).uppercased()
        guard let weekday = dayCodeToWeekday[dayCode] else { return nil }

        if weekNumber == 0 {
            return EKRecurrenceDayOfWeek(weekday)
        } else {
            return EKRecurrenceDayOfWeek(weekday, weekNumber: weekNumber)
        }
    }

    private static func parseIntArray(_ value: String?, name: String, range: ClosedRange<Int>, excludeZero: Bool) throws -> [Int]? {
        guard let value = value else { return nil }

        var result: [Int] = []
        for numStr in value.split(separator: ",") {
            let trimmed = String(numStr).trimmingCharacters(in: .whitespaces)
            guard let num = Int(trimmed), range.contains(num), !(excludeZero && num == 0) else {
                switch name {
                case "BYMONTHDAY": throw RRuleParserError.invalidByMonthDay(trimmed)
                case "BYMONTH": throw RRuleParserError.invalidByMonth(trimmed)
                case "BYWEEKNO": throw RRuleParserError.invalidByWeekNo(trimmed)
                case "BYYEARDAY": throw RRuleParserError.invalidByYearDay(trimmed)
                case "BYSETPOS": throw RRuleParserError.invalidBySetPos(trimmed)
                default: throw RRuleParserError.invalidByMonthDay(trimmed)
                }
            }
            result.append(num)
        }

        return result.isEmpty ? nil : result
    }

    // MARK: - Format EKRecurrenceRule to RRULE String

    /// Format an EKRecurrenceRule as an RRULE string
    /// - Parameter rule: The EKRecurrenceRule to format
    /// - Returns: RRULE string, e.g., "FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE,FR"
    public static func format(_ rule: EKRecurrenceRule) -> String {
        var components: [String] = []

        // FREQ (required)
        components.append("FREQ=\(formatFrequency(rule.frequency))")

        // INTERVAL (only if > 1)
        if rule.interval > 1 {
            components.append("INTERVAL=\(rule.interval)")
        }

        // End condition
        if let end = rule.recurrenceEnd {
            let count = end.occurrenceCount
            if count > 0 {
                components.append("COUNT=\(count)")
            } else if let endDate = end.endDate {
                components.append("UNTIL=\(formatUntilDate(endDate))")
            }
        }

        // BYDAY
        if let daysOfWeek = rule.daysOfTheWeek, !daysOfWeek.isEmpty {
            let dayStrs = daysOfWeek.map { formatDayOfWeek($0) }
            components.append("BYDAY=\(dayStrs.joined(separator: ","))")
        }

        // BYMONTHDAY
        if let days = rule.daysOfTheMonth, !days.isEmpty {
            components.append("BYMONTHDAY=\(days.map { "\($0.intValue)" }.joined(separator: ","))")
        }

        // BYMONTH
        if let months = rule.monthsOfTheYear, !months.isEmpty {
            components.append("BYMONTH=\(months.map { "\($0.intValue)" }.joined(separator: ","))")
        }

        // BYWEEKNO
        if let weeks = rule.weeksOfTheYear, !weeks.isEmpty {
            components.append("BYWEEKNO=\(weeks.map { "\($0.intValue)" }.joined(separator: ","))")
        }

        // BYYEARDAY
        if let days = rule.daysOfTheYear, !days.isEmpty {
            components.append("BYYEARDAY=\(days.map { "\($0.intValue)" }.joined(separator: ","))")
        }

        // BYSETPOS
        if let positions = rule.setPositions, !positions.isEmpty {
            components.append("BYSETPOS=\(positions.map { "\($0.intValue)" }.joined(separator: ","))")
        }

        return components.joined(separator: ";")
    }

    private static func formatFrequency(_ frequency: EKRecurrenceFrequency) -> String {
        switch frequency {
        case .daily: return "DAILY"
        case .weekly: return "WEEKLY"
        case .monthly: return "MONTHLY"
        case .yearly: return "YEARLY"
        @unknown default: return "DAILY"
        }
    }

    private static func formatUntilDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    private static func formatDayOfWeek(_ day: EKRecurrenceDayOfWeek) -> String {
        let dayCode = weekdayToDayCode[day.dayOfTheWeek] ?? "MO"
        if day.weekNumber == 0 {
            return dayCode
        } else {
            return "\(day.weekNumber)\(dayCode)"
        }
    }
}
