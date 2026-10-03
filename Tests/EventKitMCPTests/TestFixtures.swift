import Foundation
@testable import EventKitService

/// Common test fixtures for EventKitMCP tests
enum TestFixtures {
    // MARK: - Common Dates

    /// This time yesterday
    static var yesterday: Date {
        Calendar.current.date(byAdding: .day, value: -1, to: Date())!
    }

    /// This time tomorrow
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
}
