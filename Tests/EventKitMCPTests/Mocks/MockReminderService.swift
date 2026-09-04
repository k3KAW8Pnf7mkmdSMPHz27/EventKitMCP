import Foundation
@testable import EventKitService

/// Mock implementation of ReminderServiceProtocol for testing
@MainActor
final class MockReminderService: ReminderServiceProtocol {
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

        let existingDueDate = existing.dueDate.map {
            ReminderDateValue(date: $0, timeZoneIdentifier: existing.dueTimeZone, isAllDay: existing.isAllDay)
        }
        let existingStartDate = existing.startDate.map {
            ReminderDateValue(
                date: $0,
                timeZoneIdentifier: existing.startTimeZone,
                isAllDay: existing.isStartAllDay
            )
        }
        let newDueDate = request.dueDate.applying(to: existingDueDate)
        let newStartDate = request.startDate.applying(to: existingStartDate)
        let newAlarms = request.alarms.applying(to: existing.alarms)
        if newAlarms?.contains(where: { $0.kind == .relative }) == true,
           newStartDate == nil {
            throw MockError.invalidAlarm
        }

        let updated = ReminderModel(
            id: existing.id,
            title: request.title ?? existing.title,
            notes: request.notes.applying(to: existing.notes),
            done: request.done ?? existing.done,
            priority: request.priority ?? existing.priority,
            dueDate: newDueDate?.date,
            dueTimeZone: newDueDate?.timeZoneIdentifier,
            isAllDay: newDueDate?.isAllDay ?? false,
            listId: request.listId ?? existing.listId,
            listName: existing.listName,
            recurrenceRule: request.recurrenceRule.applying(to: existing.recurrenceRule),
            url: request.url.applying(to: existing.url),
            location: request.location.applying(to: existing.location),
            startDate: newStartDate?.date,
            startTimeZone: newStartDate?.timeZoneIdentifier,
            isStartAllDay: newStartDate?.isAllDay ?? false,
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

private extension ReminderFieldUpdate {
    func applying(to currentValue: Value?) -> Value? {
        switch self {
        case .unchanged: currentValue
        case .clear: nil
        case .set(let value): value
        }
    }
}
