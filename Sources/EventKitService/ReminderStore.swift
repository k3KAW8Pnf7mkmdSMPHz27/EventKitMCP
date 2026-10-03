import EventKit

/// Every EventKit call the service makes besides constructing objects and requesting
/// access, so tests can drive it without Reminders access. `EKEventStore` already has
/// all but the first.
protocol ReminderStore {
    func reminderCalendars() -> [EKCalendar]
    func predicateForReminders(in calendars: [EKCalendar]?) -> NSPredicate
    func predicateForIncompleteReminders(
        withDueDateStarting startDate: Date?, ending endDate: Date?, calendars: [EKCalendar]?
    ) -> NSPredicate
    func fetchReminders(matching predicate: NSPredicate, completion: @escaping ([EKReminder]?) -> Void) -> Any
    func cancelFetchRequest(_ fetchIdentifier: Any)

    func calendar(withIdentifier identifier: String) -> EKCalendar?
    func calendarItem(withIdentifier identifier: String) -> EKCalendarItem?
    func defaultCalendarForNewReminders() -> EKCalendar?
    var sources: [EKSource] { get }
    func save(_ reminder: EKReminder, commit: Bool) throws
    func remove(_ reminder: EKReminder, commit: Bool) throws
    func saveCalendar(_ calendar: EKCalendar, commit: Bool) throws
    func removeCalendar(_ calendar: EKCalendar, commit: Bool) throws
}

extension EKEventStore: ReminderStore {
    func reminderCalendars() -> [EKCalendar] {
        calendars(for: .reminder)
    }
}
