import EventKit
import Foundation
import Logging

// MARK: - Reminder Service Protocol

/// Protocol defining the interface for reminder operations
public protocol ReminderServiceProtocol: Sendable {
    /// Request access to reminders
    func requestAccess() async throws -> Bool

    /// Get all reminder lists
    func getLists() async throws -> [ReminderListModel]

    /// Get a specific reminder list by ID
    func getList(id: String) async throws -> ReminderListModel?

    /// Create a new reminder list
    func createList(_ request: CreateListRequest) async throws -> ReminderListModel

    /// Delete a reminder list
    func deleteList(id: String) async throws

    /// Get all reminders, optionally filtered by list
    func getReminders(listId: String?, includeDone: Bool) async throws -> [ReminderModel]

    /// Get a specific reminder by ID
    func getReminder(id: String) async throws -> ReminderModel?

    /// Create a new reminder
    func createReminder(_ request: CreateReminderRequest) async throws -> ReminderModel

    /// Update an existing reminder
    func updateReminder(_ request: UpdateReminderRequest) async throws -> ReminderModel

    /// Delete a reminder, returning the deleted reminder's data
    @discardableResult
    func deleteReminder(id: String) async throws -> ReminderModel

    /// Mark a reminder as done
    func markDone(id: String) async throws -> ReminderModel

    /// Search reminders by title
    func searchReminders(query: String, includeDone: Bool) async throws -> [ReminderModel]

    /// Move a reminder to a different list
    func moveReminder(id: String, toListId: String) async throws -> ReminderModel
}

// MARK: - Reminder Service Implementation

/// Service for interacting with Apple Reminders via EventKit
public final class ReminderService: ReminderServiceProtocol, @unchecked Sendable {
    private let eventStore: EKEventStore
    private let logger: Logger
    private let queue = DispatchQueue(label: "com.eventkit.mcp.reminder-service")
    private let allowedListIds: Set<String>?

    public init(
        logger: Logger = Logger(label: "eventkit.reminder-service"),
        allowedListIds: Set<String>? = nil
    ) {
        self.eventStore = EKEventStore()
        self.logger = logger
        self.allowedListIds = allowedListIds
    }

    // MARK: - Access Control Helpers

    private func isListAllowed(id: String) -> Bool {
        guard let allowed = allowedListIds else { return true }
        return allowed.contains(id)
    }

    private func allowedCalendars() -> [EKCalendar] {
        let all = eventStore.calendars(for: .reminder)
        guard let allowed = allowedListIds else { return all }
        return all.filter { allowed.contains($0.calendarIdentifier) }
    }

    // MARK: - Access

