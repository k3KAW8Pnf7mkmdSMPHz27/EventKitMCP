import Foundation
@testable import EventKitService

/// Common test fixtures for EventKitMCP tests
enum TestFixtures {
    // MARK: - Common Dates

    /// Yesterday at midnight
    static var yesterday: Date {
        Calendar.current.date(byAdding: .day, value: -1, to: Date())!
    }

    /// Tomorrow at midnight
    static var tomorrow: Date {
        Calendar.current.date(byAdding: .day, value: 1, to: Date())!
    }

    /// Today at noon
    static var todayNoon: Date {
        Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
    }

    /// In 3 days
    static var in3Days: Date {
        Calendar.current.date(byAdding: .day, value: 3, to: Date())!
    }

    /// In 10 days
    static var in10Days: Date {
        Calendar.current.date(byAdding: .day, value: 10, to: Date())!
    }

    // MARK: - Common Lists

    static let workList = ReminderListModel(
        id: "list-1",
        title: "Work",
        color: nil,
        isSubscribed: false,
        isImmutable: false,
        sourceTitle: nil
    )

    static let personalList = ReminderListModel(
        id: "list-2",
        title: "Personal",
        color: "#FF5733",
        isSubscribed: false,
        isImmutable: false,
        sourceTitle: nil
    )

    static let shoppingList = ReminderListModel(
        id: "list-3",
        title: "Shopping",
        color: "#33FF57",
        isSubscribed: false,
        isImmutable: false,
        sourceTitle: "iCloud"
    )

    // MARK: - Reminder Factory

    /// Create a reminder with customizable fields
    static func reminder(
        id: String = "r1",
        title: String = "Task",
        notes: String? = nil,
        done: Bool = false,
        priority: ReminderPriority = .none,
        dueDate: Date? = nil,
        isAllDay: Bool = false,
        listId: String = "list-1",
        listName: String = "Work",
        url: String? = nil,
        location: String? = nil,
        startDate: Date? = nil,
        isStartAllDay: Bool = false,
        alarms: [Int]? = nil
    ) -> ReminderModel {
        ReminderModel(
            id: id,
            title: title,
            notes: notes,
            done: done,
            priority: priority,
            dueDate: dueDate,
            isAllDay: isAllDay,
            listId: listId,
            listName: listName,
            url: url,
            location: location,
            startDate: startDate,
            isStartAllDay: isStartAllDay,
            alarms: alarms?.map(ReminderAlarmModel.relative(minutesBefore:))
        )
    }

    // MARK: - Preset Reminders

    /// A basic task with no due date
    static let basicTask = reminder(id: "r1", title: "Basic Task")

    /// An overdue task (due yesterday)
    static var overdueTask: ReminderModel {
        reminder(id: "r2", title: "Overdue Task", dueDate: yesterday)
    }

    /// A task due today
    static var todayTask: ReminderModel {
        reminder(id: "r3", title: "Today Task", dueDate: todayNoon)
    }

    /// A high priority task
    static let highPriorityTask = reminder(
        id: "r4",
        title: "High Priority Task",
        priority: .high
    )

    /// A done task
    static let doneTask = reminder(
        id: "r5",
        title: "Done Task",
        done: true
    )

    /// An upcoming task (due in 3 days)
    static var upcomingTask: ReminderModel {
        reminder(id: "r6", title: "Upcoming Task", dueDate: in3Days)
    }

    /// A task far in the future (due in 10 days)
    static var futureTask: ReminderModel {
        reminder(id: "r7", title: "Future Task", dueDate: in10Days)
    }

    /// A personal task in the personal list
    static let personalTask = reminder(
        id: "r8",
        title: "Personal Task",
        listId: "list-2",
        listName: "Personal"
    )

    // MARK: - Common Test Scenarios

    /// A set of reminders for testing filtering
    static var filterTestReminders: [ReminderModel] {
        [
            overdueTask,
            todayTask,
            upcomingTask,
            futureTask,
            basicTask
        ]
    }

    /// A set of reminders for testing priority filtering
    static var priorityTestReminders: [ReminderModel] {
        [
            reminder(id: "p1", title: "High Priority", priority: .high),
            reminder(id: "p2", title: "Medium Priority", priority: .medium),
            reminder(id: "p3", title: "Low Priority", priority: .low),
            reminder(id: "p4", title: "No Priority", priority: .none)
        ]
    }

    /// Standard list setup for tests
    static let standardLists = [workList, personalList]
}
