import EventKitService
import Foundation
import MCP

enum ParseError: Error, LocalizedError {
    case invalidSearchPattern(String)
    case invalidDateFormat(String)
    case invalidPriorityValue(String)
    case invalidFilterValue(String)
    case invalidDaysValue(String)
    case invalidColorFormat(String)
    case invalidRRule(String, String)
    case invalidURL(String)
    case invalidTimeZone(String)
    case invalidAlarms(String)
    case invalidStringValue(String)
    case invalidPagination(String)

    var errorDescription: String? {
        switch self {
        case .invalidSearchPattern(let value):
            return "Invalid search pattern: '\(value)'"
        case .invalidDateFormat(let value):
            return
                "Invalid date format: '\(value)'. Use ISO8601 (e.g., '2026-01-06T10:00:00Z', '2026-01-06T10:00:00-06:00', '2026-01-06T10:00:00', or '2026-01-06')"
        case .invalidPriorityValue(let value):
            return "Invalid priority: '\(value)'. Use 'high', 'medium', 'low', or 'none'"
        case .invalidFilterValue(let value):
            return "Invalid filter: '\(value)'. Use 'all', 'overdue', 'today', or 'upcoming'"
        case .invalidDaysValue(let value):
            return "Invalid days value: '\(value)'. Must be an integer from 1 through 3650"
        case .invalidColorFormat(let value):
            return "Invalid color format: '\(value)'. Use hex format (e.g., '#FF5733' or 'FF5733')"
        case .invalidRRule(let value, let reason):
            return "Invalid RRULE: '\(value)'. \(reason)"
        case .invalidURL(let value):
            return "Invalid URL: '\(value)'"
        case .invalidTimeZone(let value):
            return "Unknown time zone: '\(value)'"
        case .invalidAlarms(let reason):
            return "Invalid alarms: \(reason)"
        case .invalidStringValue(let field):
            return "Invalid \(field): expected a string or null"
        case .invalidPagination(let reason):
            return "Invalid pagination: \(reason)"
        }
    }
}

/// Result of parsing a date string, including whether time was specified
private struct ParsedDate {
    let date: Date
    let hasTime: Bool
}

/// Parse date string and detect if it includes a time component
private func parseDateWithTimeInfo(_ string: String?, in timeZone: TimeZone? = nil) -> ParsedDate? {
    guard let string = string else { return nil }

    let formatter = ISO8601DateFormatter()

    // ISO8601 with fractional seconds - has time
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: string) {
        return ParsedDate(date: date, hasTime: true)
    }

    // ISO8601 without fractional seconds - has time
    formatter.formatOptions = [.withInternetDateTime]
    if let date = formatter.date(from: string) {
        return ParsedDate(date: date, hasTime: true)
    }

    // Fallback: local datetime (no timezone = local time) - has time
    // A caller-supplied time zone anchors wall-clock inputs; otherwise they are local.
    let localFormatter = DateFormatter()
    localFormatter.locale = Locale(identifier: "en_US_POSIX")
    localFormatter.timeZone = timeZone ?? TimeZone.current

    localFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    if let date = localFormatter.date(from: string) {
        return ParsedDate(date: date, hasTime: true)
    }

    // Date-only format - no time (all-day)
    localFormatter.dateFormat = "yyyy-MM-dd"
    if let date = localFormatter.date(from: string) {
        return ParsedDate(date: date, hasTime: false)
    }

    return nil
}

private func parseDate(_ string: String?) -> Date? {
    parseDateWithTimeInfo(string)?.date
}

/// Parse date with time info and explicit error when format is invalid
/// Returns (date, isAllDay) where isAllDay is true if the input was date-only format
func requireDateWithTimeInfo(
    _ string: String?,
    in timeZone: TimeZone? = nil
) throws -> (date: Date, isAllDay: Bool)? {
    guard let string = string else { return nil }
    guard let parsed = parseDateWithTimeInfo(string, in: timeZone) else {
        throw ParseError.invalidDateFormat(string)
    }
    return (parsed.date, !parsed.hasTime)
}

