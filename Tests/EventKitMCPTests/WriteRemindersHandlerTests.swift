import Foundation
import Testing

@testable import EventKitMCP
@testable import EventKitService
import MCP

@MainActor
@Suite("Write Reminders Handler Tests")
struct WriteRemindersHandlerTests {

    @Test("Updating an unrelated field preserves alarms and time zones")
    func unrelatedUpdatePreservesExpandedFields() async {
        let service = MockReminderService()
        let alarms: [ReminderAlarmModel] = [
            .absolute(TestFixtures.todayNoon),
            .location(
                .init(title: "Office", latitude: 41.8781, longitude: -87.6298, radius: 100),
                proximity: .leave
            )
        ]
        service.mockReminders = [ReminderModel(
            id: "preserve",
            title: "Original",
            dueDate: TestFixtures.todayNoon,
            dueTimeZone: "America/Chicago",
            listId: "default",
            listName: "Default",
            startDate: TestFixtures.todayNoon,
            startTimeZone: "Europe/Paris",
            alarms: alarms
        )]

        let result = await writeReminders(upsert: [[
            "id": .string("preserve"),
            "title": .string("Updated")
        ]], service: service)

        result.expectSuccess()
        #expect(service.mockReminders[0].alarms == alarms)
        #expect(service.mockReminders[0].dueTimeZone == "America/Chicago")
        #expect(service.mockReminders[0].startTimeZone == "Europe/Paris")
    }

    @Test("Oversized batches are rejected before any EventKit work")
    func rejectsOversizedBatch() async {
        let service = MockReminderService()
        let items: [[String: Value]] = (0..<101).map { index in
            ["title": .string("Item \(index)")]
        }

        let result = await writeReminders(upsert: items, service: service)

        result.expectError(containing: "At most 100")
        // Nothing should have been written.
        #expect(service.mockReminders.isEmpty)
    }

    @Test("A batch at the limit is accepted")
    func acceptsBatchAtLimit() async {
        let service = MockReminderService()
        let items: [[String: Value]] = (0..<100).map { index in
            ["title": .string("Item \(index)")]
        }

        let result = await writeReminders(upsert: items, service: service)

        result.expectSuccess()
        #expect(service.mockReminders.count == 100)
    }

    @Test("The combined upsert and delete count is what is bounded")
    func boundsCombinedBatchCount() async {
        let upserts: [[String: Value]] = (0..<60).map { ["title": .string("Item \($0)")] }
        let deletes = (0..<60).map { "missing-\($0)" }

        let result = await writeReminders(upsert: upserts, delete: deletes)

        result.expectError(containing: "At most 100")
    }

