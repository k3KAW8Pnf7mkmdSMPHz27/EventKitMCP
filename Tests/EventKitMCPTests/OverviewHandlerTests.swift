import Foundation
import Testing

@testable import EventKitMCP
@testable import EventKitService
import MCP

@MainActor
@Suite("Overview Handler Tests")
struct OverviewHandlerTests {
    @Test("Overview with empty state returns correct structure")
    func testEmptyState() async throws {
        let result = await getOverview()

        #expect(result.content.count == 1)
        result.expectText(containing: "Overview as of", "SUMMARY:", "0 scheduled", "0 overdue", "0 today")
        result.expectTextNot(containing: "LISTS:")
    }

    @Test("Overview shows timezone in header")
    func testTimezoneInHeader() async throws {
        let result = await getOverview()

        // Should contain timezone identifier like "America/Chicago" or "UTC"
        let firstLine = try #require(result.textContent).split(separator: "\n").first ?? ""
        #expect(firstLine.contains("Overview as of"))
        #expect(firstLine.contains("("))
        #expect(firstLine.contains(")"))
    }

    @Test("Overview shows lists with reminder counts")
    func testListsWithCounts() async throws {
        let service = MockReminderService()
        service.mockLists = [
            TestFixtures.workList,
            ReminderListModel(id: "list-2", title: "Personal")
        ]
        service.mockReminders = [
            TestFixtures.reminder(title: "Task 1"),
            TestFixtures.reminder(id: "r2", title: "Task 2"),
            TestFixtures.reminder(id: "r3", title: "Task 3", listId: "list-2", listName: "Personal")
        ]

        let result = await getOverview(service: service)

        result.expectText(containing: "LISTS:", "Work: 2 incomplete", "Personal: 1 incomplete", "3 other unscheduled")
    }

    @Test("Overview hides empty lists")
    func testHidesEmptyLists() async throws {
        let service = MockReminderService()
        service.mockLists = [
            TestFixtures.workList,
            ReminderListModel(id: "list-2", title: "Personal"),
            ReminderListModel(id: "list-3", title: "Empty List")
        ]
        service.mockReminders = [
            TestFixtures.reminder(title: "Task 1")
        ]

        let result = await getOverview(service: service)

        result.expectText(containing: "LISTS:", "Work: 1 incomplete")
        result.expectTextNot(containing: "Personal", "Empty List")
    }

    @Test("Overview categorizes overdue reminders")
    func testOverdueReminders() async throws {
        let service = MockReminderService()
        service.mockLists = [TestFixtures.workList]
        service.mockReminders = [
            TestFixtures.reminder(title: "Overdue Task", priority: .high, dueDate: TestFixtures.yesterday)
        ]

        let result = await getOverview(service: service)

        result.expectText(containing: "OVERDUE:", "Overdue Task (high) in Work", ", due")
    }

    @Test("Overview shows today's reminders")
    func testTodayReminders() async throws {
        let service = MockReminderService()
        service.mockLists = [TestFixtures.workList]
        service.mockReminders = [
            TestFixtures.reminder(title: "Today Task", dueDate: TestFixtures.todayNoon)
        ]

        let result = await getOverview(service: service)

        result.expectText(containing: "TODAY:", "Today Task", "in Work")
    }

    @Test("Overview shows attention section for high priority without due date")
    func testAttentionSection() async throws {
        let service = MockReminderService()
        service.mockLists = [TestFixtures.workList]
        service.mockReminders = [
            TestFixtures.reminder(title: "Urgent No Date", priority: .high),
            TestFixtures.reminder(id: "r2", title: "Medium No Date", priority: .medium)
        ]

        let result = await getOverview(service: service)

        result.expectText(containing: "ATTENTION", "Urgent No Date (high) in Work", "Medium No Date (medium) in Work")
    }

