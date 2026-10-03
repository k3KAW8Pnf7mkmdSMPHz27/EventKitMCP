import EventKit
import Foundation

extension ReminderService {
    // MARK: - Reminders

    func getRemindersImpl(listId: String?, includeDone: Bool) async throws -> [ReminderModel] {
        let calendars: [EKCalendar]

        if let listId = listId {
            calendars = [try calendarInAllowlist(id: listId)]
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

    func createReminderImpl(_ request: CreateReminderRequest) async throws -> ReminderModel {
        let reminder = EKReminder(eventStore: eventStore)
        reminder.title = request.title
        reminder.notes = request.notes
        if request.done {
            reminder.isCompleted = true
        }

        // Set the calendar (list)
        if let listId = request.listId {
            reminder.calendar = try calendarInAllowlist(id: listId)
        } else {
            // Use default calendar, but verify it's allowed
            guard let defaultCal = reminderStore.defaultCalendarForNewReminders() else {
                throw ReminderServiceError.noValidSource
            }
            guard isListAllowed(id: defaultCal.calendarIdentifier) else {
                throw ReminderServiceError.defaultListNotAllowed
            }
            reminder.calendar = defaultCal
        }

        if let dueDate = request.dueDate {
            reminder.dueDateComponents = try EventKitMapping.dateComponents(
                from: ReminderDateValue(
                    date: dueDate, timeZoneIdentifier: request.dueTimeZone, isAllDay: request.isAllDay)
            )
        }
        if let startDate = request.startDate {
            reminder.startDateComponents = try EventKitMapping.dateComponents(
                from: ReminderDateValue(
                    date: startDate, timeZoneIdentifier: request.startTimeZone, isAllDay: request.isStartAllDay)
            )
        }
        if let priority = request.priority {
            reminder.priority = priority.rawValue
        }
        if let location = request.location {
            reminder.location = location
        }
        if let urlString = request.url {
            reminder.url = try EventKitMapping.validatedURL(urlString)
        }
        if let rrule = request.recurrenceRule {
            reminder.addRecurrenceRule(try RRuleParser.parse(rrule))
        }
        if let alarms = request.alarms {
            let ekAlarms = try EventKitMapping.makeAlarms(alarms, hasStartDate: reminder.startDateComponents != nil)
            for alarm in ekAlarms { reminder.addAlarm(alarm) }
        }

        try reminderStore.save(reminder, commit: true)
        logger.info("Created reminder", metadata: ["title": "\(request.title)"])

        return EventKitMapping.mapReminderToModel(reminder)
    }

    func updateReminderImpl(_ request: UpdateReminderRequest) async throws -> ReminderModel {
        let reminder = try reminderInAllowlist(id: request.id)

        if let title = request.title {
            reminder.title = title
        }
        request.notes.apply { reminder.notes = $0 }
        // Setting isCompleted to true restamps completionDate, so only write a change.
        if let done = request.done, done != reminder.isCompleted {
            reminder.isCompleted = done
        }
        try request.dueDate.apply { reminder.dueDateComponents = try $0.map(EventKitMapping.dateComponents) }
        try request.startDate.apply { reminder.startDateComponents = try $0.map(EventKitMapping.dateComponents) }
        if let priority = request.priority {
            reminder.priority = priority.rawValue
        }
        if let listId = request.listId {
            reminder.calendar = try calendarInAllowlist(id: listId)
        }
        request.location.apply { reminder.location = $0 }
        try request.url.apply { reminder.url = try $0.map(EventKitMapping.validatedURL) }
        try request.recurrenceRule.apply { rrule in
            for rule in reminder.recurrenceRules ?? [] { reminder.removeRecurrenceRule(rule) }
            if let rrule { reminder.addRecurrenceRule(try RRuleParser.parse(rrule)) }
        }
        // Alarms come last: relative ones need the start date this request may have just set.
        try request.alarms.apply { alarms in
            let ekAlarms = try alarms.map {
                try EventKitMapping.makeAlarms($0, hasStartDate: reminder.startDateComponents != nil)
            }
            for alarm in reminder.alarms ?? [] { reminder.removeAlarm(alarm) }
            for alarm in ekAlarms ?? [] { reminder.addAlarm(alarm) }
        }

        try reminderStore.save(reminder, commit: true)
        logger.info("Updated reminder", metadata: ["id": "\(request.id)"])

        return EventKitMapping.mapReminderToModel(reminder)
    }

    @discardableResult
    func deleteReminderImpl(id: String) async throws -> ReminderModel {
        let reminder = try reminderInAllowlist(id: id)

        // Capture reminder data before deletion
        let model = EventKitMapping.mapReminderToModel(reminder)

        try reminderStore.remove(reminder, commit: true)
        logger.info("Deleted reminder", metadata: ["id": "\(id)"])

        return model
    }
}