private func parsePriority(_ string: String?) -> ReminderPriority? {
    guard let input = string.flatMap(ReminderPriorityInput.init(rawValue:)) else { return nil }
    switch input {
    case .high: return .high
    case .medium: return .medium
    case .low: return .low
    case .none: return ReminderPriority.none
    }
}

/// Parse priority with explicit error when value is invalid
func requirePriority(_ string: String?) throws -> ReminderPriority? {
    guard let string = string else { return nil }
    guard let priority = parsePriority(string) else {
        throw ParseError.invalidPriorityValue(string)
    }
    return priority
}

/// Parse filter with explicit error when value is invalid
func requireFilter(_ string: String?) throws -> QueryFilter {
    let value = string ?? QueryFilter.all.rawValue
    guard let filter = QueryFilter(rawValue: value) else {
        throw ParseError.invalidFilterValue(value)
    }
    return filter
}

/// Parse days with explicit error when value is invalid
func requireDays(_ value: Value?) throws -> Int {
    guard let value = value else { return 7 }
    // Upper bound guards `days + 1` in ReminderFilters.upcoming from overflow-trapping,
    // and keeps the filter window meaningful. Ten years is well past any real use.
    guard let days = value.intValue, (1...3650).contains(days) else {
        let description: String
        if let str = value.stringValue {
            description = str
        } else if let num = value.doubleValue {
            description = String(num)
        } else {
            description = "invalid value"
        }
        throw ParseError.invalidDaysValue(description)
    }
    return days
}

func requireLimit(_ value: Value?) throws -> Int {
    guard let value else { return 25 }
    guard let limit = value.intValue, (1...100).contains(limit) else {
        throw ParseError.invalidPagination("limit must be an integer from 1 through 100")
    }
    return limit
}

func requireOffset(_ value: Value?) throws -> Int {
    guard let value else { return 0 }
    guard let offset = value.intValue, offset >= 0 else {
        throw ParseError.invalidPagination("offset must be a non-negative integer")
    }
    return offset
}

/// Parse color with explicit error when format is invalid
func requireColor(_ string: String?) throws -> String? {
    guard let color = string else { return nil }
    let pattern = "^#?[0-9A-Fa-f]{6}$"
    guard color.range(of: pattern, options: .regularExpression) != nil else {
        throw ParseError.invalidColorFormat(color)
    }
    return color
}

/// Parse alarms field from upsert item (3-state: missing=unchanged, null=remove, array=set).
func parseAlarmsField(
    _ itemObj: [String: Value]
) throws -> ReminderFieldUpdate<[ReminderAlarmModel]> {
    guard let value = itemObj["alarms"] else {
        return .unchanged
    }
    if case .null = value {
        return .clear
    }
    guard let array = value.arrayValue else {
        throw ParseError.invalidAlarms("expected an array or null")
    }
    var alarms: [ReminderAlarmModel] = []
    for (index, element) in array.enumerated() {
        guard let object = element.objectValue, let kind = object["kind"]?.stringValue else {
            throw ParseError.invalidAlarms("element \(index) must be an alarm object with a kind")
        }
        switch kind {
        case "relative":
            guard let minutes = object["minutesBefore"]?.intValue, minutes >= 0 else {
                throw ParseError.invalidAlarms("relative element \(index) needs non-negative integer minutesBefore")
            }
            alarms.append(.relative(minutesBefore: minutes))
        case "absolute":
            guard let value = object["absoluteDate"]?.stringValue,
                let date = parseDate(value)
            else {
                throw ParseError.invalidAlarms("absolute element \(index) needs a valid absoluteDate")
            }
            alarms.append(.absolute(date))
        case "location":
            guard let title = object["title"]?.stringValue,
                let latitude = object["latitude"]?.numberValue,
                let longitude = object["longitude"]?.numberValue,
                let radius = object["radius"]?.numberValue,
                radius >= 0,
                let proximityValue = object["proximity"]?.stringValue,
                let proximity = ReminderAlarmModel.Proximity(rawValue: proximityValue),
                proximity != .none
            else {
                throw ParseError.invalidAlarms(
                    "location element \(index) needs title, coordinates, non-negative radius, and enter/leave proximity"
                )
            }
            guard (-90...90).contains(latitude), (-180...180).contains(longitude) else {
                throw ParseError.invalidAlarms("location element \(index) has invalid coordinates")
            }
            alarms.append(
                .location(
                    .init(title: title, latitude: latitude, longitude: longitude, radius: radius),
                    proximity: proximity
                ))
        default:
            throw ParseError.invalidAlarms("unknown kind '\(kind)' at element \(index)")
        }
    }
    return .set(alarms)
}

