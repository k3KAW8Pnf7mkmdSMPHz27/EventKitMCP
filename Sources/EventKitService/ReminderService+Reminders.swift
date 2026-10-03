import EventKit
import Foundation

extension ReminderService {
    // MARK: - Reminders

    func getRemindersImpl(listId: String?, includeDone: Bool) async throws -> [ReminderModel] {
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
            guard let allowed = queryableCalendars() else { return [] }
            calendars = allowed
        }

        let predicate =
            includeDone
            ? reminderStore.predicateForReminders(in: calendars)
            : reminderStore.predicateForIncompleteReminders(
                withDueDateStarting: nil,
                ending: nil,
                calendars: calendars
            )
        return try await fetchReminderModels(predicate: predicate)
    }

    func getReminderImpl(id: String) async throws -> ReminderModel? {
        guard let item = eventStore.calendarItem(withIdentifier: id) as? EKReminder else {
            return nil
        }
        // Report an out-of-allowlist reminder exactly as a missing one. Throwing here
        // while a nonexistent ID returns nil would confirm that a reminder exists
        // outside the caller's permitted lists.
        guard isListAllowed(id: item.calendar.calendarIdentifier) else {
            return nil
        }
        return EventKitMapping.mapReminderToModel(item)
    }

    func createReminderImpl(_ request: CreateReminderRequest) async throws -> ReminderModel {
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
            reminder.dueDateComponents = try EventKitMapping.dateComponents(
                from: dueDate,
                allDay: request.isAllDay,
                timeZoneIdentifier: request.dueTimeZone
            )
        }

        // Set start date
        if let startDate = request.startDate {
            reminder.startDateComponents = try EventKitMapping.dateComponents(
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
            reminder.url = try EventKitMapping.validatedURL(urlString)
        }

        // Set recurrence rule
        if let rrule = request.recurrenceRule {
            let ekRule = try RRuleParser.parse(rrule)
            reminder.addRecurrenceRule(ekRule)
        }

        // Set alarms
        if let alarms = request.alarms {
            try EventKitMapping.validateAlarmReferences(alarms, hasStartDate: reminder.startDateComponents != nil)
            for alarm in try alarms.map(EventKitMapping.makeAlarm) { reminder.addAlarm(alarm) }
        }

        try eventStore.save(reminder, commit: true)
        logger.info("Created reminder", metadata: ["title": "\(request.title)"])

        return EventKitMapping.mapReminderToModel(reminder)
    }

    func updateReminderImpl(_ request: UpdateReminderRequest) async throws -> ReminderModel {
        guard let reminder = eventStore.calendarItem(withIdentifier: request.id) as? EKReminder else {
            throw ReminderServiceError.reminderNotFound(request.id)
        }

        // Verify current list is allowed, without disclosing which list holds it.
        guard isListAllowed(id: reminder.calendar.calendarIdentifier) else {
            throw ReminderServiceError.reminderAccessDenied(request.id)
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
            reminder.dueDateComponents = try EventKitMapping.dateComponents(
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
            reminder.startDateComponents = try EventKitMapping.dateComponents(
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
            reminder.url = try EventKitMapping.validatedURL(urlString)
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
            try EventKitMapping.validateAlarmReferences(alarms, hasStartDate: reminder.startDateComponents != nil)
            reminder.alarms?.forEach { reminder.removeAlarm($0) }
            for alarm in try alarms.map(EventKitMapping.makeAlarm) { reminder.addAlarm(alarm) }
        }

        try eventStore.save(reminder, commit: true)
        logger.info("Updated reminder", metadata: ["id": "\(request.id)"])

        return EventKitMapping.mapReminderToModel(reminder)
    }

    @discardableResult
    func deleteReminderImpl(id: String) async throws -> ReminderModel {
        guard let reminder = eventStore.calendarItem(withIdentifier: id) as? EKReminder else {
            throw ReminderServiceError.reminderNotFound(id)
        }

        guard isListAllowed(id: reminder.calendar.calendarIdentifier) else {
            throw ReminderServiceError.reminderAccessDenied(id)
        }

        // Capture reminder data before deletion
        let model = EventKitMapping.mapReminderToModel(reminder)

        try eventStore.remove(reminder, commit: true)
        logger.info("Deleted reminder", metadata: ["id": "\(id)"])

        return model
    }
}
