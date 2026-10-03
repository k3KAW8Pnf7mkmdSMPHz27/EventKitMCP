import Foundation
@testable import EventKitService

/// Mock implementation of ReminderServiceProtocol for testing
@MainActor
final class MockReminderService: ReminderServiceProtocol {
    var mockLists: [ReminderListModel] = []
    var mockReminders: [ReminderModel] = []

    // Track method calls for verification
    var getRemindersCalled = false
    var lastGetRemindersIncludeDone: Bool?
    var updateRequests: [UpdateReminderRequest] = []

    func requestAccess() async throws -> Bool {
        return true
    }

    func getLists() async throws -> [ReminderListModel] {
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

    // Merge semantics live in ReminderService; handler tests assert the request instead.
    func updateReminder(_ request: UpdateReminderRequest) async throws -> ReminderModel {
        updateRequests.append(request)
        guard let reminder = mockReminders.first(where: { $0.id == request.id }) else {
            throw MockError.notFound
        }
        return reminder
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

    enum MockError: Error {
        case notFound
    }
}
