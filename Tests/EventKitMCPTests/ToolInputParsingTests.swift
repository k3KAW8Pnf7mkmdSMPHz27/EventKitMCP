import Foundation
import MCP
import Testing

@testable import EventKitMCP
@testable import EventKitService

@Suite("Tool input parsing tests")
struct ToolInputParsingTests {
    private let tokyo = TimeZone(identifier: "Asia/Tokyo")!

    private func calendar(in timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    private func components(_ date: Date, in timeZone: TimeZone) -> [Int?] {
        let parts = calendar(in: timeZone).dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return [parts.year, parts.month, parts.day, parts.hour, parts.minute]
    }

    private func state<T>(_ update: ReminderFieldUpdate<T>) -> String {
        switch update {
        case .unchanged: "unchanged"
        case .clear: "clear"
        case .set: "set"
        }
    }

    private func expectParseError(
        _ expected: String,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ body: () throws -> Void
    ) {
        let error = #expect(throws: ParseError.self, sourceLocation: sourceLocation) { try body() }
        #expect(
            error?.errorDescription?.hasPrefix(expected) == true,
            "got: \(error?.errorDescription ?? "nil")",
            sourceLocation: sourceLocation
        )
    }

    @Test("Date inputs parse to the instant and all-day flag their form implies")
    func dateForms() throws {
        let utc = TimeZone(identifier: "UTC")!
        // An explicit offset wins over the caller's zone; wall-clock and date-only forms use it.
        let cases: [(input: String, zone: TimeZone?, readIn: TimeZone, expected: [Int?], isAllDay: Bool)] = [
            ("2026-01-06T10:00:00Z", nil, utc, [2026, 1, 6, 10, 0], false),
            ("2026-01-06T10:00:00Z", tokyo, utc, [2026, 1, 6, 10, 0], false),
            ("2026-01-06T10:00:00.250Z", nil, utc, [2026, 1, 6, 10, 0], false),
            ("2026-01-06T10:00:00-06:00", tokyo, utc, [2026, 1, 6, 16, 0], false),
            ("2026-01-06T10:00:00", tokyo, tokyo, [2026, 1, 6, 10, 0], false),
            ("2026-01-06T10:00:00", nil, .current, [2026, 1, 6, 10, 0], false),
            ("2026-01-06", tokyo, tokyo, [2026, 1, 6, 0, 0], true),
            ("2026-01-06", nil, .current, [2026, 1, 6, 0, 0], true)
        ]
        for testCase in cases {
            let parsed = try #require(try requireDateWithTimeInfo(testCase.input, in: testCase.zone))
            #expect(components(parsed.date, in: testCase.readIn) == testCase.expected, "\(testCase.input)")
            #expect(parsed.isAllDay == testCase.isAllDay, "\(testCase.input)")
        }

        #expect(try requireDateWithTimeInfo(nil) == nil)
        for bad in ["06/01/2026", "2026-13-01", "tomorrow", ""] {
            expectParseError("Invalid date format: '\(bad)'. Use ISO8601") { _ = try requireDateWithTimeInfo(bad) }
        }
    }