    public func requestAccess() async throws -> Bool {
        logger.info("Requesting reminders access")

        if #available(macOS 14.0, *) {
            return try await eventStore.requestFullAccessToReminders()
        } else {
            return try await withCheckedThrowingContinuation { continuation in
                eventStore.requestAccess(to: .reminder) { granted, error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: granted)
                    }
                }
            }
        }
    }

    // MARK: - Lists

    public func getLists() async throws -> [ReminderListModel] {
        let calendars = allowedCalendars()
        return calendars.map { mapCalendarToList($0) }
    }

    public func getList(id: String) async throws -> ReminderListModel? {
        guard isListAllowed(id: id) else {
            throw ReminderServiceError.listAccessDenied(id)
        }
        guard let calendar = eventStore.calendar(withIdentifier: id) else {
            return nil
        }
        return mapCalendarToList(calendar)
    }

    public func createList(_ request: CreateListRequest) async throws -> ReminderListModel {
        // Block list creation when allowlist is active
        if allowedListIds != nil {
            throw ReminderServiceError.listCreationBlocked
        }

        let calendar = EKCalendar(for: .reminder, eventStore: eventStore)
        calendar.title = request.title

        // Find the default source for reminders
        guard let source = findDefaultSource() else {
            throw ReminderServiceError.noValidSource
        }
        calendar.source = source

        if let colorHex = request.color {
            calendar.cgColor = colorFromHex(colorHex)
        }

        try eventStore.saveCalendar(calendar, commit: true)
        logger.info("Created reminder list", metadata: ["title": "\(request.title)"])

        return mapCalendarToList(calendar)
    }

    public func deleteList(id: String) async throws {
        guard isListAllowed(id: id) else {
            throw ReminderServiceError.listAccessDenied(id)
        }
        guard let calendar = eventStore.calendar(withIdentifier: id) else {
            throw ReminderServiceError.listNotFound(id)
        }

        try eventStore.removeCalendar(calendar, commit: true)
        logger.info("Deleted reminder list", metadata: ["id": "\(id)"])
    }

    // MARK: - Reminders

    public func getReminders(listId: String?, includeDone: Bool) async throws -> [ReminderModel] {
        let calendars: [EKCalendar]

        if let listId = listId {
            guard isListAllowed(id: listId) else {
                throw ReminderServiceError.listAccessDenied(listId)
            }
            guard let calendar = eventStore.calendar(withIdentifier: listId) else {
                throw ReminderServiceError.listNotFound(listId)
            }
            calendars = [calendar]
        } else {
            calendars = allowedCalendars()
        }

        let predicate = eventStore.predicateForReminders(in: calendars)
        let reminders = try await fetchReminders(predicate: predicate)

        let filtered = includeDone ? reminders : reminders.filter { !$0.isCompleted }
        return filtered.map { mapReminderToModel($0) }
    }

    public func getReminder(id: String) async throws -> ReminderModel? {
        guard let item = eventStore.calendarItem(withIdentifier: id) as? EKReminder else {
            return nil
        }
        // Check if reminder's list is allowed
        guard isListAllowed(id: item.calendar.calendarIdentifier) else {
            throw ReminderServiceError.listAccessDenied(item.calendar.calendarIdentifier)
        }
        return mapReminderToModel(item)
    }

    public func createReminder(_ request: CreateReminderRequest) async throws -> ReminderModel {
        let reminder = EKReminder(eventStore: eventStore)
        reminder.title = request.title
        reminder.notes = request.notes

        // Set the calendar (list)
        if let listId = request.listId {
            guard isListAllowed(id: listId) else {
                throw ReminderServiceError.listAccessDenied(listId)
            }
            guard let calendar = eventStore.calendar(withIdentifier: listId) else {
                throw ReminderServiceError.listNotFound(listId)
            }
            reminder.calendar = calendar
        } else {
            // Use default calendar, but verify it's allowed
            guard let defaultCal = eventStore.defaultCalendarForNewReminders() else {
                throw ReminderServiceError.noValidSource
            }
            guard isListAllowed(id: defaultCal.calendarIdentifier) else {
                throw ReminderServiceError.listAccessDenied(defaultCal.calendarIdentifier)
            }
            reminder.calendar = defaultCal
        }

        // Set due date
        if let dueDate = request.dueDate {
            if request.isAllDay {
                // Date-only: exclude hour/minute so they remain nil in EventKit
                reminder.dueDateComponents = Calendar.current.dateComponents(
                    [.year, .month, .day],
                    from: dueDate
                )
            } else {
                // Specific time: include hour/minute
                reminder.dueDateComponents = Calendar.current.dateComponents(
                    [.year, .month, .day, .hour, .minute],
                    from: dueDate
                )
            }
        }

        // Set start date
        if let startDate = request.startDate {
            if request.isStartAllDay {
                reminder.startDateComponents = Calendar.current.dateComponents(
                    [.year, .month, .day],
                    from: startDate
                )
            } else {
                reminder.startDateComponents = Calendar.current.dateComponents(
                    [.year, .month, .day, .hour, .minute],
                    from: startDate
                )
            }
        }

        // Set priority
        if let priority = request.priority {
            reminder.priority = priority.rawValue
        }

        // Set location
        if let location = request.location {
            reminder.location = location
        }

        // Set URL
        if let urlString = request.url, let url = URL(string: urlString) {
            reminder.url = url
        }

        // Set recurrence rule
        if let rrule = request.recurrenceRule {
            let ekRule = try RRuleParser.parse(rrule)
            reminder.addRecurrenceRule(ekRule)
        }

        // Set alarms
        if let alarmOffsets = request.alarms {
            for offset in alarmOffsets {
                let alarm = EKAlarm(relativeOffset: TimeInterval(-offset * 60))
                reminder.addAlarm(alarm)
            }
        }

        try eventStore.save(reminder, commit: true)
        logger.info("Created reminder", metadata: ["title": "\(request.title)"])

        return mapReminderToModel(reminder)
    }

    public func updateReminder(_ request: UpdateReminderRequest) async throws -> ReminderModel {
        guard let reminder = eventStore.calendarItem(withIdentifier: request.id) as? EKReminder else {
            throw ReminderServiceError.reminderNotFound(request.id)
        }

        // Verify current list is allowed
        guard isListAllowed(id: reminder.calendar.calendarIdentifier) else {
            throw ReminderServiceError.listAccessDenied(reminder.calendar.calendarIdentifier)
        }

        if let title = request.title {
            reminder.title = title
        }

        if let notes = request.notes {
            reminder.notes = notes
        }

        if let done = request.done {
            reminder.isCompleted = done
            if done && reminder.completionDate == nil {
                reminder.completionDate = Date()
            }
        }

        // Handle due date and isAllDay changes
        if let dueDate = request.dueDate {
            // New due date provided - use isAllDay from request (defaults to false if nil)
            let allDay = request.isAllDay ?? false
            if allDay {
                reminder.dueDateComponents = Calendar.current.dateComponents(
                    [.year, .month, .day],
                    from: dueDate
                )
            } else {
                reminder.dueDateComponents = Calendar.current.dateComponents(
                    [.year, .month, .day, .hour, .minute],
                    from: dueDate
                )
            }
        } else if let isAllDay = request.isAllDay, let existingComponents = reminder.dueDateComponents {
            // Only isAllDay changed, preserve existing date
            if isAllDay && existingComponents.hour != nil {
                // Convert to date-only: remove hour/minute
                var newComponents = existingComponents
                newComponents.hour = nil
                newComponents.minute = nil
                reminder.dueDateComponents = newComponents
            } else if !isAllDay && existingComponents.hour == nil {
                // Convert from date-only to timed: add midnight as default
                var newComponents = existingComponents
                newComponents.hour = 0
                newComponents.minute = 0
                reminder.dueDateComponents = newComponents
            }
        }

        // Handle start date changes
        if request.removeStartDate {
            reminder.startDateComponents = nil
        } else if let startDate = request.startDate {
            let allDay = request.isStartAllDay ?? false
            if allDay {
                reminder.startDateComponents = Calendar.current.dateComponents(
                    [.year, .month, .day],
                    from: startDate
                )
            } else {
                reminder.startDateComponents = Calendar.current.dateComponents(
                    [.year, .month, .day, .hour, .minute],
                    from: startDate
                )
            }
        }

        if let priority = request.priority {
            reminder.priority = priority.rawValue
        }

        // Verify target list if moving
        if let listId = request.listId {
            guard isListAllowed(id: listId) else {
                throw ReminderServiceError.listAccessDenied(listId)
            }
            guard let targetCalendar = eventStore.calendar(withIdentifier: listId) else {
                throw ReminderServiceError.listNotFound(listId)
            }
            reminder.calendar = targetCalendar
        }

        if let location = request.location {
            reminder.location = location
        }

        if let urlString = request.url, let url = URL(string: urlString) {
            reminder.url = url
        }

        // Handle recurrence rule changes
        if request.removeRecurrence {
            reminder.recurrenceRules?.forEach { reminder.removeRecurrenceRule($0) }
        } else if let rrule = request.recurrenceRule {
            reminder.recurrenceRules?.forEach { reminder.removeRecurrenceRule($0) }
            let ekRule = try RRuleParser.parse(rrule)
            reminder.addRecurrenceRule(ekRule)
        }

        // Handle alarm changes
        if request.removeAlarms {
            reminder.alarms?.forEach { reminder.removeAlarm($0) }
        } else if let alarmOffsets = request.alarms {
            reminder.alarms?.forEach { reminder.removeAlarm($0) }
            for offset in alarmOffsets {
                let alarm = EKAlarm(relativeOffset: TimeInterval(-offset * 60))
                reminder.addAlarm(alarm)
            }
        }

        try eventStore.save(reminder, commit: true)
        logger.info("Updated reminder", metadata: ["id": "\(request.id)"])

        return mapReminderToModel(reminder)
    }

    @discardableResult
    public func deleteReminder(id: String) async throws -> ReminderModel {
        guard let reminder = eventStore.calendarItem(withIdentifier: id) as? EKReminder else {
            throw ReminderServiceError.reminderNotFound(id)
        }

        guard isListAllowed(id: reminder.calendar.calendarIdentifier) else {
            throw ReminderServiceError.listAccessDenied(reminder.calendar.calendarIdentifier)
        }

        // Capture reminder data before deletion
        let model = mapReminderToModel(reminder)

        try eventStore.remove(reminder, commit: true)
        logger.info("Deleted reminder", metadata: ["id": "\(id)"])

        return model
    }

    public func markDone(id: String) async throws -> ReminderModel {
        guard let reminder = eventStore.calendarItem(withIdentifier: id) as? EKReminder else {
            throw ReminderServiceError.reminderNotFound(id)
        }

        reminder.isCompleted = true
        reminder.completionDate = Date()

        try eventStore.save(reminder, commit: true)
        logger.info("Marked reminder done", metadata: ["id": "\(id)"])

        return mapReminderToModel(reminder)
    }

    public func searchReminders(query: String, includeDone: Bool) async throws -> [ReminderModel] {
        let calendars = allowedCalendars()
        let predicate = eventStore.predicateForReminders(in: calendars)
        let reminders = try await fetchReminders(predicate: predicate)

        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: query, options: .caseInsensitive)
        } catch {
            throw ReminderServiceError.invalidSearchQuery(query)
        }

        let filtered = reminders.filter { reminder in
            let id = reminder.calendarItemIdentifier
            let idMatch = regex.firstMatch(in: id, range: NSRange(id.startIndex..., in: id)) != nil
            let titleMatch = reminder.title.map { regex.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil } ?? false
            let notesMatch = reminder.notes.map { regex.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil } ?? false
            let matchesQuery = idMatch || titleMatch || notesMatch

            if includeDone {
                return matchesQuery
            } else {
                return matchesQuery && !reminder.isCompleted
            }
        }

        return filtered.map { mapReminderToModel($0) }
    }

    public func moveReminder(id: String, toListId: String) async throws -> ReminderModel {
        guard let reminder = eventStore.calendarItem(withIdentifier: id) as? EKReminder else {
            throw ReminderServiceError.reminderNotFound(id)
        }

        guard let targetCalendar = eventStore.calendar(withIdentifier: toListId) else {
            throw ReminderServiceError.listNotFound(toListId)
        }

        reminder.calendar = targetCalendar

        try eventStore.save(reminder, commit: true)
        logger.info("Moved reminder", metadata: ["id": "\(id)", "toList": "\(toListId)"])

        return mapReminderToModel(reminder)
    }

    // MARK: - Private Helpers

    private func fetchReminders(predicate: NSPredicate) async throws -> [EKReminder] {
        try await withCheckedThrowingContinuation { continuation in
            eventStore.fetchReminders(matching: predicate) { reminders in
                // EKReminder is not Sendable, but we're immediately processing them
                // on the same thread context within this actor-isolated class
                nonisolated(unsafe) let result = reminders ?? []
                continuation.resume(returning: result)
            }
        }
    }

    private func findDefaultSource() -> EKSource? {
        // Try to find the local source first
        if let local = eventStore.sources.first(where: { $0.sourceType == .local }) {
            return local
        }

        // Fall back to iCloud
        if let icloud = eventStore.sources.first(where: { $0.sourceType == .calDAV && $0.title == "iCloud" }) {
            return icloud
        }

        // Use any available source
        return eventStore.sources.first(where: { $0.sourceType != .birthdays })
    }

    private func mapCalendarToList(_ calendar: EKCalendar) -> ReminderListModel {
        ReminderListModel(
            id: calendar.calendarIdentifier,
            title: calendar.title,
            color: hexFromColor(calendar.cgColor),
            isSubscribed: calendar.isSubscribed,
            isImmutable: calendar.isImmutable,
            sourceTitle: calendar.source?.title
        )
    }

    private func mapReminderToModel(_ reminder: EKReminder) -> ReminderModel {
        let dueDate: Date?
        let isAllDay: Bool

        if let components = reminder.dueDateComponents {
            dueDate = Calendar.current.date(from: components)
            // Date-only if hour component is nil (not just 0)
            isAllDay = components.hour == nil
        } else {
            dueDate = nil
            isAllDay = false
        }

        // Extract start date
        let startDate: Date?
        let isStartAllDay: Bool

        if let components = reminder.startDateComponents {
            startDate = Calendar.current.date(from: components)
            isStartAllDay = components.hour == nil
        } else {
            startDate = nil
            isStartAllDay = false
        }

        // Convert recurrence rule to RRULE string
        let recurrenceRule: String? = reminder.recurrenceRules?.first.map { RRuleParser.format($0) }

        // Extract alarms as minute offsets (skip location-based alarms)
        let alarmOffsets: [Int]?
        if let ekAlarms = reminder.alarms, !ekAlarms.isEmpty {
            let offsets = ekAlarms.compactMap { alarm -> Int? in
                guard alarm.structuredLocation == nil else { return nil }
                return Int(-alarm.relativeOffset / 60)
            }.sorted()
            alarmOffsets = offsets.isEmpty ? nil : offsets
        } else {
            alarmOffsets = nil
        }

        return ReminderModel(
            id: reminder.calendarItemIdentifier,
            title: reminder.title ?? "",
            notes: reminder.notes,
            done: reminder.isCompleted,
            priority: ReminderPriority(eventKitPriority: reminder.priority),
            dueDate: dueDate,
            isAllDay: isAllDay,
            doneDate: reminder.completionDate,
            listId: reminder.calendar.calendarIdentifier,
            listName: reminder.calendar.title,
            creationDate: reminder.creationDate,
            lastModifiedDate: reminder.lastModifiedDate,
            recurrenceRule: recurrenceRule,
            url: reminder.url?.absoluteString,
            location: reminder.location,
            startDate: startDate,
            isStartAllDay: isStartAllDay,
            alarms: alarmOffsets
        )
    }

    private func colorFromHex(_ hex: String) -> CGColor? {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        var rgb: UInt64 = 0
        Scanner(string: hexSanitized).scanHexInt64(&rgb)

        let red = CGFloat((rgb & 0xFF0000) >> 16) / 255.0
        let green = CGFloat((rgb & 0x00FF00) >> 8) / 255.0
        let blue = CGFloat(rgb & 0x0000FF) / 255.0

        return CGColor(red: red, green: green, blue: blue, alpha: 1.0)
    }

    private func hexFromColor(_ cgColor: CGColor?) -> String? {
        guard let color = cgColor,
              let components = color.components,
              components.count >= 3 else {
            return nil
        }

        let red = Int(components[0] * 255)
        let green = Int(components[1] * 255)
        let blue = Int(components[2] * 255)

        return String(format: "#%02X%02X%02X", red, green, blue)
    }
}

// MARK: - Errors

/// Errors that can occur during reminder operations
public enum ReminderServiceError: Error, LocalizedError {
    case accessDenied
    case listNotFound(String)
    case reminderNotFound(String)
    case noValidSource
    case saveFailed(String)
    case listAccessDenied(String)
    case listCreationBlocked
    case invalidSearchQuery(String)

    public var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "Access to reminders was denied"
        case .listNotFound(let id):
            return "Reminder list not found: \(id)"
        case .reminderNotFound(let id):
            return "Reminder not found: \(id)"
        case .noValidSource:
            return "No valid source found for creating reminder lists"
        case .saveFailed(let message):
            return "Failed to save: \(message)"
        case .listAccessDenied(let id):
            return "Access to reminder list '\(id)' is not allowed"
        case .listCreationBlocked:
            return "Creating new reminder lists is not allowed when --allowed-lists is active"
        case .invalidSearchQuery(let query):
            return "Invalid search pattern: '\(query)'"
        }
    }
}
