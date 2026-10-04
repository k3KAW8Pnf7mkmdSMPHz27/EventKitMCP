import EventKit
import Foundation
import Testing

@testable import EventKitService

@Suite("EventKit mapping tests")
struct EventKitMappingTests {
    /// 2026-01-06 01:30 UTC, which is 10:30 the same day in Tokyo.
    private let instant = Date(timeIntervalSince1970: 1_767_663_000)

    @Test("Date components are floating without a zone, zoned with one, and day-only when all-day")
    func dateComponents() throws {
        let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
        var local = Calendar(identifier: .gregorian)
        local.timeZone = .current
        let localParts = local.dateComponents([.year, .month, .day, .hour, .minute], from: instant)

        let floating = try EventKitMapping.dateComponents(from: instant, allDay: false, timeZoneIdentifier: nil)
        #expect(floating.timeZone == nil)
        #expect([floating.year, floating.month, floating.day] == [localParts.year, localParts.month, localParts.day])
        #expect([floating.hour, floating.minute] == [localParts.hour, localParts.minute])

        let zoned = try EventKitMapping.dateComponents(from: instant, allDay: false, timeZoneIdentifier: "Asia/Tokyo")
        #expect(zoned.timeZone == tokyo)
        #expect([zoned.year, zoned.month, zoned.day, zoned.hour, zoned.minute] == [2026, 1, 6, 10, 30])

        let allDay = try EventKitMapping.dateComponents(from: instant, allDay: true, timeZoneIdentifier: "Asia/Tokyo")
        #expect(allDay.timeZone == tokyo)
        #expect([allDay.year, allDay.month, allDay.day] == [2026, 1, 6])
        #expect(allDay.hour == nil && allDay.minute == nil)

        #expect(throws: ReminderServiceError.invalidTimeZone("Mars/Base")) {
            try EventKitMapping.dateComponents(from: instant, allDay: false, timeZoneIdentifier: "Mars/Base")
        }
    }

    @Test("Hex colours round-trip and malformed ones are rejected")
    func colors() {
        for (input, normalized) in [("#FF5733", "#FF5733"), ("ff5733", "#FF5733"), ("#000000", "#000000")] {
            #expect(EventKitMapping.hexFromColor(EventKitMapping.colorFromHex(input)) == normalized, "\(input)")
        }
        for bad in ["#FFF", "GG5733", "#FF57331", ""] {
            #expect(EventKitMapping.colorFromHex(bad) == nil, "\(bad)")
        }
        #expect(EventKitMapping.hexFromColor(nil) == nil)
    }

    @Test("Alarms round-trip through EventKit for every kind")
    func alarmRoundTrip() throws {
        let office = ReminderAlarmModel.StructuredLocation(
            title: "Office", latitude: 41.8781, longitude: -87.6298, radius: 100)
        let models: [ReminderAlarmModel] = [
            .relative(minutesBefore: 0),
            .relative(minutesBefore: 15),
            .absolute(instant),
            .location(office, proximity: .enter),
            .location(office, proximity: .leave),
            .location(office, proximity: .none)
        ]
        for model in models {
            let alarm = try EventKitMapping.makeAlarm(model)
            #expect(EventKitMapping.mapAlarm(alarm) == model, "\(model)")
        }
        #expect(throws: ReminderServiceError.invalidAlarm) {
            try EventKitMapping.makeAlarm(.relative(minutesBefore: -1))
        }
    }

    @Test("Relative alarms need a start date and a non-negative offset")
    func alarmReferences() throws {
        try EventKitMapping.validateAlarmReferences([.relative(minutesBefore: 5)], hasStartDate: true)
        try EventKitMapping.validateAlarmReferences([.absolute(instant)], hasStartDate: false)
        #expect(throws: ReminderServiceError.relativeAlarmRequiresStartDate) {
            try EventKitMapping.validateAlarmReferences([.relative(minutesBefore: 5)], hasStartDate: false)
        }
        #expect(throws: ReminderServiceError.invalidAlarm) {
            try EventKitMapping.validateAlarmReferences([.relative(minutesBefore: -5)], hasStartDate: true)
        }
    }

    @Test("URLs need a scheme")
    func urls() throws {
        #expect(try EventKitMapping.validatedURL("https://example.com/a").absoluteString == "https://example.com/a")
        #expect(try EventKitMapping.validatedURL("mailto:a@example.com").scheme == "mailto")
        #expect(throws: ReminderServiceError.invalidURL("example.com")) {
            try EventKitMapping.validatedURL("example.com")
        }
    }
}
