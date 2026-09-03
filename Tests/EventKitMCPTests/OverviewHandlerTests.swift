import Foundation
import Logging
import Testing

@testable import EventKitMCP
@testable import EventKitService
import MCP

@Suite("Overview Handler Tests")
struct OverviewHandlerTests {
    let logger = Logger(label: "test")

    @Test("Overview with empty state returns correct structure")
    func testEmptyState() async throws {
        let mockService = MockReminderService()

        let result = await handleToolCall(
            name: "overview",
            arguments: nil,
            reminderService: mockService,

            logger: logger,
            readOnly: false
        )

        #expect(result.isError == nil || result.isError == false)
        #expect(result.content.count == 1)

        if case .text(let text, _, _) = result.content[0] {
            #expect(text.contains("Overview as of"))
            #expect(text.contains("SUMMARY:"))
            #expect(text.contains("0 scheduled"))
            #expect(text.contains("0 overdue"))
            #expect(text.contains("0 today"))
            // LISTS section is hidden when empty
            #expect(!text.contains("LISTS:"))
        } else {
            Issue.record("Expected text content")
        }
    }

    @Test("Overview shows timezone in header")
    func testTimezoneInHeader() async throws {
        let mockService = MockReminderService()

        let result = await handleToolCall(
            name: "overview",
            arguments: nil,
            reminderService: mockService,

            logger: logger,
            readOnly: false
        )

        if case .text(let text, _, _) = result.content[0] {
            // Should contain timezone identifier like "America/Chicago" or "UTC"
            let firstLine = text.components(separatedBy: "\n").first ?? ""
            #expect(firstLine.contains("Overview as of"))
            #expect(firstLine.contains("("))
            #expect(firstLine.contains(")"))
        } else {
            Issue.record("Expected text content")
        }
    }

    @Test("Overview shows lists with reminder counts")
    func testListsWithCounts() async throws {
        let mockService = MockReminderService()
        mockService.mockLists = [
            ReminderListModel(id: "list-1", title: "Work", color: nil, isSubscribed: false, isImmutable: false, sourceTitle: nil),
            ReminderListModel(id: "list-2", title: "Personal", color: nil, isSubscribed: false, isImmutable: false, sourceTitle: nil)
        ]
        mockService.mockReminders = [
            ReminderModel(id: "r1", title: "Task 1", notes: nil, done: false, priority: .none, dueDate: nil, listId: "list-1", listName: "Work"),
            ReminderModel(id: "r2", title: "Task 2", notes: nil, done: false, priority: .none, dueDate: nil, listId: "list-1", listName: "Work"),
            ReminderModel(id: "r3", title: "Task 3", notes: nil, done: false, priority: .none, dueDate: nil, listId: "list-2", listName: "Personal")
        ]

        let result = await handleToolCall(
            name: "overview",
            arguments: nil,
            reminderService: mockService,

            logger: logger,
            readOnly: false
        )

        if case .text(let text, _, _) = result.content[0] {
            #expect(text.contains("LISTS:"))
            #expect(text.contains("Work: 2 incomplete"))
            #expect(text.contains("Personal: 1 incomplete"))
            #expect(text.contains("3 other unscheduled"))
        } else {
            Issue.record("Expected text content")
        }
    }

    @Test("Overview hides empty lists")
    func testHidesEmptyLists() async throws {
        let mockService = MockReminderService()
        mockService.mockLists = [
            ReminderListModel(id: "list-1", title: "Work", color: nil, isSubscribed: false, isImmutable: false, sourceTitle: nil),
            ReminderListModel(id: "list-2", title: "Personal", color: nil, isSubscribed: false, isImmutable: false, sourceTitle: nil),
            ReminderListModel(id: "list-3", title: "Empty List", color: nil, isSubscribed: false, isImmutable: false, sourceTitle: nil)
        ]
        mockService.mockReminders = [
            ReminderModel(id: "r1", title: "Task 1", notes: nil, done: false, priority: .none, dueDate: nil, listId: "list-1", listName: "Work")
        ]

        let result = await handleToolCall(
            name: "overview",
            arguments: nil,
            reminderService: mockService,

            logger: logger,
            readOnly: false
        )

        if case .text(let text, _, _) = result.content[0] {
            #expect(text.contains("LISTS:"))
            #expect(text.contains("Work: 1 incomplete"))
            #expect(!text.contains("Personal"))
            #expect(!text.contains("Empty List"))
        } else {
            Issue.record("Expected text content")
        }
    }

