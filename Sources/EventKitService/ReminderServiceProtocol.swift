import Foundation

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
