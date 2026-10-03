import Foundation
import Testing

@testable import EventKitMCP
@testable import EventKitService
import MCP

@MainActor
@Suite("Write Reminders Handler Tests")
struct WriteRemindersHandlerTests {
    @Test("Omitted fields are sent as unchanged")
    func omittedFieldsAreSentAsUnchanged() async throws {
        let service = MockReminderService()
        service.mockReminders = [TestFixtures.reminder(id: "preserve", title: "Original")]

        let result = await writeReminders(
            upsert: [
                [
                    "id": .string("preserve"),
                    "title": .string("Updated")
                ]
            ], service: service)

        result.expectSuccess()
        let request = try #require(service.updateRequests.last)
        #expect(request.title == "Updated")
        #expect(request.done == nil && request.priority == nil && request.listId == nil)
        #expect(request.notes == .unchanged)
        #expect(request.dueDate == .unchanged)
        #expect(request.recurrenceRule == .unchanged)
        #expect(request.location == .unchanged)
        #expect(request.url == .unchanged)
        #expect(request.startDate == .unchanged)
        #expect(request.alarms == .unchanged)
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

    @Test("Explicit null clears every nullable reminder field")
    func explicitNullClearsFields() async throws {
        let service = MockReminderService()
        service.mockReminders = [TestFixtures.reminder(id: "clear-me", title: "Clear fields")]

        let result = await writeReminders(
            upsert: [
                [
                    "id": .string("clear-me"),
                    "notes": .null,
                    "dueDate": .null,
                    "location": .null,
                    "url": .null,
                    "startDate": .null,
                    "recurrence": .null,
                    "alarms": .null
                ]
            ], service: service)

        result.expectSuccess()
        let request = try #require(service.updateRequests.last)
        #expect(request.notes == .clear)
        #expect(request.dueDate == .clear)
        #expect(request.location == .clear)
        #expect(request.url == .clear)
        #expect(request.startDate == .clear)
        #expect(request.recurrenceRule == .clear)
        #expect(request.alarms == .clear)
    }

    @Test("Update reminder with URL")
    func testUpdateWithURL() async throws {
        let service = MockReminderService()
        service.mockReminders = [
            TestFixtures.reminder(id: "rem-1", title: "Check docs")
        ]

        let result = await writeReminders(
            upsert: [
                [
                    "id": .string("rem-1"),
                    "url": .string("https://example.com/updated")
                ]
            ], service: service)

        result.expectText(containing: "Updated 1")
        #expect(service.updateRequests.last?.url == .set("https://example.com/updated"))
    }

    @Test("Update reminder with location")
    func testUpdateWithLocation() async throws {
        let service = MockReminderService()
        service.mockReminders = [
            TestFixtures.reminder(id: "rem-1", title: "Meeting")
        ]

        let result = await writeReminders(
            upsert: [
                [
                    "id": .string("rem-1"),
                    "location": .string("Room 42")
                ]
            ], service: service)

        result.expectText(containing: "Updated 1")
        #expect(service.updateRequests.last?.location == .set("Room 42"))
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

        let result = await writeReminders(
            upsert: [
                [
                    "id": .string("rem-1"),
                    "alarms": .array([
                        .object([
                            "kind": .string("relative"),
                            "minutesBefore": .int(30)
                        ])
                    ])
                ]
            ], service: service)

        result.expectText(containing: "Updated 1")
        #expect(service.updateRequests.last?.alarms == .set([.relative(minutesBefore: 30)]))
    }

    @Test("Remove alarms with null")
    func testRemoveAlarms() async throws {
        let service = MockReminderService()
        service.mockReminders = [
            TestFixtures.reminder(id: "rem-1", title: "Meeting", alarms: [15, 60])
        ]

        let result = await writeReminders(
            upsert: [
                [
                    "id": .string("rem-1"),
                    "alarms": .null
                ]
            ], service: service)

        result.expectText(containing: "Updated 1")
        #expect(service.updateRequests.last?.alarms == .clear)
    }

    @Test("Remove start date with null")
    func testRemoveStartDate() async throws {
        let service = MockReminderService()
        service.mockReminders = [
            TestFixtures.reminder(id: "rem-1", title: "Task", startDate: TestFixtures.tomorrow)
        ]

        let result = await writeReminders(
            upsert: [
                [
                    "id": .string("rem-1"),
                    "startDate": .null
                ]
            ], service: service)

        result.expectText(containing: "Updated 1")
        #expect(service.updateRequests.last?.startDate == .clear)
    }

    // MARK: - Update Tests (upsert with id)

    @Test("Update single reminder via upsert with id")
    func testUpdateSingleReminder() async throws {
        let service = MockReminderService()
        service.mockReminders = [
            TestFixtures.reminder(id: "rem-1", title: "Original")
        ]

        let result = await writeReminders(
            upsert: [
                [
                    "id": .string("rem-1"),
                    "title": .string("Updated title"),
                    "done": .bool(true)
                ]
            ], service: service)

        result.expectText(containing: "Updated 1")
        let request = try #require(service.updateRequests.last)
        #expect(request.title == "Updated title")
        #expect(request.done == true)
    }

    @Test("Update multiple reminders via upsert")
    func testUpdateMultipleReminders() async throws {
        let service = MockReminderService()
        service.mockReminders = [
            TestFixtures.reminder(id: "rem-1", title: "Task 1"),
            TestFixtures.reminder(id: "rem-2", title: "Task 2")
        ]

        let result = await writeReminders(
            upsert: [
                ["id": .string("rem-1"), "done": .bool(true)],
                ["id": .string("rem-2"), "priority": .string("high")]
            ], service: service)

        result.expectText(containing: "Updated 2")
        #expect(service.updateRequests.map(\.id) == ["rem-1", "rem-2"])
        #expect(service.updateRequests.first?.done == true)
        #expect(service.updateRequests.last?.priority == .high)
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

        let result = await writeReminders(
            upsert: [
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
        let result = await callTool(
            "write_reminders",
            arguments: [
                "upsert": .array([]),
                "delete": .array([])
            ])

        result.expectError(containing: "At least one of 'upsert' or 'delete' required")
    }

    @Test("Invalid date format reports failure")
    func testInvalidDateFormat() async throws {
        let result = await writeReminders(upsert: [
            [
                "title": .string("Task with bad date"),
                "dueDate": .string("next tuesday")
            ]
        ])

        result.expectText(containing: "Failed", "Invalid date")
    }

    @Test("Invalid priority reports failure")
    func testInvalidPriority() async throws {
        let result = await writeReminders(upsert: [
            [
                "title": .string("Task with bad priority"),
                "priority": .string("urgent")
            ]
        ])

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
