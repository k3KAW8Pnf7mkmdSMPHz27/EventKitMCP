import Foundation
import Logging
import Testing

@testable import EventKitMCP
@testable import EventKitService
import MCP

@Suite("Query Reminders Handler Tests")
struct QueryRemindersTests {
    let logger = Logger(label: "test")

    @Test("Structured query preserves time zones and every alarm kind")
    func structuredTimeZonesAndAlarms() async throws {
        let service = MockReminderService()
        service.mockReminders = [ReminderModel(
            id: "zoned",
            title: "Zoned reminder",
            dueDate: TestFixtures.todayNoon,
            dueTimeZone: "America/Chicago",
            listId: "default",
            listName: "Default",
            startDate: TestFixtures.todayNoon,
            startTimeZone: "Europe/Paris",
            alarms: [
                .relative(minutesBefore: 15),
                .absolute(TestFixtures.todayNoon),
                .location(
                    .init(title: "Office", latitude: 41.8781, longitude: -87.6298, radius: 100),
                    proximity: .enter
                )
            ]
        )]

        let result = await queryReminders(service: service)
        result.expectSuccess()
        guard let content = result.structuredContent,
              case .object(let structured) = content,
              case .array(let reminders)? = structured["reminders"],
              case .object(let reminder)? = reminders.first else {
            Issue.record("Expected structured reminder output")
            return
        }
        #expect(reminder["dueTimeZone"]?.stringValue == "America/Chicago")
        #expect(reminder["startTimeZone"]?.stringValue == "Europe/Paris")
        guard case .array(let alarms)? = reminder["alarms"] else {
            Issue.record("Expected structured alarms")
            return
        }
        #expect(Set(alarms.compactMap { $0.objectValue?["kind"]?.stringValue }) == [
            "relative", "absolute", "location"
        ])
    }

    // MARK: - ID-based search queries

    @Test("Search by IDs returns specific reminders")
    func testSearchByIds() async throws {
        let mockService = MockReminderService()
        mockService.mockReminders = [
            ReminderModel(id: "r1", title: "Task 1", notes: nil, done: false, priority: .none, dueDate: nil, listId: "list-1", listName: "Work"),
            ReminderModel(id: "r2", title: "Task 2", notes: nil, done: false, priority: .none, dueDate: nil, listId: "list-1", listName: "Work"),
            ReminderModel(id: "r3", title: "Task 3", notes: nil, done: false, priority: .none, dueDate: nil, listId: "list-1", listName: "Work")
        ]

        // Use regex alternation to search for multiple IDs
        let result = await handleToolCall(
            name: "query_reminders",
            arguments: ["search": .string("^(r1|r3)$")],
            reminderService: mockService,

            logger: logger,
            readOnly: false
        )

        #expect(result.isError == nil || result.isError == false)
        if case .text(let text, _, _) = result.content[0] {
            #expect(text.contains("Found 2 reminder(s)"))
            #expect(text.contains("Task 1"))
            #expect(text.contains("Task 3"))
            #expect(!text.contains("Task 2"))
        } else {
            Issue.record("Expected text content")
        }
    }

    @Test("Search by ID returns single reminder")
    func testSearchBySingleId() async throws {
        let mockService = MockReminderService()
        mockService.mockReminders = [
            ReminderModel(id: "r1", title: "Task 1", notes: nil, done: false, priority: .none, dueDate: nil, listId: "list-1", listName: "Work"),
            ReminderModel(id: "r2", title: "Task 2", notes: nil, done: false, priority: .none, dueDate: nil, listId: "list-1", listName: "Work")
        ]

        let result = await handleToolCall(
            name: "query_reminders",
            arguments: ["search": .string("^r1$")],
            reminderService: mockService,

            logger: logger,
            readOnly: false
        )

        #expect(result.isError == nil || result.isError == false)
        if case .text(let text, _, _) = result.content[0] {
            #expect(text.contains("Found 1 reminder(s)"))
            #expect(text.contains("Task 1"))
            #expect(!text.contains("Task 2"))
        } else {
            Issue.record("Expected text content")
        }
    }

    @Test("Search by nonexistent ID returns no results")
    func testSearchByNonexistentId() async throws {
        let mockService = MockReminderService()
        mockService.mockReminders = [
            ReminderModel(id: "r1", title: "Task 1", notes: nil, done: false, priority: .none, dueDate: nil, listId: "list-1", listName: "Work")
        ]

        let result = await handleToolCall(
            name: "query_reminders",
            arguments: ["search": .string("^nonexistent$")],
            reminderService: mockService,

            logger: logger,
            readOnly: false
        )

        #expect(result.isError == nil || result.isError == false)
        if case .text(let text, _, _) = result.content[0] {
            #expect(text.contains("No reminders found"))
        } else {
            Issue.record("Expected text content")
        }
    }

    // MARK: - Search queries

    @Test("Query by search returns matching reminders")
    func testQueryBySearch() async throws {
        let mockService = MockReminderService()
        mockService.mockReminders = [
            ReminderModel(id: "r1", title: "Buy groceries", notes: nil, done: false, priority: .none, dueDate: nil, listId: "list-1", listName: "Personal"),
            ReminderModel(id: "r2", title: "Call mom", notes: nil, done: false, priority: .none, dueDate: nil, listId: "list-1", listName: "Personal"),
            ReminderModel(id: "r3", title: "Buy milk", notes: nil, done: false, priority: .none, dueDate: nil, listId: "list-1", listName: "Personal")
        ]

        let result = await handleToolCall(
            name: "query_reminders",
            arguments: ["search": .string("Buy")],
            reminderService: mockService,

            logger: logger,
            readOnly: false
        )

        #expect(result.isError == nil || result.isError == false)
        if case .text(let text, _, _) = result.content[0] {
            #expect(text.contains("Found 2 reminder(s)"))
            #expect(text.contains("Buy groceries"))
            #expect(text.contains("Buy milk"))
            #expect(!text.contains("Call mom"))
        } else {
            Issue.record("Expected text content")
        }
    }

    @Test("Query by search with no matches includes hint")
    func testQueryBySearchNoMatches() async throws {
        let mockService = MockReminderService()
        mockService.mockReminders = [
            ReminderModel(id: "r1", title: "Task 1", notes: nil, done: false, priority: .none, dueDate: nil, listId: "list-1", listName: "Work")
        ]

        let result = await handleToolCall(
            name: "query_reminders",
            arguments: ["search": .string("nonexistent")],
            reminderService: mockService,

            logger: logger,
            readOnly: false
        )

        #expect(result.isError == nil || result.isError == false)
        if case .text(let text, _, _) = result.content[0] {
            #expect(text.contains("No reminders found matching 'nonexistent'"))
            #expect(text.contains("includeDone=true"))
        } else {
            Issue.record("Expected text content")
        }
    }

    @Test("Query by search with no matches and includeDone omits hint")
    func testQueryBySearchNoMatchesWithIncludeCompleted() async throws {
        let mockService = MockReminderService()
        mockService.mockReminders = []

        let result = await handleToolCall(
            name: "query_reminders",
            arguments: ["search": .string("nonexistent"), "includeDone": .bool(true)],
            reminderService: mockService,

            logger: logger,
            readOnly: false
        )

        #expect(result.isError == nil || result.isError == false)
        if case .text(let text, _, _) = result.content[0] {
            #expect(text.contains("No reminders found matching 'nonexistent'"))
            #expect(!text.contains("includeDone"))
            #expect(text.contains("broader search term"))
        } else {
            Issue.record("Expected text content")
        }
    }

    // MARK: - Filter queries

    @Test("Query with filter=all returns all reminders")
    func testQueryFilterAll() async throws {
        let mockService = MockReminderService()
        mockService.mockReminders = [
            ReminderModel(id: "r1", title: "Task 1", notes: nil, done: false, priority: .none, dueDate: nil, listId: "list-1", listName: "Work"),
            ReminderModel(id: "r2", title: "Task 2", notes: nil, done: false, priority: .none, dueDate: nil, listId: "list-1", listName: "Work")
        ]

        let result = await handleToolCall(
            name: "query_reminders",
            arguments: ["filter": .string("all")],
            reminderService: mockService,

            logger: logger,
            readOnly: false
        )

        #expect(result.isError == nil || result.isError == false)
        if case .text(let text, _, _) = result.content[0] {
            #expect(text.contains("Task 1"))
            #expect(text.contains("Task 2"))
        } else {
            Issue.record("Expected text content")
        }
    }

    @Test("Query with filter=overdue returns only overdue reminders")
    func testQueryFilterOverdue() async throws {
        let mockService = MockReminderService()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!

        mockService.mockReminders = [
            ReminderModel(id: "r1", title: "Overdue Task", notes: nil, done: false, priority: .none, dueDate: yesterday, listId: "list-1", listName: "Work"),
            ReminderModel(id: "r2", title: "Future Task", notes: nil, done: false, priority: .none, dueDate: tomorrow, listId: "list-1", listName: "Work")
        ]

        let result = await handleToolCall(
            name: "query_reminders",
            arguments: ["filter": .string("overdue")],
            reminderService: mockService,

            logger: logger,
            readOnly: false
        )

        #expect(result.isError == nil || result.isError == false)
        if case .text(let text, _, _) = result.content[0] {
            #expect(text.contains("Overdue Task"))
            #expect(!text.contains("Future Task"))
        } else {
            Issue.record("Expected text content")
        }
    }

    @Test("Query with filter=today returns today's reminders")
    func testQueryFilterToday() async throws {
        let mockService = MockReminderService()
        let todayNoon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!

        mockService.mockReminders = [
            ReminderModel(id: "r1", title: "Today Task", notes: nil, done: false, priority: .none, dueDate: todayNoon, listId: "list-1", listName: "Work"),
            ReminderModel(id: "r2", title: "Tomorrow Task", notes: nil, done: false, priority: .none, dueDate: tomorrow, listId: "list-1", listName: "Work")
        ]

        let result = await handleToolCall(
            name: "query_reminders",
            arguments: ["filter": .string("today")],
            reminderService: mockService,

            logger: logger,
            readOnly: false
        )

        #expect(result.isError == nil || result.isError == false)
        if case .text(let text, _, _) = result.content[0] {
            #expect(text.contains("Today Task"))
            #expect(!text.contains("Tomorrow Task"))
        } else {
            Issue.record("Expected text content")
        }
    }

    @Test("Query with filter=upcoming uses days parameter")
    func testQueryFilterUpcoming() async throws {
        let mockService = MockReminderService()
        let in3Days = Calendar.current.date(byAdding: .day, value: 3, to: Date())!
        let in10Days = Calendar.current.date(byAdding: .day, value: 10, to: Date())!

        mockService.mockReminders = [
            ReminderModel(id: "r1", title: "Soon Task", notes: nil, done: false, priority: .none, dueDate: in3Days, listId: "list-1", listName: "Work"),
            ReminderModel(id: "r2", title: "Later Task", notes: nil, done: false, priority: .none, dueDate: in10Days, listId: "list-1", listName: "Work")
        ]

        let result = await handleToolCall(
            name: "query_reminders",
            arguments: ["filter": .string("upcoming"), "days": .int(5)],
            reminderService: mockService,

            logger: logger,
            readOnly: false
        )

        #expect(result.isError == nil || result.isError == false)
        if case .text(let text, _, _) = result.content[0] {
            #expect(text.contains("Soon Task"))
            #expect(!text.contains("Later Task"))
        } else {
            Issue.record("Expected text content")
        }
    }

    // MARK: - Empty filter result hints

    @Test("Empty overdue filter includes hint")
    func testEmptyOverdueFilterHint() async throws {
        let mockService = MockReminderService()
        mockService.mockReminders = []

        let result = await handleToolCall(
            name: "query_reminders",
            arguments: ["filter": .string("overdue")],
            reminderService: mockService,

            logger: logger,
            readOnly: false
        )

        #expect(result.isError == nil || result.isError == false)
        if case .text(let text, _, _) = result.content[0] {
            #expect(text.contains("No overdue reminders found"))
            #expect(text.contains("filter='today'"))
            #expect(text.contains("filter='upcoming'"))
        } else {
            Issue.record("Expected text content")
        }
    }

    @Test("Empty today filter includes hint")
    func testEmptyTodayFilterHint() async throws {
        let mockService = MockReminderService()
        mockService.mockReminders = []

        let result = await handleToolCall(
            name: "query_reminders",
            arguments: ["filter": .string("today")],
            reminderService: mockService,

            logger: logger,
            readOnly: false
        )

        #expect(result.isError == nil || result.isError == false)
        if case .text(let text, _, _) = result.content[0] {
            #expect(text.contains("No reminders due today"))
            #expect(text.contains("filter='overdue'"))
            #expect(text.contains("filter='upcoming'"))
        } else {
            Issue.record("Expected text content")
        }
    }

    @Test("Empty upcoming filter includes hint with days")
    func testEmptyUpcomingFilterHint() async throws {
        let mockService = MockReminderService()
        mockService.mockReminders = []

        let result = await handleToolCall(
            name: "query_reminders",
            arguments: ["filter": .string("upcoming"), "days": .int(5)],
            reminderService: mockService,

            logger: logger,
            readOnly: false
        )

        #expect(result.isError == nil || result.isError == false)
        if case .text(let text, _, _) = result.content[0] {
            #expect(text.contains("No upcoming reminders in the next 5 days"))
            #expect(text.contains("'days' parameter"))
            #expect(text.contains("filter='all'"))
        } else {
            Issue.record("Expected text content")
        }
    }

    @Test("Empty all filter includes hint about includeDone")
    func testEmptyAllFilterHint() async throws {
        let mockService = MockReminderService()
        mockService.mockReminders = []

        let result = await handleToolCall(
            name: "query_reminders",
            arguments: ["filter": .string("all")],
            reminderService: mockService,

            logger: logger,
            readOnly: false
        )

        #expect(result.isError == nil || result.isError == false)
        if case .text(let text, _, _) = result.content[0] {
            #expect(text.contains("No reminders found"))
            #expect(text.contains("includeDone=true"))
        } else {
            Issue.record("Expected text content")
        }
    }

    @Test("Empty all filter with listId includes hint about removing listId")
    func testEmptyAllFilterWithListIdHint() async throws {
        let mockService = MockReminderService()
        mockService.mockReminders = []

        let result = await handleToolCall(
            name: "query_reminders",
            arguments: ["filter": .string("all"), "listId": .string("some-list")],
            reminderService: mockService,

            logger: logger,
            readOnly: false
        )

        #expect(result.isError == nil || result.isError == false)
        if case .text(let text, _, _) = result.content[0] {
            #expect(text.contains("No reminders found"))
            #expect(text.contains("removing listId"))
        } else {
            Issue.record("Expected text content")
        }
    }

    // MARK: - Composed query tests

    @Test("Search is applied within the selected time filter")
    func testSearchComposesWithFilter() async throws {
        let mockService = MockReminderService()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!

        mockService.mockReminders = [
            ReminderModel(id: "r1", title: "Find overdue", notes: nil, done: false, priority: .none, dueDate: yesterday, listId: "list-1", listName: "Work"),
            ReminderModel(id: "r2", title: "Other overdue", notes: nil, done: false, priority: .none, dueDate: yesterday, listId: "list-1", listName: "Work"),
            ReminderModel(id: "r3", title: "Find unscheduled", notes: nil, done: false, priority: .none, dueDate: nil, listId: "list-1", listName: "Work"),
            ReminderModel(id: "r4", title: "Find personal overdue", notes: nil, done: false, priority: .none, dueDate: yesterday, listId: "list-2", listName: "Personal")
        ]

        // Provide both search and filter
        let result = await handleToolCall(
            name: "query_reminders",
            arguments: [
                "search": .string("Find"),
                "filter": .string("overdue"),
                "listId": .string("list-1")
            ],
            reminderService: mockService,

            logger: logger,
            readOnly: false
        )

        #expect(result.isError == nil || result.isError == false)
        if case .text(let text, _, _) = result.content[0] {
            #expect(text.contains("Found 1 reminder(s)"))
            #expect(text.contains("Find overdue"))
            #expect(!text.contains("Other overdue"))
            #expect(!text.contains("Find unscheduled"))
            #expect(!text.contains("Find personal overdue"))
        } else {
            Issue.record("Expected text content")
        }
    }

    // MARK: - Default behavior

    @Test("No parameters defaults to filter=all")
    func testDefaultBehavior() async throws {
        let mockService = MockReminderService()
        mockService.mockReminders = [
            ReminderModel(id: "r1", title: "Task 1", notes: nil, done: false, priority: .none, dueDate: nil, listId: "list-1", listName: "Work")
        ]

        let result = await handleToolCall(
            name: "query_reminders",
            arguments: nil,
            reminderService: mockService,

            logger: logger,
            readOnly: false
        )

        #expect(result.isError == nil || result.isError == false)
        if case .text(let text, _, _) = result.content[0] {
            #expect(text.contains("Task 1"))
        } else {
            Issue.record("Expected text content")
        }
    }

    // MARK: - Validation errors

    @Test("Invalid filter returns error")
    func testInvalidFilter() async throws {
        let mockService = MockReminderService()

        let result = await handleToolCall(
            name: "query_reminders",
            arguments: ["filter": .string("invalid")],
            reminderService: mockService,

            logger: logger,
            readOnly: false
        )

        #expect(result.isError == true)
        if case .text(let text, _, _) = result.content[0] {
            #expect(text.contains("Invalid filter"))
        } else {
            Issue.record("Expected text content")
        }
    }
}