    @Test("Three-state fields distinguish absent, null, a value and a wrong type")
    func threeStateFields() throws {
        let fields: [(key: String, value: Value, parse: ([String: Value]) throws -> String, wrongType: String)] = [
            (
                "notes", .string("n"), { state(try parseStringField($0, key: "notes")) },
                "Invalid notes: expected a string or null"
            ),
            (
                "dueDate", .string("2026-01-06"), { state(try parseDateField($0, key: "dueDate", timeZoneKey: "tz")) },
                "Invalid date format: '(non-string value)'"
            ),
            (
                "url", .string("https://example.com"), { state(try parseURLField($0)) },
                "Invalid URL: '(non-string value)'"
            ),
            (
                "recurrence", .string("FREQ=DAILY"), { state(try parseRecurrenceField($0)) },
                "Invalid RRULE: '(non-string value)'. Recurrence must be an RRULE string"
            ),
            (
                "alarms", .array([]), { state(try parseAlarmsField($0)) },
                "Invalid alarms: expected an array or null"
            )
        ]
        for field in fields {
            #expect(try field.parse([:]) == "unchanged", "\(field.key)")
            #expect(try field.parse([field.key: .null]) == "clear", "\(field.key)")
            #expect(try field.parse([field.key: field.value]) == "set", "\(field.key)")
            expectParseError(field.wrongType) { _ = try field.parse([field.key: .int(1)]) }
        }

        #expect(try parseStringField(["notes": .string("n")], key: "notes") == .set("n"))
        #expect(try parseURLField(["url": .string("mailto:a@example.com")]) == .set("mailto:a@example.com"))
        expectParseError("Invalid URL: 'example.com'") { _ = try parseURLField(["url": .string("example.com")]) }
        #expect(
            try parseRecurrenceField(["recurrence": .string("FREQ=WEEKLY;BYDAY=MO")]) == .set("FREQ=WEEKLY;BYDAY=MO"))
        expectParseError("Invalid RRULE: 'FREQ=SOMETIMES'. ") {
            _ = try parseRecurrenceField(["recurrence": .string("FREQ=SOMETIMES")])
        }
    }

    @Test("Date fields resolve their time zone first and anchor to it")
    func dateFieldTimeZones() throws {
        let tokyoMidnight = try #require(calendar(in: tokyo).date(from: DateComponents(year: 2026, month: 1, day: 6)))
        #expect(
            try parseDateField(
                ["startDate": .string("2026-01-06"), "startTimeZone": .string("Asia/Tokyo")],
                key: "startDate", timeZoneKey: "startTimeZone"
            ) == .set(ReminderDateValue(date: tokyoMidnight, timeZoneIdentifier: "Asia/Tokyo", isAllDay: true)))
        #expect(
            try parseDateField(
                ["startDate": .string("2026-01-06T09:00:00"), "startTimeZone": .string("Asia/Tokyo")],
                key: "startDate", timeZoneKey: "startTimeZone"
            )
                == .set(
                    ReminderDateValue(
                        date: tokyoMidnight.addingTimeInterval(9 * 3600), timeZoneIdentifier: "Asia/Tokyo",
                        isAllDay: false
                    )))
        expectParseError("Unknown time zone: 'Mars/Base'") {
            _ = try parseDateField(
                ["dueDate": .int(1), "dueTimeZone": .string("Mars/Base")], key: "dueDate", timeZoneKey: "dueTimeZone")
        }

        #expect(try parseTimeZone(nil) == nil)
        #expect(try parseTimeZone(.null) == nil)
        #expect(try parseTimeZone(.string("Asia/Tokyo")) == "Asia/Tokyo")
        expectParseError("Unknown time zone: '(non-string value)'") { _ = try parseTimeZone(.int(9)) }
    }

    @Test("Alarms parse every kind and reject each malformed shape with its own message")
    func alarms() throws {
        let absoluteDate = try #require(try requireDateWithTimeInfo("2026-01-06T10:00:00Z")).date
        #expect(
            try parseAlarmsField([
                "alarms": .array([
                    .object(["kind": .string("relative"), "minutesBefore": .int(0)]),
                    .object(["kind": .string("absolute"), "absoluteDate": .string("2026-01-06T10:00:00Z")]),
                    .object([
                        "kind": .string("location"), "title": .string("Office"), "latitude": .int(41),
                        "longitude": .double(-87.5), "radius": .int(100), "proximity": .string("leave")
                    ])
                ])
            ])
                == .set([
                    .relative(minutesBefore: 0),
                    .absolute(absoluteDate),
                    .location(.init(title: "Office", latitude: 41, longitude: -87.5, radius: 100), proximity: .leave)
                ]))

        func location(_ overrides: [String: Value]) -> Value {
            let base: [String: Value] = [
                "kind": .string("location"), "title": .string("Office"), "latitude": .double(41.9),
                "longitude": .double(-87.6), "radius": .int(100), "proximity": .string("enter")
            ]
            return .object(base.merging(overrides) { $1 })
        }
        let needs = "location element 0 needs title, coordinates, non-negative radius, and enter/leave proximity"
        let invalid: [(Value, String)] = [
            (.string("15"), "expected an array or null"),
            (.array([.int(15)]), "element 0 must be an alarm object with a kind"),
            (.array([.object(["minutesBefore": .int(5)])]), "element 0 must be an alarm object with a kind"),
            (
                .array([.object(["kind": .string("relative"), "minutesBefore": .int(-1)])]),
                "relative element 0 needs non-negative integer minutesBefore"
            ),
            (
                .array([.object(["kind": .string("relative"), "minutesBefore": .double(5)])]),
                "relative element 0 needs non-negative integer minutesBefore"
            ),
            (
                .array([.object(["kind": .string("absolute"), "absoluteDate": .string("soon")])]),
                "absolute element 0 needs a valid absoluteDate"
            ),
            (.array([location(["proximity": .null])]), needs),
            (.array([location(["proximity": .string("none")])]), needs),
            (.array([location(["radius": .int(-1)])]), needs),
            (.array([location(["title": .null])]), needs),
            (.array([location(["latitude": .int(91)])]), "location element 0 has invalid coordinates"),
            (.array([location(["longitude": .int(-181)])]), "location element 0 has invalid coordinates"),
            (
                .array([
                    .object(["kind": .string("relative"), "minutesBefore": .int(5)]),
                    .object(["kind": .string("sometimes")])
                ]),
                "unknown kind 'sometimes' at element 1"
            )
        ]
        for (value, message) in invalid {
            expectParseError("Invalid alarms: \(message)") { _ = try parseAlarmsField(["alarms": value]) }
        }
    }

    @Test("Numeric query parameters take JSON integers within their bounds")
    func numericBounds() throws {
        #expect(try requireDays(nil) == 7)
        #expect(try requireLimit(nil) == 25)
        #expect(try requireOffset(nil) == 0)
        for days in [1, 3650] { #expect(try requireDays(.int(days)) == days) }
        for limit in [1, 100] { #expect(try requireLimit(.int(limit)) == limit) }
        #expect(try requireOffset(.int(1_000_000)) == 1_000_000)

        // Out-of-range integers are described as "invalid value"; only strings and doubles echo.
        let days: [(Value, String)] = [
            (.int(0), "invalid value"), (.int(3651), "invalid value"), (.string("7"), "7"), (.double(7), "7.0")
        ]
        for (value, echoed) in days {
            expectParseError("Invalid days value: '\(echoed)'. Must be an integer from 1 through 3650") {
                _ = try requireDays(value)
            }
        }
        for value: Value in [.int(0), .int(101), .double(25), .string("25")] {
            expectParseError("Invalid pagination: limit must be an integer from 1 through 100") {
                _ = try requireLimit(value)
            }
        }
        for value: Value in [.int(-1), .string("0")] {
            expectParseError("Invalid pagination: offset must be a non-negative integer") {
                _ = try requireOffset(value)
            }
        }
    }

    @Test("Enumerated and patterned strings map exactly and reject everything else")
    func enumeratedStrings() throws {
        let priorities: [(String, ReminderPriority)] = [
            ("high", .high), ("medium", .medium), ("low", .low), ("none", .none)
        ]
        for (input, priority) in priorities {
            #expect(try requirePriority(input) == priority, "\(input)")
        }
        #expect(try requirePriority(nil) == nil)
        for bad in ["urgent", "High", ""] {
            expectParseError("Invalid priority: '\(bad)'. Use 'high', 'medium', 'low', or 'none'") {
                _ = try requirePriority(bad)
            }
        }

        #expect(try requireFilter(nil) == .all)
        for filter in [QueryFilter.all, .overdue, .today, .upcoming] {
            #expect(try requireFilter(filter.rawValue) == filter)
        }
        expectParseError("Invalid filter: 'weekly'. Use 'all', 'overdue', 'today', or 'upcoming'") {
            _ = try requireFilter("weekly")
        }

        #expect(try requireColor(nil) == nil)
        for color in ["#FF5733", "ff5733", "#abcdef"] {
            #expect(try requireColor(color) == color)
        }
        for bad in ["#FFF", "#GG5733", "FF57331", "#FF5733 ", ""] {
            expectParseError("Invalid color format: '\(bad)'. Use hex format") { _ = try requireColor(bad) }
        }
    }
}