    @Test("Overview categorizes overdue reminders")
    func testOverdueReminders() async throws {
        let mockService = MockReminderService()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!

        mockService.mockLists = [
            ReminderListModel(id: "list-1", title: "Work", color: nil, isSubscribed: false, isImmutable: false, sourceTitle: nil)
        ]
        mockService.mockReminders = [
            ReminderModel(id: "r1", title: "Overdue Task", notes: nil, done: false, priority: .high, dueDate: yesterday, listId: "list-1", listName: "Work")
        ]

        let result = await handleToolCall(
            name: "overview",
            arguments: nil,
            reminderService: mockService,

            logger: logger,
            readOnly: false
        )

        if case .text(let text, _, _) = result.content[0] {
            #expect(text.contains("OVERDUE:"))
            #expect(text.contains("Overdue Task (high) in Work"))
            #expect(text.contains(", due"))
        } else {
            Issue.record("Expected text content")
        }
    }

    @Test("Overview shows today's reminders")
    func testTodayReminders() async throws {
        let mockService = MockReminderService()
        let todayNoon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!

        mockService.mockLists = [
            ReminderListModel(id: "list-1", title: "Work", color: nil, isSubscribed: false, isImmutable: false, sourceTitle: nil)
        ]
        mockService.mockReminders = [
            ReminderModel(id: "r1", title: "Today Task", notes: nil, done: false, priority: .none, dueDate: todayNoon, listId: "list-1", listName: "Work")
        ]

        let result = await handleToolCall(
            name: "overview",
            arguments: nil,
            reminderService: mockService,

            logger: logger,
            readOnly: false
        )

        if case .text(let text, _, _) = result.content[0] {
            #expect(text.contains("TODAY:"))
            #expect(text.contains("Today Task"))
            #expect(text.contains("in Work"))
        } else {
            Issue.record("Expected text content")
        }
    }

    @Test("Overview shows attention section for high priority without due date")
    func testAttentionSection() async throws {
        let mockService = MockReminderService()

        mockService.mockLists = [
            ReminderListModel(id: "list-1", title: "Work", color: nil, isSubscribed: false, isImmutable: false, sourceTitle: nil)
        ]
        mockService.mockReminders = [
            ReminderModel(id: "r1", title: "Urgent No Date", notes: nil, done: false, priority: .high, dueDate: nil, listId: "list-1", listName: "Work"),
            ReminderModel(id: "r2", title: "Medium No Date", notes: nil, done: false, priority: .medium, dueDate: nil, listId: "list-1", listName: "Work")
        ]

        let result = await handleToolCall(
            name: "overview",
            arguments: nil,
            reminderService: mockService,

            logger: logger,
            readOnly: false
        )

        if case .text(let text, _, _) = result.content[0] {
            #expect(text.contains("ATTENTION"))
            #expect(text.contains("Urgent No Date (high) in Work"))
            #expect(text.contains("Medium No Date (medium) in Work"))
        } else {
            Issue.record("Expected text content")
        }
    }

    @Test("Overview shows upcoming reminders grouped by date")
    func testUpcomingReminders() async throws {
        let mockService = MockReminderService()
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        let dayAfter = Calendar.current.date(byAdding: .day, value: 2, to: Date())!

        mockService.mockLists = [
            ReminderListModel(id: "list-1", title: "Work", color: nil, isSubscribed: false, isImmutable: false, sourceTitle: nil)
        ]
        mockService.mockReminders = [
            ReminderModel(id: "r1", title: "Tomorrow 1", notes: nil, done: false, priority: .none, dueDate: tomorrow, listId: "list-1", listName: "Work"),
            ReminderModel(id: "r2", title: "Tomorrow 2", notes: nil, done: false, priority: .none, dueDate: tomorrow, listId: "list-1", listName: "Work"),
            ReminderModel(id: "r3", title: "Day After", notes: nil, done: false, priority: .none, dueDate: dayAfter, listId: "list-1", listName: "Work")
        ]

        let result = await handleToolCall(
            name: "overview",
            arguments: nil,
            reminderService: mockService,

            logger: logger,
            readOnly: false
        )

        if case .text(let text, _, _) = result.content[0] {
            #expect(text.contains("UPCOMING (7 days):"))
            #expect(text.contains("2 reminders"))
            #expect(text.contains("1 reminder"))
        } else {
            Issue.record("Expected text content")
        }
    }

