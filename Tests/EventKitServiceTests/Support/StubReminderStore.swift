import EventKit
import Foundation

@testable import EventKitService

/// A `ReminderStore` over unsaved EventKit objects, which get real identifiers at
/// creation and need no Reminders access. Records every predicate, save and remove.
final class StubReminderStore: ReminderStore, @unchecked Sendable {
    private let lock = NSLock()
    private let calendars: [EKCalendar]
    private var reminders: [String: EKReminder]
    private let defaultCalendar: EKCalendar?
    private var counts: [Int?] = []
    private var savedItems: [EKReminder] = []
    private var removedItems: [EKReminder] = []
    private var removedCalendarIds: [String] = []

    init(calendars: [EKCalendar], reminders: [EKReminder] = [], defaultCalendar: EKCalendar? = nil) {
        self.calendars = calendars
        self.reminders = Dictionary(uniqueKeysWithValues: reminders.map { ($0.calendarItemIdentifier, $0) })
        self.defaultCalendar = defaultCalendar
    }

    /// One entry per predicate built; `nil` means EventKit's "all calendars".
    var predicateCalendarCounts: [Int?] { lock.withLock { counts } }
    var saved: [EKReminder] { lock.withLock { savedItems } }
    var removed: [EKReminder] { lock.withLock { removedItems } }
    var removedCalendars: [String] { lock.withLock { removedCalendarIds } }

    func reminderCalendars() -> [EKCalendar] { calendars }
    func predicateForReminders(in calendars: [EKCalendar]?) -> NSPredicate {
        record(calendars)
        return NSPredicate(value: true)
    }
    func predicateForIncompleteReminders(
        withDueDateStarting: Date?, ending: Date?, calendars: [EKCalendar]?
    ) -> NSPredicate {
        record(calendars)
        return NSPredicate(value: true)
    }
    func fetchReminderItems(matching: NSPredicate, completion: @escaping @Sendable ([EKReminder]?) -> Void) -> Any {
        completion([])
        return NSObject()
    }
    func cancelFetchRequest(_: Any) {}

    func calendar(withIdentifier identifier: String) -> EKCalendar? {
        calendars.first { $0.calendarIdentifier == identifier }
    }
    func calendarItem(withIdentifier identifier: String) -> EKCalendarItem? {
        lock.withLock { reminders[identifier] }
    }
    func defaultCalendarForNewReminders() -> EKCalendar? { defaultCalendar }
    var sources: [EKSource] { [] }
    func save(_ reminder: EKReminder, commit: Bool) throws {
        lock.withLock { savedItems.append(reminder) }
    }
    func remove(_ reminder: EKReminder, commit: Bool) throws {
        lock.withLock {
            removedItems.append(reminder)
            reminders[reminder.calendarItemIdentifier] = nil
        }
    }
    func saveCalendar(_ calendar: EKCalendar, commit: Bool) throws {}
    func removeCalendar(_ calendar: EKCalendar, commit: Bool) throws {
        lock.withLock { removedCalendarIds.append(calendar.calendarIdentifier) }
    }

    private func record(_ calendars: [EKCalendar]?) { lock.withLock { counts.append(calendars?.count) } }
}
