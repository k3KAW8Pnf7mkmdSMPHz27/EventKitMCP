import EventKitService
import Foundation
import Testing

@testable import EventKitMCP

@Suite("Overview snapshot tests")
struct OverviewSnapshotTests {
    /// Noon on 2026-06-10, local time.
    private let now = Calendar.current.date(from: DateComponents(year: 2026, month: 6, day: 10, hour: 12))!

    private func at(day: Int, hour: Int) -> Date {
        let start = Calendar.current.startOfDay(for: now)
        return Calendar.current.date(byAdding: DateComponents(day: day, hour: hour), to: start)!
    }

    private let personal = ReminderListModel(id: "list-2", title: "Personal")
    private let empty = ReminderListModel(id: "list-3", title: "Empty")

    @Test("Counts and per-list stats match the text, and empty lists are left out")
    func countsAndListStats() {
        let reminders = [
            TestFixtures.reminder(id: "o1", title: "Late high", priority: .high, dueDate: at(day: -1, hour: 9)),
            TestFixtures.reminder(id: "t1", title: "Today", priority: .medium, dueDate: at(day: 0, hour: 15)),
            TestFixtures.reminder(id: "u1", title: "Soon", dueDate: at(day: 3, hour: 9)),
            TestFixtures.reminder(id: "a1", title: "Undated high", priority: .high),
            TestFixtures.reminder(id: "x1", title: "Plain", listId: personal.id, listName: personal.title)
        ]
        let snapshot = OverviewSnapshot(
            lists: [TestFixtures.workList, personal, empty], reminders: reminders, now: now)
        let output = snapshot.output

        let counts: [Int] = [
            output.listCount, output.incompleteCount, output.overdueCount, output.todayCount,
            output.upcomingCount, output.attentionCount
        ]
        #expect(counts == [3, 5, 1, 1, 1, 1])
        #expect(snapshot.scheduledCount == 3 && snapshot.unscheduledOtherCount == 1)
        #expect(output.lists.map(\.id) == [TestFixtures.workList.id, personal.id])
        let work = output.lists[0]
        let workCounts: [Int] = [
            work.incompleteCount, work.overdueCount, work.highPriorityCount, work.mediumPriorityCount
        ]
        #expect(workCounts == [4, 1, 2, 1])
        #expect(output.attention.map(\.id) == ["a1"])
        #expect(output.today.map(\.id) == ["t1"])
        #expect(snapshot.render().contains("- Work: 4 incomplete, 1 overdue, 2 high, 1 medium"))
    }

    @Test("Structured overdue is capped like the text, highest priority first, with the full count")
    func overdueCap() {
        let reminders = (1...13).map { i in
            TestFixtures.reminder(
                id: "o\(i)", title: "Overdue \(i)", priority: i == 13 ? .high : .none, dueDate: at(day: -i, hour: 9))
        }
        let output = OverviewSnapshot(lists: [TestFixtures.workList], reminders: reminders, now: now).output

        #expect(output.overdueCount == 13)
        #expect(output.overdue.count == 10)
        #expect(output.overdue.first?.id == "o13")
    }

    @Test("Upcoming is counted per local day, earliest first, through the window's last day")
    func upcomingByDay() {
        let reminders = [
            TestFixtures.reminder(id: "late", title: "Last day", dueDate: at(day: 7, hour: 23)),
            TestFixtures.reminder(id: "u2", title: "Evening", dueDate: at(day: 2, hour: 18)),
            TestFixtures.reminder(id: "u1", title: "Morning", dueDate: at(day: 2, hour: 9)),
            TestFixtures.reminder(id: "out", title: "Too far", dueDate: at(day: 8, hour: 9))
        ]
        let output = OverviewSnapshot(lists: [TestFixtures.workList], reminders: reminders, now: now).output

        #expect(output.upcomingByDay.map(\.date) == ["2026-06-12", "2026-06-17"])
        #expect(output.upcomingByDay.map(\.count) == [2, 1])
        #expect(output.upcomingCount == 3)
    }
}
