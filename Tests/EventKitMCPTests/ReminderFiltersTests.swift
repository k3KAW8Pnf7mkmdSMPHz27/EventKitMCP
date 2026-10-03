import Foundation
import Testing

@testable import EventKitMCP
@testable import EventKitService

@Suite("Reminder filter tests")
struct ReminderFiltersTests {
    /// Noon on a fixed mid-June day, clear of daylight-saving transitions.
    private let now = Calendar.current.date(from: DateComponents(year: 2026, month: 6, day: 10, hour: 12))!

    private func at(day: Int, hour: Int, minute: Int = 0) -> Date {
        let startOfToday = Calendar.current.startOfDay(for: now)
        return Calendar.current.date(byAdding: DateComponents(day: day, hour: hour, minute: minute), to: startOfToday)!
    }

    private func ids(_ reminders: [ReminderModel]) -> [String] {
        reminders.map(\.id)
    }

    @Test("Overdue keeps reminders due before today, high priority first, then most overdue")
    func overdue() {
        let reminders = [
            TestFixtures.reminder(id: "low", priority: .low, dueDate: at(day: -3, hour: 9)),
            TestFixtures.reminder(id: "high-recent", priority: .high, dueDate: at(day: -1, hour: 9)),
            TestFixtures.reminder(id: "high-older", priority: .high, dueDate: at(day: -2, hour: 9)),
            TestFixtures.reminder(id: "medium-late", priority: .medium, dueDate: at(day: -1, hour: 23, minute: 59)),
            TestFixtures.reminder(id: "none-oldest", dueDate: at(day: -5, hour: 9)),
            TestFixtures.reminder(id: "due-at-midnight", priority: .high, dueDate: at(day: 0, hour: 0)),
            TestFixtures.reminder(id: "undated", priority: .high)
        ]

        #expect(
            ids(ReminderFilters.overdue(reminders, before: now)) == [
                "high-older", "high-recent", "medium-late", "low", "none-oldest"
            ])
    }

    @Test("Today runs from midnight up to the next midnight, earliest first")
    func today() {
        let reminders = [
            TestFixtures.reminder(id: "afternoon", dueDate: at(day: 0, hour: 14)),
            TestFixtures.reminder(id: "yesterday-late", dueDate: at(day: -1, hour: 23, minute: 59)),
            TestFixtures.reminder(id: "morning", dueDate: at(day: 0, hour: 9)),
            TestFixtures.reminder(id: "tomorrow-midnight", dueDate: at(day: 1, hour: 0)),
            TestFixtures.reminder(id: "midnight", dueDate: at(day: 0, hour: 0)),
            TestFixtures.reminder(id: "undated")
        ]

        #expect(ids(ReminderFilters.today(reminders, relativeTo: now)) == ["midnight", "morning", "afternoon"])
    }

    @Test("Upcoming starts tomorrow and includes the whole final day, earliest first")
    func upcoming() {
        let reminders = [
            TestFixtures.reminder(id: "final-day", dueDate: at(day: 7, hour: 23)),
            TestFixtures.reminder(id: "today-late", dueDate: at(day: 0, hour: 23)),
            TestFixtures.reminder(id: "tomorrow", dueDate: at(day: 1, hour: 0)),
            TestFixtures.reminder(id: "past-window", dueDate: at(day: 8, hour: 0)),
            TestFixtures.reminder(id: "mid-window", dueDate: at(day: 4, hour: 12)),
            TestFixtures.reminder(id: "undated")
        ]

        #expect(
            ids(ReminderFilters.upcoming(reminders, days: 7, from: now)) == ["tomorrow", "mid-window", "final-day"])
        #expect(ids(ReminderFilters.upcoming(reminders, days: 1, from: now)) == ["tomorrow"])
    }

    @Test("Needs attention is undated high or medium priority")
    func needsAttention() {
        let reminders = [
            TestFixtures.reminder(id: "high", priority: .high),
            TestFixtures.reminder(id: "medium", priority: .medium),
            TestFixtures.reminder(id: "low", priority: .low),
            TestFixtures.reminder(id: "none"),
            TestFixtures.reminder(id: "dated-high", priority: .high, dueDate: at(day: 1, hour: 9))
        ]

        #expect(ids(ReminderFilters.needsAttention(reminders)) == ["high", "medium"])
    }

    @Test("Search matches ID, title and notes case-insensitively, and nothing else")
    func matching() throws {
        let reminders = [
            TestFixtures.reminder(id: "by-id-PROJECT", title: "First"),
            TestFixtures.reminder(id: "r2", title: "Project kickoff"),
            TestFixtures.reminder(id: "r3", title: "Third", notes: "see the project plan"),
            TestFixtures.reminder(id: "r4", title: "Fourth", listName: "Project")
        ]

        #expect(try ids(ReminderFilters.matching(reminders, pattern: "project")) == ["by-id-PROJECT", "r2", "r3"])
        #expect(try ids(ReminderFilters.matching(reminders, pattern: "^r[23]$")) == ["r2", "r3"])

        let error = #expect(throws: ParseError.self) {
            try ReminderFilters.matching(reminders, pattern: "(")
        }
        #expect(error?.errorDescription == "Invalid search pattern: '('")
    }

    @Test("Ordering is due date first, dated before undated, then title and ID")
    func ordered() {
        let reminders = [
            TestFixtures.reminder(id: "u1", title: "beta"),
            TestFixtures.reminder(id: "s2", title: "Same", dueDate: at(day: 3, hour: 9)),
            TestFixtures.reminder(id: "u3", title: "alpha"),
            TestFixtures.reminder(id: "d2", title: "Zed", dueDate: at(day: 2, hour: 9)),
            TestFixtures.reminder(id: "s1", title: "Same", dueDate: at(day: 3, hour: 9)),
            TestFixtures.reminder(id: "u2", title: "Alpha"),
            TestFixtures.reminder(id: "d1", title: "Yak", dueDate: at(day: 1, hour: 9))
        ]

        #expect(ids(ReminderFilters.ordered(reminders)) == ["d1", "d2", "s1", "s2", "u2", "u3", "u1"])
    }
}
