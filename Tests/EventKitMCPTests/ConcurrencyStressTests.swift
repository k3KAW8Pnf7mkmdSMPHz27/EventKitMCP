import EventKitService
import Foundation
import Logging
import MCP
import Testing
@testable import EventKitMCP

@Suite("Concurrent handler stress tests")
struct ConcurrencyStressTests {
    @Test("One hundred simultaneous reads and writes complete deterministically")
    func simultaneousCalls() async throws {
        let service = ConcurrentReminderService()
        let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for index in 0..<100 {
                group.addTask {
                    let result: CallTool.Result
                    if index.isMultiple(of: 2) {
                        result = await handleToolCall(
                            name: "write_reminders",
                            arguments: ["upsert": .array([.object(["title": .string("Task \(index)")])])],
                            reminderService: service,
                            logger: Logger(label: "stress")
                        )
                    } else {
                        result = await handleToolCall(
                            name: "query_reminders",
                            arguments: nil,
                            reminderService: service,
                            logger: Logger(label: "stress")
                        )
                    }
                    return result.isError != true
                }
            }
            var values: [Bool] = []
            for await value in group { values.append(value) }
            return values
        }

        #expect(results.count == 100)
        #expect(results.allSatisfy { $0 })
        #expect(await service.count == 50)
    }
}

private actor ConcurrentReminderService: ReminderServiceProtocol {
    private var reminders: [ReminderModel] = []
    var count: Int { reminders.count }

    func requestAccess() async throws -> Bool { true }
    func getLists() async throws -> [ReminderListModel] { [] }
    func getList(id: String) async throws -> ReminderListModel? { nil }
    func createList(_ request: CreateListRequest) async throws -> ReminderListModel { throw StressError.unsupported }
    func deleteList(id: String) async throws { throw StressError.unsupported }
    func getReminders(listId: String?, includeDone: Bool) async throws -> [ReminderModel] {
        includeDone ? reminders : reminders.filter { !$0.done }
    }
    func getReminder(id: String) async throws -> ReminderModel? { reminders.first { $0.id == id } }
    func createReminder(_ request: CreateReminderRequest) async throws -> ReminderModel {
        let reminder = ReminderModel(
            id: UUID().uuidString,
            title: request.title,
            notes: request.notes,
            listId: request.listId ?? "default",
            listName: "Default"
        )
        reminders.append(reminder)
        return reminder
    }
    func updateReminder(_ request: UpdateReminderRequest) async throws -> ReminderModel { throw StressError.unsupported }
    func deleteReminder(id: String) async throws -> ReminderModel { throw StressError.unsupported }
    enum StressError: Error { case unsupported }
}
