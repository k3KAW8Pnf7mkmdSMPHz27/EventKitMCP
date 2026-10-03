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

/// Parse a date string; the date-only form is all-day.
private func parseDateWithTimeInfo(_ string: String?, in timeZone: TimeZone? = nil) -> (date: Date, isAllDay: Bool)? {
    guard let string = string else { return nil }

    let formatter = ISO8601DateFormatter()

    // ISO8601 with fractional seconds - has time
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: string) {
        return (date, false)
    }

    // ISO8601 without fractional seconds - has time
    formatter.formatOptions = [.withInternetDateTime]
    if let date = formatter.date(from: string) {
        return (date, false)
    }

    // Fallback: local datetime (no timezone = local time) - has time
    // A caller-supplied time zone anchors wall-clock inputs; otherwise they are local.
    let localFormatter = DateFormatter()
    localFormatter.locale = Locale(identifier: "en_US_POSIX")
    localFormatter.timeZone = timeZone ?? TimeZone.current

    localFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    if let date = localFormatter.date(from: string) {
        return (date, false)
    }

    // Date-only format - no time (all-day)
    localFormatter.dateFormat = "yyyy-MM-dd"
    if let date = localFormatter.date(from: string) {
        return (date, true)
    }

    return nil
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

/// Three-state field: absent leaves it unchanged, null clears it, anything else is parsed.
private func parseField<T: Sendable>(
    _ object: [String: Value],
    key: String,
    _ parse: (Value) throws -> T
) throws -> ReminderFieldUpdate<T> {
    guard let value = object[key] else { return .unchanged }
    if value.isNull { return .clear }
    return .set(try parse(value))
}

func parseAlarmsField(_ itemObj: [String: Value]) throws -> ReminderFieldUpdate<[ReminderAlarmModel]> {
    try parseField(itemObj, key: "alarms") { value in
        guard let array = value.arrayValue else {
            throw ParseError.invalidAlarms("expected an array or null")
        }
        // EventKit keeps one zone per reminder and the start date's wins, so wall-clock
        // absolute alarms anchor to the start zone, else the due zone.
        let zone = try (parseTimeZone(itemObj["startTimeZone"]) ?? parseTimeZone(itemObj["dueTimeZone"]))
            .flatMap(TimeZone.init(identifier:))
        return try array.enumerated().map { index, element in try parseAlarm(element, at: index, in: zone) }
    }
}

private func parseAlarm(_ element: Value, at index: Int, in timeZone: TimeZone?) throws -> ReminderAlarmModel {
    guard let object = element.objectValue, let kind = object["kind"]?.stringValue else {
        throw ParseError.invalidAlarms("element \(index) must be an alarm object with a kind")
    }
    switch ReminderAlarmKindInput(rawValue: kind) {
    case .relative:
        guard let minutes = object["minutesBefore"]?.intValue, minutes >= 0 else {
            throw ParseError.invalidAlarms("relative element \(index) needs non-negative integer minutesBefore")
        }
        return .relative(minutesBefore: minutes)
    case .absolute:
        guard let date = parseDateWithTimeInfo(object["absoluteDate"]?.stringValue, in: timeZone)?.date else {
            throw ParseError.invalidAlarms("absolute element \(index) needs a valid absoluteDate")
        }
        return .absolute(date)
    case .location:
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
        return .location(
            .init(title: title, latitude: latitude, longitude: longitude, radius: radius),
            proximity: proximity
        )
    case nil:
        throw ParseError.invalidAlarms("unknown kind '\(kind)' at element \(index)")
    }
}

func parseDateField(
    _ object: [String: Value],
    key: String,
    timeZoneKey: String
) throws -> ReminderFieldUpdate<ReminderDateValue> {
    try parseField(object, key: key) { value in
        // Resolve the zone first: a date-only or zone-less input is a wall-clock time that
        // must be anchored in the caller's zone, not in the server's.
        let timeZoneIdentifier = try parseTimeZone(object[timeZoneKey])
        let timeZone = timeZoneIdentifier.flatMap(TimeZone.init(identifier:))
        guard let parsed = parseDateWithTimeInfo(value.stringValue, in: timeZone) else {
            throw ParseError.invalidDateFormat(value.unparsableText)
        }
        return ReminderDateValue(date: parsed.date, timeZoneIdentifier: timeZoneIdentifier, isAllDay: parsed.isAllDay)
    }
}

func parseStringField(_ object: [String: Value], key: String) throws -> ReminderFieldUpdate<String> {
    try parseField(object, key: key) { value in
        guard let string = value.stringValue else {
            throw ParseError.invalidStringValue(key)
        }
        return string
    }
}

func parseURLField(_ object: [String: Value]) throws -> ReminderFieldUpdate<String> {
    try parseField(object, key: "url", validatedURLString)
}

private func validatedURLString(_ value: Value) throws -> String {
    guard let string = value.stringValue,
        let url = URL(string: string),
        url.scheme?.isEmpty == false
    else {
        throw ParseError.invalidURL(value.unparsableText)
    }
    return string
}

func parseTimeZone(_ value: Value?) throws -> String? {
    guard let value, !value.isNull else { return nil }
    guard let identifier = value.stringValue, TimeZone(identifier: identifier) != nil else {
        throw ParseError.invalidTimeZone(value.unparsableText)
    }
    return identifier
}

func parseRecurrenceField(_ itemObj: [String: Value]) throws -> ReminderFieldUpdate<String> {
    try parseField(itemObj, key: "recurrence") { value in
        guard let rrule = value.stringValue else {
            throw ParseError.invalidRRule(value.unparsableText, "Recurrence must be an RRULE string")
        }
        // Validate by parsing (RRuleParser will throw if invalid)
        do {
            _ = try RRuleParser.parse(rrule)
        } catch {
            throw ParseError.invalidRRule(rrule, error.localizedDescription)
        }
        return rrule
    }
}

private extension Value {
    var numberValue: Double? {
        switch self {
        case .int(let value): Double(value)
        case .double(let value): value
        default: nil
        }
    }

    /// The string itself, or a placeholder for error messages when the value is not a string.
    var unparsableText: String {
        stringValue ?? "(non-string value)"
    }
}
