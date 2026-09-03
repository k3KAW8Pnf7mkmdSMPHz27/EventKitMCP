import Foundation
@testable import EventKitService

/// Mock implementation of ReminderServiceProtocol for testing
final class MockReminderService: ReminderServiceProtocol, @unchecked Sendable {
    var mockLists: [ReminderListModel] = []
    var mockReminders: [ReminderModel] = []

    // Track method calls for verification
    var getListsCalled = false
    var getRemindersCalled = false
    var lastGetRemindersListId: String?
    var lastGetRemindersIncludeDone: Bool?
    var lastUpdateRequest: UpdateReminderRequest?

    func requestAccess() async throws -> Bool {
        return true
    }

    func getLists() async throws -> [ReminderListModel] {
        getListsCalled = true
        return mockLists
    }

    func getList(id: String) async throws -> ReminderListModel? {
        return mockLists.first { $0.id == id }
    }

    func createList(_ request: CreateListRequest) async throws -> ReminderListModel {
        let list = ReminderListModel(
            id: UUID().uuidString,
            title: request.title,
            color: request.color,
            isSubscribed: false,
            isImmutable: false,
            sourceTitle: nil
        )
        mockLists.append(list)
        return list
    }

    func deleteList(id: String) async throws {
        mockLists.removeAll { $0.id == id }
    }

    func getReminders(listId: String?, includeDone: Bool) async throws -> [ReminderModel] {
        getRemindersCalled = true
        lastGetRemindersListId = listId
        lastGetRemindersIncludeDone = includeDone

        var result = mockReminders
        if let listId = listId {
            result = result.filter { $0.listId == listId }
        }
        if !includeDone {
            result = result.filter { !$0.done }
        }
        return result
    }

    func getReminder(id: String) async throws -> ReminderModel? {
        return mockReminders.first { $0.id == id }
    }

    func createReminder(_ request: CreateReminderRequest) async throws -> ReminderModel {
        let reminder = ReminderModel(
            id: UUID().uuidString,
            title: request.title,
            notes: request.notes,
            done: false,
            priority: request.priority ?? .none,
            dueDate: request.dueDate,
            dueTimeZone: request.dueTimeZone,
            isAllDay: request.isAllDay,
            listId: request.listId ?? "default",
            listName: "Default",
            recurrenceRule: request.recurrenceRule,
            url: request.url,
            location: request.location,
            startDate: request.startDate,
            startTimeZone: request.startTimeZone,
            isStartAllDay: request.isStartAllDay,
            alarms: request.alarms
        )
        mockReminders.append(reminder)
        return reminder
    }

    func updateReminder(_ request: UpdateReminderRequest) async throws -> ReminderModel {
        lastUpdateRequest = request
        guard let index = mockReminders.firstIndex(where: { $0.id == request.id }) else {
            throw MockError.notFound
        }
        let existing = mockReminders[index]

        // Handle recurrence: remove if requested, otherwise update if provided or keep existing
        let newRecurrence: String?
        if request.removeRecurrence {
            newRecurrence = nil
        } else if let rrule = request.recurrenceRule {
            newRecurrence = rrule
        } else {
            newRecurrence = existing.recurrenceRule
        }

        // Handle start date: remove if requested, otherwise update if provided or keep existing
        let newStartDate: Date?
        let newIsStartAllDay: Bool
        if request.removeStartDate {
            newStartDate = nil
            newIsStartAllDay = false
        } else if let startDate = request.startDate {
            newStartDate = startDate
            newIsStartAllDay = request.isStartAllDay ?? false
        } else {
            newStartDate = existing.startDate
            newIsStartAllDay = request.isStartAllDay ?? existing.isStartAllDay
        }

        // Handle alarms: remove if requested, otherwise update if provided or keep existing
        let newAlarms: [ReminderAlarmModel]?
        if request.removeAlarms {
            newAlarms = nil
        } else if let alarms = request.alarms {
            newAlarms = alarms
        } else {
            newAlarms = existing.alarms
        }
        if newAlarms?.contains(where: { $0.kind == .relative }) == true,
           newStartDate == nil {
            throw MockError.invalidAlarm
        }

        let newNotes = request.removeNotes ? nil : (request.notes ?? existing.notes)
        let newDueDate = request.removeDueDate ? nil : (request.dueDate ?? existing.dueDate)
        let newDueTimeZone = request.removeDueDate ? nil : (request.dueTimeZone ?? existing.dueTimeZone)
        let newLocation = request.removeLocation ? nil : (request.location ?? existing.location)
        let newURL = request.removeURL ? nil : (request.url ?? existing.url)

        let updated = ReminderModel(
            id: existing.id,
            title: request.title ?? existing.title,
            notes: newNotes,
            done: request.done ?? existing.done,
            priority: request.priority ?? existing.priority,
            dueDate: newDueDate,
            dueTimeZone: newDueTimeZone,
            isAllDay: request.isAllDay ?? existing.isAllDay,
            listId: request.listId ?? existing.listId,
            listName: existing.listName,
            recurrenceRule: newRecurrence,
            url: newURL,
            location: newLocation,
            startDate: newStartDate,
            startTimeZone: request.removeStartDate ? nil : (request.startTimeZone ?? existing.startTimeZone),
            isStartAllDay: newIsStartAllDay,
            alarms: newAlarms
        )
        mockReminders[index] = updated
        return updated
    }

    @discardableResult
    func deleteReminder(id: String) async throws -> ReminderModel {
        guard let index = mockReminders.firstIndex(where: { $0.id == id }) else {
            throw MockError.notFound
        }
        let reminder = mockReminders[index]
        mockReminders.remove(at: index)
        return reminder
    }

    func markDone(id: String) async throws -> ReminderModel {
        guard let index = mockReminders.firstIndex(where: { $0.id == id }) else {
            throw MockError.notFound
        }
        let existing = mockReminders[index]
        let updated = ReminderModel(
            id: existing.id,
            title: existing.title,
            notes: existing.notes,
            done: true,
            priority: existing.priority,
            dueDate: existing.dueDate,
            isAllDay: existing.isAllDay,
            doneDate: Date(),
            listId: existing.listId,
            listName: existing.listName,
            creationDate: existing.creationDate,
            lastModifiedDate: existing.lastModifiedDate,
            recurrenceRule: existing.recurrenceRule,
            url: existing.url,
            location: existing.location,
            startDate: existing.startDate,
            startTimeZone: existing.startTimeZone,
            isStartAllDay: existing.isStartAllDay,
            alarms: existing.alarms
        )
        mockReminders[index] = updated
        return updated
    }

    func moveReminder(id: String, toListId: String) async throws -> ReminderModel {
        guard let index = mockReminders.firstIndex(where: { $0.id == id }) else {
            throw MockError.notFound
        }
        let existing = mockReminders[index]
        let updated = ReminderModel(
            id: existing.id,
            title: existing.title,
            notes: existing.notes,
            done: existing.done,
            priority: existing.priority,
            dueDate: existing.dueDate,
            isAllDay: existing.isAllDay,
            listId: toListId,
            listName: mockLists.first { $0.id == toListId }?.title ?? "Unknown",
            creationDate: existing.creationDate,
            lastModifiedDate: existing.lastModifiedDate,
            recurrenceRule: existing.recurrenceRule,
            url: existing.url,
            location: existing.location,
            startDate: existing.startDate,
            startTimeZone: existing.startTimeZone,
            isStartAllDay: existing.isStartAllDay,
            alarms: existing.alarms
        )
        mockReminders[index] = updated
        return updated
    }

    enum MockError: Error {
        case notFound
        case invalidAlarm
    }
}
