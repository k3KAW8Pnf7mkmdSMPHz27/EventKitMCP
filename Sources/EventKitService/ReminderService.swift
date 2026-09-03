import EventKit
import Foundation
import Logging
import CoreLocation

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

    /// Move a reminder to a different list
    func moveReminder(id: String, toListId: String) async throws -> ReminderModel
}

// MARK: - Reminder Service Implementation

/// Service for interacting with Apple Reminders via EventKit
public actor ReminderService: ReminderServiceProtocol {
    private let eventStore: EKEventStore
    private let logger: Logger
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

        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess:
            return true
        case .notDetermined:
            return try await eventStore.requestFullAccessToReminders()
        case .denied, .restricted, .writeOnly:
            throw ReminderServiceError.accessDenied
        @unknown default:
            throw ReminderServiceError.accessDenied
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

        let predicate = includeDone
            ? eventStore.predicateForReminders(in: calendars)
            : eventStore.predicateForIncompleteReminders(
                withDueDateStarting: nil,
                ending: nil,
                calendars: calendars
            )
        return try await fetchReminderModels(predicate: predicate)
    }

    public func getReminder(id: String) async throws -> ReminderModel? {
        guard let item = eventStore.calendarItem(withIdentifier: id) as? EKReminder else {
            return nil
        }
        // Check if reminder's list is allowed
        guard isListAllowed(id: item.calendar.calendarIdentifier) else {
            throw ReminderServiceError.listAccessDenied(item.calendar.calendarIdentifier)
        }
        return Self.mapReminderToModel(item)
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
            reminder.dueDateComponents = try dateComponents(
                from: dueDate,
                allDay: request.isAllDay,
                timeZoneIdentifier: request.dueTimeZone
            )
        }

        // Set start date
        if let startDate = request.startDate {
            reminder.startDateComponents = try dateComponents(
                from: startDate,
                allDay: request.isStartAllDay,
                timeZoneIdentifier: request.startTimeZone
            )
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
        if let urlString = request.url {
            reminder.url = try validatedURL(urlString)
        }

        // Set recurrence rule
        if let rrule = request.recurrenceRule {
            let ekRule = try RRuleParser.parse(rrule)
            reminder.addRecurrenceRule(ekRule)
        }

        // Set alarms
        if let alarms = request.alarms {
            try validateAlarmReferences(alarms, hasStartDate: reminder.startDateComponents != nil)
            for alarm in try alarms.map(makeAlarm) { reminder.addAlarm(alarm) }
        }

        try eventStore.save(reminder, commit: true)
        logger.info("Created reminder", metadata: ["title": "\(request.title)"])

        return Self.mapReminderToModel(reminder)
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

        if request.removeNotes {
            reminder.notes = nil
        } else if let notes = request.notes {
            reminder.notes = notes
        }

        if let done = request.done {
            reminder.isCompleted = done
            if done && reminder.completionDate == nil {
                reminder.completionDate = Date()
            }
        }

        // Handle due date and isAllDay changes
        if request.removeDueDate {
            reminder.dueDateComponents = nil
        } else if let dueDate = request.dueDate {
            // New due date provided - use isAllDay from request (defaults to false if nil)
            let allDay = request.isAllDay ?? false
            reminder.dueDateComponents = try dateComponents(
                from: dueDate,
                allDay: allDay,
                timeZoneIdentifier: request.dueTimeZone
            )
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
            reminder.startDateComponents = try dateComponents(
                from: startDate,
                allDay: allDay,
                timeZoneIdentifier: request.startTimeZone
            )
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

        if request.removeLocation {
            reminder.location = nil
        } else if let location = request.location {
            reminder.location = location
        }

        if request.removeURL {
            reminder.url = nil
        } else if let urlString = request.url {
            reminder.url = try validatedURL(urlString)
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
        } else if let alarms = request.alarms {
            try validateAlarmReferences(alarms, hasStartDate: reminder.startDateComponents != nil)
            reminder.alarms?.forEach { reminder.removeAlarm($0) }
            for alarm in try alarms.map(makeAlarm) { reminder.addAlarm(alarm) }
        }

        try eventStore.save(reminder, commit: true)
        logger.info("Updated reminder", metadata: ["id": "\(request.id)"])

        return Self.mapReminderToModel(reminder)
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
        let model = Self.mapReminderToModel(reminder)

        try eventStore.remove(reminder, commit: true)
        logger.info("Deleted reminder", metadata: ["id": "\(id)"])

        return model
    }

    public func markDone(id: String) async throws -> ReminderModel {
        guard let reminder = eventStore.calendarItem(withIdentifier: id) as? EKReminder else {
            throw ReminderServiceError.reminderNotFound(id)
        }

        guard isListAllowed(id: reminder.calendar.calendarIdentifier) else {
            throw ReminderServiceError.listAccessDenied(reminder.calendar.calendarIdentifier)
        }

        reminder.isCompleted = true
        reminder.completionDate = Date()

        try eventStore.save(reminder, commit: true)
        logger.info("Marked reminder done", metadata: ["id": "\(id)"])

        return Self.mapReminderToModel(reminder)
    }

    public func moveReminder(id: String, toListId: String) async throws -> ReminderModel {
        guard let reminder = eventStore.calendarItem(withIdentifier: id) as? EKReminder else {
            throw ReminderServiceError.reminderNotFound(id)
        }

        guard isListAllowed(id: reminder.calendar.calendarIdentifier) else {
            throw ReminderServiceError.listAccessDenied(reminder.calendar.calendarIdentifier)
        }

        guard isListAllowed(id: toListId) else {
            throw ReminderServiceError.listAccessDenied(toListId)
        }

        guard let targetCalendar = eventStore.calendar(withIdentifier: toListId) else {
            throw ReminderServiceError.listNotFound(toListId)
        }

        reminder.calendar = targetCalendar

        try eventStore.save(reminder, commit: true)
        logger.info("Moved reminder", metadata: ["id": "\(id)", "toList": "\(toListId)"])

        return Self.mapReminderToModel(reminder)
    }

    // MARK: - Private Helpers

    private func fetchReminderModels(predicate: NSPredicate) async throws -> [ReminderModel] {
        await withCheckedContinuation { continuation in
            eventStore.fetchReminders(matching: predicate) { reminders in
                let result = (reminders ?? []).map(Self.mapReminderToModel)
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

    private static func mapReminderToModel(_ reminder: EKReminder) -> ReminderModel {
        let dueDate: Date?
        let isAllDay: Bool

        if let components = reminder.dueDateComponents {
            dueDate = calendar(for: components).date(from: components)
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
            startDate = calendar(for: components).date(from: components)
            isStartAllDay = components.hour == nil
        } else {
            startDate = nil
            isStartAllDay = false
        }

        // Convert recurrence rule to RRULE string
        let recurrenceRule: String? = reminder.recurrenceRules?.first.map { RRuleParser.format($0) }

        let alarmModels: [ReminderAlarmModel]?
        if let ekAlarms = reminder.alarms, !ekAlarms.isEmpty {
            alarmModels = ekAlarms.compactMap(mapAlarm)
        } else {
            alarmModels = nil
        }

        return ReminderModel(
            id: reminder.calendarItemIdentifier,
            title: reminder.title ?? "",
            notes: reminder.notes,
            done: reminder.isCompleted,
            priority: ReminderPriority(eventKitPriority: reminder.priority),
            dueDate: dueDate,
            dueTimeZone: reminder.dueDateComponents?.timeZone?.identifier,
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
            startTimeZone: reminder.startDateComponents?.timeZone?.identifier,
            isStartAllDay: isStartAllDay,
            alarms: alarmModels
        )
    }

    private static func calendar(for components: DateComponents) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        if let timeZone = components.timeZone { calendar.timeZone = timeZone }
        return calendar
    }

    private func dateComponents(from date: Date, allDay: Bool, timeZoneIdentifier: String?) throws -> DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        if let identifier = timeZoneIdentifier {
            guard let timeZone = TimeZone(identifier: identifier) else {
                throw ReminderServiceError.invalidTimeZone(identifier)
            }
            calendar.timeZone = timeZone
        }
        var components = calendar.dateComponents(
            allDay ? [.year, .month, .day] : [.year, .month, .day, .hour, .minute],
            from: date
        )
        components.timeZone = timeZoneIdentifier == nil ? nil : calendar.timeZone
        return components
    }

    private func validatedURL(_ string: String) throws -> URL {
        guard let url = URL(string: string), let scheme = url.scheme, !scheme.isEmpty else {
            throw ReminderServiceError.invalidURL(string)
        }
        return url
    }

    private func validateAlarmReferences(_ alarms: [ReminderAlarmModel], hasStartDate: Bool) throws {
        for alarm in alarms where alarm.kind == .relative {
            guard hasStartDate else { throw ReminderServiceError.relativeAlarmRequiresStartDate }
            guard let minutes = alarm.minutesBefore, minutes >= 0 else {
                throw ReminderServiceError.invalidAlarm
            }
        }
    }

    private func makeAlarm(_ model: ReminderAlarmModel) throws -> EKAlarm {
        switch model.kind {
        case .relative:
            guard let minutes = model.minutesBefore, minutes >= 0 else { throw ReminderServiceError.invalidAlarm }
            return EKAlarm(relativeOffset: TimeInterval(-minutes * 60))
        case .absolute:
            guard let date = model.absoluteDate else { throw ReminderServiceError.invalidAlarm }
            return EKAlarm(absoluteDate: date)
        case .location:
            guard let location = model.structuredLocation, let proximity = model.proximity else {
                throw ReminderServiceError.invalidAlarm
            }
            let structured = EKStructuredLocation(title: location.title)
            structured.geoLocation = CLLocation(latitude: location.latitude, longitude: location.longitude)
            structured.radius = location.radius
            let alarm = EKAlarm()
            alarm.structuredLocation = structured
            alarm.proximity = proximity == .enter ? .enter : proximity == .leave ? .leave : .none
            return alarm
        }
    }

    private static func mapAlarm(_ alarm: EKAlarm) -> ReminderAlarmModel? {
        if let structured = alarm.structuredLocation, let coordinate = structured.geoLocation?.coordinate {
            let proximity: ReminderAlarmModel.Proximity = switch alarm.proximity {
            case .enter: .enter
            case .leave: .leave
            default: .none
            }
            return .location(
                .init(
                    title: structured.title ?? "",
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude,
                    radius: structured.radius
                ),
                proximity: proximity
            )
        }
        if let date = alarm.absoluteDate { return .absolute(date) }
        return .relative(minutesBefore: Int(-alarm.relativeOffset / 60))
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
    case invalidURL(String)
    case invalidTimeZone(String)
    case invalidAlarm
    case relativeAlarmRequiresStartDate

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
        case .invalidURL(let value):
            return "Invalid URL: '\(value)'"
        case .invalidTimeZone(let identifier):
            return "Unknown time zone: '\(identifier)'"
        case .invalidAlarm:
            return "Invalid alarm definition"
        case .relativeAlarmRequiresStartDate:
            return "Relative alarms require a start date"
        }
    }
}