    @Test("Overview excludes completed reminders")
    func testExcludesCompleted() async throws {
        let mockService = MockReminderService()

        mockService.mockLists = [
            ReminderListModel(id: "list-1", title: "Work", color: nil, isSubscribed: false, isImmutable: false, sourceTitle: nil)
        ]
        mockService.mockReminders = [
            ReminderModel(id: "r1", title: "Pending", notes: nil, done: false, priority: .none, dueDate: nil, listId: "list-1", listName: "Work"),
            ReminderModel(id: "r2", title: "Done", notes: nil, done: true, priority: .none, dueDate: nil, listId: "list-1", listName: "Work")
        ]

        let result = await handleToolCall(
            name: "overview",
            arguments: nil,
            reminderService: mockService,

            logger: logger,
            readOnly: false
        )

        #expect(mockService.getRemindersCalled)
        #expect(mockService.lastGetRemindersIncludeDone == false)

        if case .text(let text, _, _) = result.content[0] {
            #expect(text.contains("1 other unscheduled"))
        } else {
            Issue.record("Expected text content")
        }
    }

    @Test("Overview shows per-list stats for overdue and priority")
    func testListStats() async throws {
        let mockService = MockReminderService()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!

        mockService.mockLists = [
            ReminderListModel(id: "list-1", title: "Work", color: nil, isSubscribed: false, isImmutable: false, sourceTitle: nil)
        ]
        mockService.mockReminders = [
            ReminderModel(id: "r1", title: "Overdue High", notes: nil, done: false, priority: .high, dueDate: yesterday, listId: "list-1", listName: "Work"),
            ReminderModel(id: "r2", title: "Overdue Medium", notes: nil, done: false, priority: .medium, dueDate: yesterday, listId: "list-1", listName: "Work"),
            ReminderModel(id: "r3", title: "Normal Task", notes: nil, done: false, priority: .none, dueDate: nil, listId: "list-1", listName: "Work")
        ]

        let result = await handleToolCall(
            name: "overview",
            arguments: nil,
            reminderService: mockService,

            logger: logger,
            readOnly: false
        )

        if case .text(let text, _, _) = result.content[0] {
            #expect(text.contains("Work: 3 incomplete, 2 overdue, 1 high, 1 medium"))
        } else {
            Issue.record("Expected text content")
        }
    }

    @Test("Overview truncates overdue section when more than 10 items")
    func testOverdueTruncation() async throws {
        let mockService = MockReminderService()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!

        mockService.mockLists = [
            ReminderListModel(id: "list-1", title: "Work", color: nil, isSubscribed: false, isImmutable: false, sourceTitle: nil)
        ]
        // Create 15 overdue reminders
        mockService.mockReminders = (1...15).map { i in
            ReminderModel(id: "r\(i)", title: "Overdue Task \(i)", notes: nil, done: false, priority: .none, dueDate: yesterday, listId: "list-1", listName: "Work")
        }

        let result = await handleToolCall(
            name: "overview",
            arguments: nil,
            reminderService: mockService,

            logger: logger,
            readOnly: false
        )

        if case .text(let text, _, _) = result.content[0] {
            #expect(text.contains("OVERDUE:"))
            #expect(text.contains("Overdue Task 1"))
            #expect(text.contains("Overdue Task 10"))
            #expect(!text.contains("Overdue Task 11"))
            #expect(text.contains("... and 5 more overdue"))
        } else {
            Issue.record("Expected text content")
        }
    }
}
