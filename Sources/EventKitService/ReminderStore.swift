import EventKit

/// The EventKit calls behind reads and the allowlist, so tests can drive them
/// without Reminders access. `EKEventStore` already has the last four.
protocol ReminderStore {
    func reminderCalendars() -> [EKCalendar]
    func predicateForReminders(in calendars: [EKCalendar]?) -> NSPredicate
    func predicateForIncompleteReminders(
        withDueDateStarting startDate: Date?, ending endDate: Date?, calendars: [EKCalendar]?
    ) -> NSPredicate
    func fetchReminders(matching predicate: NSPredicate, completion: @escaping ([EKReminder]?) -> Void) -> Any
    func cancelFetchRequest(_ fetchIdentifier: Any)
}

extension EKEventStore: ReminderStore {
    func reminderCalendars() -> [EKCalendar] {
        calendars(for: .reminder)
    }
}
