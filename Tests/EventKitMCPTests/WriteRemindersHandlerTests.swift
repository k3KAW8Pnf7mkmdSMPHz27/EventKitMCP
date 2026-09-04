import Foundation
import Logging
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

        let result = await callTool("write_reminders", arguments: [
            "upsert": .array([.object([
                "id": .string("preserve"),
                "title": .string("Updated")
            ])])
        ], reminderService: service)

        result.expectSuccess()
        #expect(service.mockReminders[0].alarms == alarms)
        #expect(service.mockReminders[0].dueTimeZone == "America/Chicago")
        #expect(service.mockReminders[0].startTimeZone == "Europe/Paris")
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

        let result = await callTool("write_reminders", arguments: [
            "upsert": .array([.object([
                "id": .string("clear-me"),
                "notes": .null,
                "dueDate": .null,
                "location": .null,
                "url": .null,
                "startDate": .null,
                "recurrence": .null,
                "alarms": .null
            ])])
        ], reminderService: service)

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
        let mockService = MockReminderService()

        let result = await callTool(
            "write_reminders",
            arguments: [
                "upsert": .array([
                    .object([
                        "title": .string("Buy groceries"),
                        "notes": .string("Milk, eggs, bread"),
                        "priority": .string("medium")
                    ])
                ])
            ],
            reminderService: mockService
        )

        result.expectSuccess()
        result.expectText(containing: "Created 1")
        result.expectText(containing: "Buy groceries")
        result.expectText(containing: "Milk, eggs, bread")
    }

    @Test("Create multiple reminders via upsert")
    func testCreateMultipleReminders() async throws {
        let mockService = MockReminderService()

        let result = await callTool(
            "write_reminders",
            arguments: [
                "upsert": .array([
                    .object(["title": .string("Task 1")]),
                    .object(["title": .string("Task 2")]),
                    .object(["title": .string("Task 3")])
                ])
            ],
            reminderService: mockService
        )

        result.expectSuccess()
        result.expectText(containing: "Created 3")
    }

    @Test("Create with missing title reports failure")
    func testCreateMissingTitle() async throws {
        let mockService = MockReminderService()

        let result = await callTool(
            "write_reminders",
            arguments: [
                "upsert": .array([
                    .object(["notes": .string("No title here")])
                ])
            ],
            reminderService: mockService
        )

        result.expectSuccess()
        result.expectText(containing: "Failed")
        result.expectText(containing: "upsert[0]")
        result.expectText(containing: "Missing title")
    }

    @Test("Create reminder with URL")
    func testCreateWithURL() async throws {
        let mockService = MockReminderService()

        let result = await callTool(
            "write_reminders",
            arguments: [
                "upsert": .array([
                    .object([
                        "title": .string("Check docs"),
                        "url": .string("https://example.com/docs")
                    ])
                ])
            ],
            reminderService: mockService
        )

        result.expectSuccess()
        result.expectText(containing: "Created 1")
        result.expectText(containing: "URL: https://example.com/docs")
    }

    @Test("Update reminder with URL")
    func testUpdateWithURL() async throws {
        let mockService = MockReminderService()
        mockService.mockReminders = [
            TestFixtures.reminder(id: "rem-1", title: "Check docs")
        ]

        let result = await callTool(
            "write_reminders",
            arguments: [
                "upsert": .array([
                    .object([
                        "id": .string("rem-1"),
                        "url": .string("https://example.com/updated")
                    ])
                ])
            ],
            reminderService: mockService
        )

        result.expectSuccess()
        result.expectText(containing: "Updated 1")
        result.expectText(containing: "URL: https://example.com/updated")
    }

    @Test("Create reminder with location")
    func testCreateWithLocation() async throws {
        let mockService = MockReminderService()

        let result = await callTool(
            "write_reminders",
            arguments: [
                "upsert": .array([
                    .object([
                        "title": .string("Meeting"),
                        "location": .string("Conference Room B")
                    ])
                ])
            ],
            reminderService: mockService
        )

        result.expectSuccess()
        result.expectText(containing: "Created 1")
        result.expectText(containing: "Location: Conference Room B")
    }

    @Test("Update reminder with location")
    func testUpdateWithLocation() async throws {
        let mockService = MockReminderService()
        mockService.mockReminders = [
            TestFixtures.reminder(id: "rem-1", title: "Meeting")
        ]

        let result = await callTool(
            "write_reminders",
            arguments: [
                "upsert": .array([
                    .object([
                        "id": .string("rem-1"),
                        "location": .string("Room 42")
                    ])
                ])
            ],
            reminderService: mockService
        )

        result.expectSuccess()
        result.expectText(containing: "Updated 1")
        result.expectText(containing: "Location: Room 42")
    }

    @Test("Create reminder with alarms")
    func testCreateWithAlarms() async throws {
        let mockService = MockReminderService()

        let result = await callTool(
            "write_reminders",
            arguments: [
                "upsert": .array([
                    .object([
                        "title": .string("Meeting"),
                        "dueDate": .string("2026-06-01T10:00:00"),
                        "startDate": .string("2026-06-01T10:00:00"),
                        "alarms": .array([0, 15, 60].map { minutes in
                            .object([
                                "kind": .string("relative"),
                                "minutesBefore": .int(minutes)
                            ])
                        })
                    ])
                ])
            ],
            reminderService: mockService
        )

        result.expectSuccess()
        result.expectText(containing: "Created 1")
        result.expectText(containing: "Alarms:")
        result.expectText(containing: "at start")
        result.expectText(containing: "15 min before start")
        result.expectText(containing: "60 min before start")
    }

    @Test("Update reminder alarms")
    func testUpdateAlarms() async throws {
        let mockService = MockReminderService()
        mockService.mockReminders = [
            TestFixtures.reminder(
                id: "rem-1",
                title: "Meeting",
                startDate: TestFixtures.todayNoon,
                alarms: [15]
            )
        ]

        let result = await callTool(
            "write_reminders",
            arguments: [
                "upsert": .array([
                    .object([
                        "id": .string("rem-1"),
                        "alarms": .array([.object([
                            "kind": .string("relative"),
                            "minutesBefore": .int(30)
                        ])])
                    ])
                ])
            ],
            reminderService: mockService
        )

        result.expectSuccess()
        result.expectText(containing: "Updated 1")
        result.expectText(containing: "30 min before")
    }

    @Test("Remove alarms with null")
    func testRemoveAlarms() async throws {
        let mockService = MockReminderService()
        mockService.mockReminders = [
            TestFixtures.reminder(id: "rem-1", title: "Meeting", alarms: [15, 60])
        ]

        let result = await callTool(
            "write_reminders",
            arguments: [
                "upsert": .array([
                    .object([
                        "id": .string("rem-1"),
                        "alarms": .null
                    ])
                ])
            ],
            reminderService: mockService
        )

        result.expectSuccess()
        result.expectText(containing: "Updated 1")
        result.expectTextNot(containing: "Alarms:")
    }

    @Test("Create reminder with start date")
    func testCreateWithStartDate() async throws {
        let mockService = MockReminderService()

        let result = await callTool(
            "write_reminders",
            arguments: [
                "upsert": .array([
                    .object([
                        "title": .string("Project kickoff"),
                        "startDate": .string("2026-06-01T09:00:00"),
                        "dueDate": .string("2026-06-15T17:00:00")
                    ])
                ])
            ],
            reminderService: mockService
        )

        result.expectSuccess()
        result.expectText(containing: "Created 1")
        result.expectText(containing: "Start:")
        result.expectText(containing: "Due:")
    }

    @Test("Create reminder with all-day start date")
    func testCreateWithAllDayStartDate() async throws {
        let mockService = MockReminderService()

        let result = await callTool(
            "write_reminders",
            arguments: [
                "upsert": .array([
                    .object([
                        "title": .string("Vacation"),
                        "startDate": .string("2026-07-01")
                    ])
                ])
            ],
            reminderService: mockService
        )

        result.expectSuccess()
        result.expectText(containing: "Created 1")
        result.expectText(containing: "Start:")
    }

    @Test("Remove start date with null")
    func testRemoveStartDate() async throws {
        let mockService = MockReminderService()
        mockService.mockReminders = [
            TestFixtures.reminder(id: "rem-1", title: "Task", startDate: TestFixtures.tomorrow)
        ]

        let result = await callTool(
            "write_reminders",
            arguments: [
                "upsert": .array([
                    .object([
                        "id": .string("rem-1"),
                        "startDate": .null
                    ])
                ])
            ],
            reminderService: mockService
        )

        result.expectSuccess()
        result.expectText(containing: "Updated 1")
        result.expectTextNot(containing: "Start:")
    }

    // MARK: - Update Tests (upsert with id)

    @Test("Update single reminder via upsert with id")
    func testUpdateSingleReminder() async throws {
        let mockService = MockReminderService()
        mockService.mockReminders = [
            ReminderModel(id: "rem-1", title: "Original", notes: nil, done: false, priority: .none, dueDate: nil, listId: "list-1", listName: "Work")
        ]

        let result = await callTool(
            "write_reminders",
            arguments: [
                "upsert": .array([
                    .object([
                        "id": .string("rem-1"),
                        "title": .string("Updated title"),
                        "done": .bool(true)
                    ])
                ])
            ],
            reminderService: mockService
        )

        result.expectSuccess()
        result.expectText(containing: "Updated 1")
        result.expectText(containing: "Updated title")
    }

    @Test("Update multiple reminders via upsert")
    func testUpdateMultipleReminders() async throws {
        let mockService = MockReminderService()
        mockService.mockReminders = [
            ReminderModel(id: "rem-1", title: "Task 1", notes: nil, done: false, priority: .none, dueDate: nil, listId: "list-1", listName: "Work"),
            ReminderModel(id: "rem-2", title: "Task 2", notes: nil, done: false, priority: .none, dueDate: nil, listId: "list-1", listName: "Work")
        ]

        let result = await callTool(
            "write_reminders",
            arguments: [
                "upsert": .array([
                    .object(["id": .string("rem-1"), "done": .bool(true)]),
                    .object(["id": .string("rem-2"), "priority": .string("high")])
                ])
            ],
            reminderService: mockService
        )

        result.expectSuccess()
        result.expectText(containing: "Updated 2")
    }

    // MARK: - Delete Tests

    @Test("Delete single reminder returns full details")
    func testDeleteSingleReminder() async throws {
        let mockService = MockReminderService()
        mockService.mockReminders = [
            ReminderModel(id: "rem-1", title: "To delete", notes: "Some notes", done: false, priority: .high, dueDate: nil, listId: "list-1", listName: "Work")
        ]

        let result = await callTool(
            "write_reminders",
            arguments: [
                "delete": .array([.string("rem-1")])
            ],
            reminderService: mockService
        )

        result.expectSuccess()
        result.expectText(containing: "Deleted 1 of 1")
        // Verify full reminder details are returned
        result.expectText(containing: "To delete")
        result.expectText(containing: "ID: rem-1")
        result.expectText(containing: "List: Work")
        result.expectText(containing: "Notes: Some notes")
        result.expectText(containing: "Priority: High")
    }

    @Test("Delete multiple reminders returns full details")
    func testDeleteMultipleReminders() async throws {
        let mockService = MockReminderService()
        mockService.mockReminders = [
            ReminderModel(id: "rem-1", title: "Task 1", notes: nil, done: false, priority: .none, dueDate: nil, listId: "list-1", listName: "Work"),
            ReminderModel(id: "rem-2", title: "Task 2", notes: nil, done: false, priority: .medium, dueDate: nil, listId: "list-1", listName: "Work")
        ]

        let result = await callTool(
            "write_reminders",
            arguments: [
                "delete": .array([.string("rem-1"), .string("rem-2")])
            ],
            reminderService: mockService
        )

        result.expectSuccess()
        result.expectText(containing: "Deleted 2 of 2")
        // Verify full reminder details are returned for both
        result.expectText(containing: "Task 1")
        result.expectText(containing: "Task 2")
        result.expectText(containing: "ID: rem-1")
        result.expectText(containing: "ID: rem-2")
    }

    // MARK: - Mixed Operations Tests

    @Test("Mixed create and update in single call")
    func testMixedCreateAndUpdate() async throws {
        let mockService = MockReminderService()
        mockService.mockReminders = [
            ReminderModel(id: "existing-1", title: "Existing task", notes: nil, done: false, priority: .none, dueDate: nil, listId: "list-1", listName: "Work")
        ]

        let result = await callTool(
            "write_reminders",
            arguments: [
                "upsert": .array([
                    .object(["title": .string("New task")]),  // create (no id)
                    .object(["id": .string("existing-1"), "done": .bool(true)])  // update (has id)
                ])
            ],
            reminderService: mockService
        )

        result.expectSuccess()
        result.expectText(containing: "Created 1")
        result.expectText(containing: "Updated 1")
    }

    @Test("Mixed delete and upsert in single call")
    func testMixedDeleteAndUpsert() async throws {
        let mockService = MockReminderService()
        mockService.mockReminders = [
            ReminderModel(id: "to-delete", title: "Old task", notes: nil, done: false, priority: .none, dueDate: nil, listId: "list-1", listName: "Work")
        ]

        let result = await callTool(
            "write_reminders",
            arguments: [
                "delete": .array([.string("to-delete")]),
                "upsert": .array([
                    .object(["title": .string("Replacement task")])
                ])
            ],
            reminderService: mockService
        )

        result.expectSuccess()
        result.expectText(containing: "Deleted 1 of 1")
        result.expectText(containing: "Created 1")
        result.expectText(containing: "Replacement task")
    }

    // MARK: - Validation Tests

    @Test("Empty input returns error")
    func testEmptyInput() async throws {
        let result = await callTool(
            "write_reminders",
            arguments: [:]
        )

        result.expectError(containing: "At least one of 'upsert' or 'delete' required")
    }

    @Test("Empty arrays returns error")
    func testEmptyArrays() async throws {
        let result = await callTool(
            "write_reminders",
            arguments: [
                "upsert": .array([]),
                "delete": .array([])
            ]
        )

        result.expectError(containing: "At least one of 'upsert' or 'delete' required")
    }

    @Test("Invalid date format reports failure")
    func testInvalidDateFormat() async throws {
        let mockService = MockReminderService()

        let result = await callTool(
            "write_reminders",
            arguments: [
                "upsert": .array([
                    .object([
                        "title": .string("Task with bad date"),
                        "dueDate": .string("next tuesday")
                    ])
                ])
            ],
            reminderService: mockService
        )

        result.expectSuccess()
        result.expectText(containing: "Failed")
        result.expectText(containing: "Invalid date")
    }

    @Test("Invalid priority reports failure")
    func testInvalidPriority() async throws {
        let mockService = MockReminderService()

        let result = await callTool(
            "write_reminders",
            arguments: [
                "upsert": .array([
                    .object([
                        "title": .string("Task with bad priority"),
                        "priority": .string("urgent")
                    ])
                ])
            ],
            reminderService: mockService
        )

        result.expectSuccess()
        result.expectText(containing: "Failed")
        result.expectText(containing: "Invalid priority")
    }

    // MARK: - Partial Failure Tests

    @Test("Partial failure in upsert reports successes and failures")
    func testPartialFailureUpsert() async throws {
        let mockService = MockReminderService()

        let result = await callTool(
            "write_reminders",
            arguments: [
                "upsert": .array([
                    .object(["title": .string("Valid task 1")]),
                    .object(["notes": .string("Missing title")]),  // will fail
                    .object(["title": .string("Valid task 2")])
                ])
            ],
            reminderService: mockService
        )

        result.expectSuccess()
        result.expectText(containing: "Created 2")
        result.expectText(containing: "Failed")
        result.expectText(containing: "upsert[1]")
        result.expectText(containing: "Missing title")
    }

    // MARK: - Read-Only Mode Tests

    @Test("Write blocked in read-only mode")
    func testReadOnlyMode() async throws {
        let result = await callTool(
            "write_reminders",
            arguments: [
                "upsert": .array([
                    .object(["title": .string("Should not create")])
                ])
            ],
            readOnly: true
        )

        result.expectError(containing: "not allowed in read-only mode")
    }
}
