import Foundation
import MCP
import Testing

@testable import EventKitMCP
@testable import EventKitService

@MainActor
@Suite("Write reminders create tests")
struct WriteRemindersCreateTests {
    @Test("A date-only due date anchors to the supplied time zone, not the server's")
    func dateOnlyAnchorsToSuppliedTimeZone() async throws {
        let service = MockReminderService()

        let result = await writeReminders(
            upsert: [
                [
                    "title": .string("All-day in Tokyo"),
                    "dueDate": .string("2026-03-15"),
                    "dueTimeZone": .string("Asia/Tokyo")
                ]
            ], service: service)

        result.expectSuccess()
        let reminder = try #require(service.mockReminders.first)
        #expect(reminder.dueTimeZone == "Asia/Tokyo")

        // The date-only branch used to hardcode TimeZone.current, so the instant landed
        // on local midnight. Anchored correctly it is midnight in Tokyo.
        var tokyoCalendar = Calendar(identifier: .gregorian)
        tokyoCalendar.timeZone = try #require(TimeZone(identifier: "Asia/Tokyo"))
        let due = try #require(reminder.dueDate)
        let parts = tokyoCalendar.dateComponents([.year, .month, .day, .hour], from: due)

        #expect(parts.year == 2026)
        #expect(parts.month == 3)
        #expect(parts.day == 15)
        #expect(parts.hour == 0)
    }

    @Test("A date-only due date without a time zone still uses the server zone")
    func dateOnlyWithoutTimeZoneUsesLocal() async throws {
        let service = MockReminderService()

        let result = await writeReminders(
            upsert: [
                [
                    "title": .string("All-day local"),
                    "dueDate": .string("2026-03-15")
                ]
            ], service: service)

        result.expectSuccess()
        let reminder = try #require(service.mockReminders.first)
        let due = try #require(reminder.dueDate)
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour], from: due)

        #expect(parts.year == 2026)
        #expect(parts.month == 3)
        #expect(parts.day == 15)
        #expect(parts.hour == 0)
    }

    @Test("Create single reminder via upsert")
    func testCreateSingleReminder() async throws {
        let result = await writeReminders(upsert: [
            [
                "title": .string("Buy groceries"),
                "notes": .string("Milk, eggs, bread"),
                "priority": .string("medium")
            ]
        ])

        result.expectText(containing: "Created 1", "Buy groceries", "Milk, eggs, bread")
    }

    @Test("Create multiple reminders via upsert")
    func testCreateMultipleReminders() async throws {
        let result = await writeReminders(upsert: [
            ["title": .string("Task 1")],
            ["title": .string("Task 2")],
            ["title": .string("Task 3")]
        ])

        result.expectText(containing: "Created 3")
    }

    @Test("Create with missing title reports failure")
    func testCreateMissingTitle() async throws {
        let result = await writeReminders(upsert: [["notes": .string("No title here")]])

        result.expectText(containing: "Failed", "upsert[0]", "Missing title")
    }

    @Test("Create reminder with URL")
    func testCreateWithURL() async throws {
        let result = await writeReminders(upsert: [
            [
                "title": .string("Check docs"),
                "url": .string("https://example.com/docs")
            ]
        ])

        result.expectText(containing: "Created 1", "URL: https://example.com/docs")
    }

    @Test("Create reminder with alarms")
    func testCreateWithAlarms() async throws {
        let result = await writeReminders(upsert: [
            [
                "title": .string("Meeting"),
                "dueDate": .string("2026-06-01T10:00:00"),
                "startDate": .string("2026-06-01T10:00:00"),
                "alarms": .array(
                    [0, 15, 60].map { minutes in
                        .object([
                            "kind": .string("relative"),
                            "minutesBefore": .int(minutes)
                        ])
                    })
            ]
        ])

        result.expectText(
            containing: "Created 1", "Alarms:", "at start", "15 min before start", "60 min before start"
        )
    }

    @Test("Create reminder with start date")
    func testCreateWithStartDate() async throws {
        let result = await writeReminders(upsert: [
            [
                "title": .string("Project kickoff"),
                "startDate": .string("2026-06-01T09:00:00"),
                "dueDate": .string("2026-06-15T17:00:00")
            ]
        ])

        result.expectText(containing: "Created 1", "Start:", "Due:")
    }

    @Test("Create reminder with all-day start date")
    func testCreateWithAllDayStartDate() async throws {
        let result = await writeReminders(upsert: [
            [
                "title": .string("Vacation"),
                "startDate": .string("2026-07-01")
            ]
        ])

        result.expectText(containing: "Created 1", "Start:")
    }

    @Test("Create fails an item whose field has the wrong type instead of dropping the field")
    func createRejectsWrongTypes() async throws {
        let fields: [(String, Value, String)] = [
            ("notes", .int(1), "Invalid notes: expected a string or null"),
            ("dueDate", .int(5), "Invalid date format: '(non-string value)'"),
            ("startDate", .int(5), "Invalid date format: '(non-string value)'"),
            ("url", .int(5), "Invalid URL: '(non-string value)'")
        ]
        for (key, value, message) in fields {
            let service = MockReminderService()
            let result = await writeReminders(upsert: [["title": .string("Typed"), key: value]], service: service)
            result.expectText(containing: "Failed", "Typed", message)
            #expect(service.createRequests.isEmpty, "\(key)")
        }
    }

    @Test("Create passes done and the parsed dates to the service")
    func createPassesDoneAndDates() async throws {
        let service = MockReminderService()
        let result = await writeReminders(
            upsert: [
                [
                    "title": .string("Already done"),
                    "done": .bool(true),
                    "dueDate": .string("2026-03-15"),
                    "dueTimeZone": .string("Asia/Tokyo"),
                    "startDate": .null
                ]
            ], service: service)

        result.expectText(containing: "Created 1")
        let request = try #require(service.createRequests.last)
        #expect(request.done)
        #expect(request.dueTimeZone == "Asia/Tokyo")
        #expect(request.isAllDay)
        #expect(request.startDate == nil && request.startTimeZone == nil)
    }

    @Test("Create reads a time-zone key only with its date, like update")
    func createIgnoresZoneWithoutDate() async throws {
        let service = MockReminderService()
        let result = await writeReminders(
            upsert: [["title": .string("Zoneless"), "dueTimeZone": .string("Mars/Base")]], service: service)
        result.expectText(containing: "Created 1")
        let request = try #require(service.createRequests.last)
        #expect(request.dueDate == nil && request.dueTimeZone == nil)
    }
}