    @Test("A date-only due date anchors to the supplied time zone, not the server's")
    func dateOnlyAnchorsToSuppliedTimeZone() async throws {
        let service = MockReminderService()

        let result = await writeReminders(upsert: [[
            "title": .string("All-day in Tokyo"),
            "dueDate": .string("2026-03-15"),
            "dueTimeZone": .string("Asia/Tokyo")
        ]], service: service)

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

        let result = await writeReminders(upsert: [[
            "title": .string("All-day local"),
            "dueDate": .string("2026-03-15")
        ]], service: service)

        result.expectSuccess()
        let reminder = try #require(service.mockReminders.first)
        let due = try #require(reminder.dueDate)
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour], from: due)

        #expect(parts.year == 2026)
        #expect(parts.month == 3)
        #expect(parts.day == 15)
        #expect(parts.hour == 0)
    }

    @Test("Explicit null clears every nullable reminder field")
    func explicitNullClearsFields() async {
        let service = MockReminderService()
        service.mockReminders = [ReminderModel(
            id: "clear-me",
            title: "Clear fields",
            notes: "notes",
            dueDate: TestFixtures.todayNoon,
            dueTimeZone: "America/Chicago",
            listId: "default",
            listName: "Default",
            recurrenceRule: "FREQ=DAILY",
            url: "https://example.com",
            location: "Office",
            startDate: TestFixtures.todayNoon,
            startTimeZone: "America/Chicago",
            alarms: [.relative(minutesBefore: 15)]
        )]

        let result = await writeReminders(upsert: [[
            "id": .string("clear-me"),
            "notes": .null,
            "dueDate": .null,
            "location": .null,
            "url": .null,
            "startDate": .null,
            "recurrence": .null,
            "alarms": .null
        ]], service: service)

        result.expectSuccess()
        let reminder = service.mockReminders[0]
        #expect(reminder.notes == nil)
        #expect(reminder.dueDate == nil)
        #expect(reminder.dueTimeZone == nil)
        #expect(reminder.location == nil)
        #expect(reminder.url == nil)
        #expect(reminder.startDate == nil)
        #expect(reminder.startTimeZone == nil)
        #expect(reminder.recurrenceRule == nil)
        #expect(reminder.alarms == nil)
    }

    // MARK: - Create Tests (upsert without id)

    @Test("Create single reminder via upsert")
    func testCreateSingleReminder() async throws {
        let result = await writeReminders(upsert: [[
            "title": .string("Buy groceries"),
            "notes": .string("Milk, eggs, bread"),
            "priority": .string("medium")
        ]])

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
        let result = await writeReminders(upsert: [[
            "title": .string("Check docs"),
            "url": .string("https://example.com/docs")
        ]])

        result.expectText(containing: "Created 1", "URL: https://example.com/docs")
    }

    @Test("Update reminder with URL")
    func testUpdateWithURL() async throws {
        let service = MockReminderService()
        service.mockReminders = [
            TestFixtures.reminder(id: "rem-1", title: "Check docs")
        ]

        let result = await writeReminders(upsert: [[
            "id": .string("rem-1"),
            "url": .string("https://example.com/updated")
        ]], service: service)

        result.expectText(containing: "Updated 1", "URL: https://example.com/updated")
    }

    @Test("Create reminder with location")
    func testCreateWithLocation() async throws {
        let result = await writeReminders(upsert: [[
            "title": .string("Meeting"),
            "location": .string("Conference Room B")
        ]])

        result.expectText(containing: "Created 1", "Location: Conference Room B")
    }

    @Test("Update reminder with location")
    func testUpdateWithLocation() async throws {
        let service = MockReminderService()
        service.mockReminders = [
            TestFixtures.reminder(id: "rem-1", title: "Meeting")
        ]

        let result = await writeReminders(upsert: [[
            "id": .string("rem-1"),
            "location": .string("Room 42")
        ]], service: service)

        result.expectText(containing: "Updated 1", "Location: Room 42")
    }

    @Test("Create reminder with alarms")
    func testCreateWithAlarms() async throws {
        let result = await writeReminders(upsert: [[
            "title": .string("Meeting"),
            "dueDate": .string("2026-06-01T10:00:00"),
            "startDate": .string("2026-06-01T10:00:00"),
            "alarms": .array([0, 15, 60].map { minutes in
                .object([
                    "kind": .string("relative"),
                    "minutesBefore": .int(minutes)
                ])
            })
        ]])

        result.expectText(
            containing: "Created 1", "Alarms:", "at start", "15 min before start", "60 min before start"
        )
    }

    @Test("Update reminder alarms")
    func testUpdateAlarms() async throws {
        let service = MockReminderService()
        service.mockReminders = [
            TestFixtures.reminder(
                id: "rem-1",
                title: "Meeting",
                startDate: TestFixtures.todayNoon,
                alarms: [15]
            )
        ]

        let result = await writeReminders(upsert: [[
            "id": .string("rem-1"),
            "alarms": .array([.object([
                "kind": .string("relative"),
                "minutesBefore": .int(30)
            ])])
        ]], service: service)

        result.expectText(containing: "Updated 1", "30 min before")
    }

    @Test("Remove alarms with null")
    func testRemoveAlarms() async throws {
        let service = MockReminderService()
        service.mockReminders = [
            TestFixtures.reminder(id: "rem-1", title: "Meeting", alarms: [15, 60])
        ]

        let result = await writeReminders(upsert: [[
            "id": .string("rem-1"),
            "alarms": .null
        ]], service: service)

        result.expectText(containing: "Updated 1")
        result.expectTextNot(containing: "Alarms:")
    }

    @Test("Create reminder with start date")
    func testCreateWithStartDate() async throws {
        let result = await writeReminders(upsert: [[
            "title": .string("Project kickoff"),
            "startDate": .string("2026-06-01T09:00:00"),
            "dueDate": .string("2026-06-15T17:00:00")
        ]])

        result.expectText(containing: "Created 1", "Start:", "Due:")
    }

    @Test("Create reminder with all-day start date")
    func testCreateWithAllDayStartDate() async throws {
        let result = await writeReminders(upsert: [[
            "title": .string("Vacation"),
            "startDate": .string("2026-07-01")
        ]])

        result.expectText(containing: "Created 1", "Start:")
    }

    @Test("Remove start date with null")
    func testRemoveStartDate() async throws {
        let service = MockReminderService()
        service.mockReminders = [
            TestFixtures.reminder(id: "rem-1", title: "Task", startDate: TestFixtures.tomorrow)
        ]

        let result = await writeReminders(upsert: [[
            "id": .string("rem-1"),
            "startDate": .null
        ]], service: service)

        result.expectText(containing: "Updated 1")
        result.expectTextNot(containing: "Start:")
    }

    // MARK: - Update Tests (upsert with id)

    @Test("Update single reminder via upsert with id")
    func testUpdateSingleReminder() async throws {
        let service = MockReminderService()
        service.mockReminders = [
            TestFixtures.reminder(id: "rem-1", title: "Original")
        ]

        let result = await writeReminders(upsert: [[
            "id": .string("rem-1"),
            "title": .string("Updated title"),
            "done": .bool(true)
        ]], service: service)

        result.expectText(containing: "Updated 1", "Updated title")
    }

    @Test("Update multiple reminders via upsert")
    func testUpdateMultipleReminders() async throws {
        let service = MockReminderService()
        service.mockReminders = [
            TestFixtures.reminder(id: "rem-1", title: "Task 1"),
            TestFixtures.reminder(id: "rem-2", title: "Task 2")
        ]

        let result = await writeReminders(upsert: [
            ["id": .string("rem-1"), "done": .bool(true)],
            ["id": .string("rem-2"), "priority": .string("high")]
        ], service: service)

        result.expectText(containing: "Updated 2")
    }

    // MARK: - Delete Tests

    @Test("Delete single reminder returns full details")
    func testDeleteSingleReminder() async throws {
        let service = MockReminderService()
        service.mockReminders = [
            TestFixtures.reminder(id: "rem-1", title: "To delete", notes: "Some notes", priority: .high)
        ]

        let result = await writeReminders(delete: ["rem-1"], service: service)

        result.expectText(
            containing: "Deleted 1 of 1", "To delete", "ID: rem-1", "List: Work",
            "Notes: Some notes", "Priority: High"
        )
    }

    @Test("Delete multiple reminders returns full details")
    func testDeleteMultipleReminders() async throws {
        let service = MockReminderService()
        service.mockReminders = [
            TestFixtures.reminder(id: "rem-1", title: "Task 1"),
            TestFixtures.reminder(id: "rem-2", title: "Task 2", priority: .medium)
        ]

        let result = await writeReminders(delete: ["rem-1", "rem-2"], service: service)

        result.expectText(containing: "Deleted 2 of 2", "Task 1", "Task 2", "ID: rem-1", "ID: rem-2")
    }

    // MARK: - Mixed Operations Tests

    @Test("Mixed create and update in single call")
    func testMixedCreateAndUpdate() async throws {
        let service = MockReminderService()
        service.mockReminders = [
            TestFixtures.reminder(id: "existing-1", title: "Existing task")
        ]

        let result = await writeReminders(upsert: [
            ["title": .string("New task")],  // create (no id)
            ["id": .string("existing-1"), "done": .bool(true)]  // update (has id)
        ], service: service)

        result.expectText(containing: "Created 1", "Updated 1")
    }

    @Test("Mixed delete and upsert in single call")
    func testMixedDeleteAndUpsert() async throws {
        let service = MockReminderService()
        service.mockReminders = [
            TestFixtures.reminder(id: "to-delete", title: "Old task")
        ]

        let result = await writeReminders(
            upsert: [["title": .string("Replacement task")]],
            delete: ["to-delete"],
            service: service
        )

        result.expectText(containing: "Deleted 1 of 1", "Created 1", "Replacement task")
    }

    // MARK: - Validation Tests

    @Test("Empty input returns error")
    func testEmptyInput() async throws {
        let result = await callTool("write_reminders", arguments: [:])

        result.expectError(containing: "At least one of 'upsert' or 'delete' required")
    }

    @Test("Empty arrays returns error")
    func testEmptyArrays() async throws {
        let result = await callTool("write_reminders", arguments: [
            "upsert": .array([]),
            "delete": .array([])
        ])

        result.expectError(containing: "At least one of 'upsert' or 'delete' required")
    }

    @Test("Invalid date format reports failure")
    func testInvalidDateFormat() async throws {
        let result = await writeReminders(upsert: [[
            "title": .string("Task with bad date"),
            "dueDate": .string("next tuesday")
        ]])

        result.expectText(containing: "Failed", "Invalid date")
    }

    @Test("Invalid priority reports failure")
    func testInvalidPriority() async throws {
        let result = await writeReminders(upsert: [[
            "title": .string("Task with bad priority"),
            "priority": .string("urgent")
        ]])

        result.expectText(containing: "Failed", "Invalid priority")
    }

    // MARK: - Partial Failure Tests

    @Test("Partial failure in upsert reports successes and failures")
    func testPartialFailureUpsert() async throws {
        let result = await writeReminders(upsert: [
            ["title": .string("Valid task 1")],
            ["notes": .string("Missing title")],  // will fail
            ["title": .string("Valid task 2")]
        ])

        result.expectText(containing: "Created 2", "Failed", "upsert[1]", "Missing title")
    }
}