    @Test("Overview shows upcoming reminders grouped by date")
    func testUpcomingReminders() async throws {
        let service = MockReminderService()
        let dayAfter = Calendar.current.date(byAdding: .day, value: 2, to: Date())!

        service.mockLists = [TestFixtures.workList]
        service.mockReminders = [
            TestFixtures.reminder(title: "Tomorrow 1", dueDate: TestFixtures.tomorrow),
            TestFixtures.reminder(id: "r2", title: "Tomorrow 2", dueDate: TestFixtures.tomorrow),
            TestFixtures.reminder(id: "r3", title: "Day After", dueDate: dayAfter)
        ]

        let result = await getOverview(service: service)

        result.expectText(containing: "UPCOMING (7 days):", "2 reminders", "1 reminder")
    }

    @Test("Overview excludes completed reminders")
    func testExcludesCompleted() async throws {
        let service = MockReminderService()
        service.mockLists = [TestFixtures.workList]
        service.mockReminders = [
            TestFixtures.reminder(title: "Pending"),
            TestFixtures.reminder(id: "r2", title: "Done", done: true)
        ]

        let result = await getOverview(service: service)

        #expect(service.getRemindersCalled)
        #expect(service.lastGetRemindersIncludeDone == false)
        result.expectText(containing: "1 other unscheduled")
    }

    @Test("Overview shows per-list stats for overdue and priority")
    func testListStats() async throws {
        let service = MockReminderService()
        service.mockLists = [TestFixtures.workList]
        service.mockReminders = [
            TestFixtures.reminder(title: "Overdue High", priority: .high, dueDate: TestFixtures.yesterday),
            TestFixtures.reminder(
                id: "r2", title: "Overdue Medium", priority: .medium, dueDate: TestFixtures.yesterday),
            TestFixtures.reminder(id: "r3", title: "Undated High", priority: .high)
        ]

        let result = await getOverview(service: service)

        result.expectText(containing: "Work: 3 incomplete, 2 overdue, 2 high, 1 medium")
    }

    @Test("Overview orders overdue by priority and today by time")
    func sectionOrdering() async throws {
        let now = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 6, day: 10, hour: 12)))
        let startOfToday = Calendar.current.startOfDay(for: now)
        func at(day: Int, hour: Int) -> Date {
            Calendar.current.date(byAdding: DateComponents(day: day, hour: hour), to: startOfToday)!
        }
        let service = MockReminderService()
        service.mockLists = [TestFixtures.workList]
        service.mockReminders = [
            TestFixtures.reminder(id: "t2", title: "Afternoon call", dueDate: at(day: 0, hour: 14)),
            TestFixtures.reminder(id: "t1", title: "Morning standup", dueDate: at(day: 0, hour: 9)),
            TestFixtures.reminder(id: "o1", title: "Old low", priority: .low, dueDate: at(day: -5, hour: 9)),
            TestFixtures.reminder(id: "o2", title: "Recent high", priority: .high, dueDate: at(day: -1, hour: 9))
        ]

        let text = try #require(await getOverview(service: service, now: now).textContent)

        let lines = text.split(separator: "\n")
        let positions = ["Recent high", "Old low", "Morning standup", "Afternoon call"].compactMap { title in
            lines.firstIndex { $0.hasPrefix("- \(title) ") }
        }
        #expect(positions.count == 4, "\(text)")
        #expect(positions == positions.sorted(), "\(text)")
    }

    @Test("Overview truncates overdue section when more than 10 items")
    func testOverdueTruncation() async throws {
        let service = MockReminderService()
        service.mockLists = [TestFixtures.workList]
        service.mockReminders = (1...15).map { i in
            TestFixtures.reminder(id: "r\(i)", title: "Overdue Task \(i)", dueDate: TestFixtures.yesterday)
        }

        let result = await getOverview(service: service)

        result.expectText(containing: "OVERDUE:", "Overdue Task 1", "Overdue Task 10", "... and 5 more overdue")
        result.expectTextNot(containing: "Overdue Task 11")
    }
}
