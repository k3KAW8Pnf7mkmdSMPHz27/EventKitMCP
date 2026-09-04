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

}

actor EventStoreOperationGate {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
        let timeoutTask: Task<Void, Never>
    }

    private var isAcquired = false
    private var waiters: [Waiter] = []

    func acquire(timeout: Duration) async throws {
        try Task.checkCancellation()

        guard isAcquired else {
            isAcquired = true
            return
        }

        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timeoutTask = Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    await self?.failWaiter(id: id, error: ReminderServiceError.operationTimedOut)
                }
                waiters.append(.init(id: id, continuation: continuation, timeoutTask: timeoutTask))
            }
        } onCancel: {
            Task { await self.failWaiter(id: id, error: CancellationError()) }
        }
    }

    func release() {
        guard !waiters.isEmpty else {
            isAcquired = false
            return
        }
        let waiter = waiters.removeFirst()
        waiter.timeoutTask.cancel()
        waiter.continuation.resume()
    }

    private func failWaiter(id: UUID, error: any Error) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.timeoutTask.cancel()
        waiter.continuation.resume(throwing: error)
    }
}

// MARK: - Reminder Service Implementation

/// Service for interacting with Apple Reminders via EventKit
public actor ReminderService: ReminderServiceProtocol {
    private struct PendingReminderFetch {
        let id: UUID
        let continuation: CheckedContinuation<[ReminderModel], any Error>
        var request: Any?
        var timeoutTask: Task<Void, Never>?
    }

    private let eventStore: EKEventStore
    private let logger: Logger
    private let allowedListIds: Set<String>?
    private let operationGate = EventStoreOperationGate()
    private let operationTimeout: Duration
    private var pendingReminderFetch: PendingReminderFetch?

    public init(
        logger: Logger = Logger(label: "eventkit.reminder-service"),
        allowedListIds: Set<String>? = nil,
        operationTimeout: Duration = .seconds(15)
    ) {
        self.eventStore = EKEventStore()
        self.logger = logger
        self.allowedListIds = allowedListIds
        self.operationTimeout = operationTimeout
    }

    // MARK: - Serialized protocol boundary

    public func requestAccess() async throws -> Bool {
        try await withExclusiveEventStoreAccess { try await $0.requestAccessImpl() }
    }

    public func getLists() async throws -> [ReminderListModel] {
        try await withExclusiveEventStoreAccess { try await $0.getListsImpl() }
    }

    public func getList(id: String) async throws -> ReminderListModel? {
        try await withExclusiveEventStoreAccess { try await $0.getListImpl(id: id) }
    }

    public func createList(_ request: CreateListRequest) async throws -> ReminderListModel {
        try await withExclusiveEventStoreAccess { try await $0.createListImpl(request) }
    }

    public func deleteList(id: String) async throws {
        try await withExclusiveEventStoreAccess { try await $0.deleteListImpl(id: id) }
    }

    public func getReminders(listId: String?, includeDone: Bool) async throws -> [ReminderModel] {
        try await withExclusiveEventStoreAccess {
            try await $0.getRemindersImpl(listId: listId, includeDone: includeDone)
        }
    }

    public func getReminder(id: String) async throws -> ReminderModel? {
        try await withExclusiveEventStoreAccess { try await $0.getReminderImpl(id: id) }
    }

    public func createReminder(_ request: CreateReminderRequest) async throws -> ReminderModel {
        try await withExclusiveEventStoreAccess { try await $0.createReminderImpl(request) }
    }

    public func updateReminder(_ request: UpdateReminderRequest) async throws -> ReminderModel {
        try await withExclusiveEventStoreAccess { try await $0.updateReminderImpl(request) }
    }

    @discardableResult
    public func deleteReminder(id: String) async throws -> ReminderModel {
        try await withExclusiveEventStoreAccess { try await $0.deleteReminderImpl(id: id) }
    }

    private func withExclusiveEventStoreAccess<Result: Sendable>(
        _ operation: @Sendable (isolated ReminderService) async throws -> Result
    ) async throws -> Result {
        try await operationGate.acquire(timeout: operationTimeout)
        do {
            let result = try await operation(self)
            await operationGate.release()
            return result
        } catch {
            await operationGate.release()
            throw error
        }
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

    private func requestAccessImpl() async throws -> Bool {
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

    private func getListsImpl() async throws -> [ReminderListModel] {
        let calendars = allowedCalendars()
        return calendars.map { mapCalendarToList($0) }
    }

    private func getListImpl(id: String) async throws -> ReminderListModel? {
        guard isListAllowed(id: id) else {
            throw ReminderServiceError.listAccessDenied(id)
        }
        guard let calendar = eventStore.calendar(withIdentifier: id) else {
            return nil
        }
        return mapCalendarToList(calendar)
    }

    private func createListImpl(_ request: CreateListRequest) async throws -> ReminderListModel {
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

    private func deleteListImpl(id: String) async throws {
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

    private func getRemindersImpl(listId: String?, includeDone: Bool) async throws -> [ReminderModel] {
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

    private func getReminderImpl(id: String) async throws -> ReminderModel? {
        guard let item = eventStore.calendarItem(withIdentifier: id) as? EKReminder else {
            return nil
        }
        // Check if reminder's list is allowed
        guard isListAllowed(id: item.calendar.calendarIdentifier) else {
            throw ReminderServiceError.listAccessDenied(item.calendar.calendarIdentifier)
        }
        return Self.mapReminderToModel(item)
    }

    private func createReminderImpl(_ request: CreateReminderRequest) async throws -> ReminderModel {
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

    private func updateReminderImpl(_ request: UpdateReminderRequest) async throws -> ReminderModel {
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

        switch request.notes {
        case .unchanged:
            break
        case .clear:
            reminder.notes = nil
        case .set(let notes):
            reminder.notes = notes
        }

        if let done = request.done {
            reminder.isCompleted = done
            if done && reminder.completionDate == nil {
                reminder.completionDate = Date()
            }
        }

        switch request.dueDate {
        case .unchanged:
            break
        case .clear:
            reminder.dueDateComponents = nil
        case .set(let value):
            reminder.dueDateComponents = try dateComponents(
                from: value.date,
                allDay: value.isAllDay,
                timeZoneIdentifier: value.timeZoneIdentifier
            )
        }

        switch request.startDate {
        case .unchanged:
            break
        case .clear:
            reminder.startDateComponents = nil
        case .set(let value):
            reminder.startDateComponents = try dateComponents(
                from: value.date,
                allDay: value.isAllDay,
                timeZoneIdentifier: value.timeZoneIdentifier
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

        switch request.location {
        case .unchanged:
            break
        case .clear:
            reminder.location = nil
        case .set(let location):
            reminder.location = location
        }

        switch request.url {
        case .unchanged:
            break
        case .clear:
            reminder.url = nil
        case .set(let urlString):
            reminder.url = try validatedURL(urlString)
        }

        switch request.recurrenceRule {
        case .unchanged:
            break
        case .clear:
            reminder.recurrenceRules?.forEach { reminder.removeRecurrenceRule($0) }
        case .set(let rrule):
            reminder.recurrenceRules?.forEach { reminder.removeRecurrenceRule($0) }
            let ekRule = try RRuleParser.parse(rrule)
            reminder.addRecurrenceRule(ekRule)
        }

        switch request.alarms {
        case .unchanged:
            break
        case .clear:
            reminder.alarms?.forEach { reminder.removeAlarm($0) }
        case .set(let alarms):
            try validateAlarmReferences(alarms, hasStartDate: reminder.startDateComponents != nil)
            reminder.alarms?.forEach { reminder.removeAlarm($0) }
            for alarm in try alarms.map(makeAlarm) { reminder.addAlarm(alarm) }
        }

        try eventStore.save(reminder, commit: true)
        logger.info("Updated reminder", metadata: ["id": "\(request.id)"])

        return Self.mapReminderToModel(reminder)
    }

    @discardableResult
    private func deleteReminderImpl(id: String) async throws -> ReminderModel {
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

    // MARK: - Private Helpers

    private func fetchReminderModels(predicate: NSPredicate) async throws -> [ReminderModel] {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pendingReminderFetch = .init(
                    id: id,
                    continuation: continuation,
                    request: nil,
                    timeoutTask: nil
                )

                let request = eventStore.fetchReminders(matching: predicate) { [weak self] reminders in
                    let models = (reminders ?? []).map(Self.mapReminderToModel)
                    guard let service = self else { return }
                    Task { await service.finishReminderFetch(id: id, result: .success(models)) }
                }
                pendingReminderFetch?.request = request
                pendingReminderFetch?.timeoutTask = Task { [weak self, operationTimeout] in
                    try? await Task.sleep(for: operationTimeout)
                    guard !Task.isCancelled else { return }
                    await self?.finishReminderFetch(
                        id: id,
                        result: .failure(ReminderServiceError.operationTimedOut),
                        cancelRequest: true
                    )
                }
            }
        } onCancel: {
            Task {
                await self.finishReminderFetch(
                    id: id,
                    result: .failure(CancellationError()),
                    cancelRequest: true
                )
            }
        }
    }

    private func finishReminderFetch(
        id: UUID,
        result: Result<[ReminderModel], any Error>,
        cancelRequest: Bool = false
    ) {
        guard let pending = pendingReminderFetch, pending.id == id else { return }
        pendingReminderFetch = nil
        pending.timeoutTask?.cancel()
        if cancelRequest, let request = pending.request {
            eventStore.cancelFetchRequest(request)
        }
        pending.continuation.resume(with: result)
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
        for case .relative(let minutes) in alarms {
            guard hasStartDate else { throw ReminderServiceError.relativeAlarmRequiresStartDate }
            guard minutes >= 0 else { throw ReminderServiceError.invalidAlarm }
        }
    }

    private func makeAlarm(_ model: ReminderAlarmModel) throws -> EKAlarm {
        switch model {
        case .relative(let minutes):
            guard minutes >= 0 else { throw ReminderServiceError.invalidAlarm }
            return EKAlarm(relativeOffset: TimeInterval(-minutes * 60))
        case .absolute(let date):
            return EKAlarm(absoluteDate: date)
        case .location(let location, let proximity):
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
public enum ReminderServiceError: Error, LocalizedError, Equatable {
    case accessDenied
    case listNotFound(String)
    case reminderNotFound(String)
    case noValidSource
    case listAccessDenied(String)
    case listCreationBlocked
    case invalidURL(String)
    case invalidTimeZone(String)
    case invalidAlarm
    case relativeAlarmRequiresStartDate
    case operationTimedOut

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
        case .operationTimedOut:
            return "The EventKit operation timed out"
        }
    }
}