func parseDateField(
    _ object: [String: Value],
    key: String,
    timeZoneKey: String
) throws -> ReminderFieldUpdate<ReminderDateValue> {
    guard let value = object[key] else { return .unchanged }
    if value.isNull { return .clear }
    // Resolve the zone first: a date-only or zone-less input is a wall-clock time that
    // must be anchored in the caller's zone, not in the server's.
    let timeZoneIdentifier = try parseTimeZone(object[timeZoneKey])
    let timeZone = timeZoneIdentifier.flatMap(TimeZone.init(identifier:))
    guard let string = value.stringValue,
        let parsed = parseDateWithTimeInfo(string, in: timeZone)
    else {
        throw ParseError.invalidDateFormat(value.stringValue ?? "(non-string value)")
    }
    return .set(
        ReminderDateValue(
            date: parsed.date,
            timeZoneIdentifier: timeZoneIdentifier,
            isAllDay: !parsed.hasTime
        ))
}

func parseStringField(
    _ object: [String: Value],
    key: String
) throws -> ReminderFieldUpdate<String> {
    guard let value = object[key] else { return .unchanged }
    if value.isNull { return .clear }
    guard let string = value.stringValue else {
        throw ParseError.invalidStringValue(key)
    }
    return .set(string)
}

func parseURL(_ value: Value?) throws -> String? {
    guard let value else { return nil }
    if value.isNull { return nil }
    guard let string = value.stringValue,
        let url = URL(string: string),
        url.scheme?.isEmpty == false
    else {
        throw ParseError.invalidURL(value.stringValue ?? "(non-string value)")
    }
    return string
}

func parseURLField(_ object: [String: Value]) throws -> ReminderFieldUpdate<String> {
    guard let value = object["url"] else { return .unchanged }
    if value.isNull { return .clear }
    guard let url = try parseURL(value) else { return .unchanged }
    return .set(url)
}

func parseTimeZone(_ value: Value?) throws -> String? {
    guard let value else { return nil }
    if value.isNull { return nil }
    guard let identifier = value.stringValue, TimeZone(identifier: identifier) != nil else {
        throw ParseError.invalidTimeZone(value.stringValue ?? "(non-string value)")
    }
    return identifier
}

/// Parse recurrence field from upsert item
func parseRecurrenceField(_ itemObj: [String: Value]) throws -> ReminderFieldUpdate<String> {
    guard let value = itemObj["recurrence"] else {
        return .unchanged
    }

    if case .null = value {
        return .clear
    }

    guard let rrule = value.stringValue else {
        throw ParseError.invalidRRule("(non-string value)", "Recurrence must be an RRULE string")
    }

    // Validate by parsing (RRuleParser will throw if invalid)
    do {
        _ = try RRuleParser.parse(rrule)
    } catch {
        throw ParseError.invalidRRule(rrule, error.localizedDescription)
    }

    return .set(rrule)
}

private extension Value {
    var numberValue: Double? {
        switch self {
        case .int(let value): Double(value)
        case .double(let value): value
        default: nil
        }
    }
}
