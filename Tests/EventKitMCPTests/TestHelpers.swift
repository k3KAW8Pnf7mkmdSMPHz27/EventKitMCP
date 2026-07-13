import Foundation
import Logging
import MCP
import Testing

@testable import EventKitMCP
@testable import EventKitService

// MARK: - Shared Test Logger

/// Shared logger for all tests
let testLogger = Logger(label: "test")

// MARK: - CallTool.Result Extensions

extension CallTool.Result {
    /// Extract text content from the first content item
    var textContent: String? {
        guard let first = content.first else { return nil }
        if case .text(let text, _, _) = first {
            return text
        }
        return nil
    }

    /// Assert the result is a success (not an error)
    func expectSuccess(sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(isError == nil || isError == false, sourceLocation: sourceLocation)
    }

    /// Assert the result is an error containing specific text
    func expectError(
        containing text: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(isError == true, "Expected error result", sourceLocation: sourceLocation)
        #expect(
            textContent?.contains(text) == true,
            "Expected error to contain '\(text)', got: \(textContent ?? "nil")",
            sourceLocation: sourceLocation
        )
    }

    /// Assert the result is a success with text containing all specified strings
    func expectText(
        containing texts: String...,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        expectSuccess(sourceLocation: sourceLocation)
        for text in texts {
            #expect(
                textContent?.contains(text) == true,
                "Expected to contain '\(text)', got: \(textContent ?? "nil")",
                sourceLocation: sourceLocation
            )
        }
    }

    /// Assert the result is a success with text NOT containing specified strings
    func expectTextNot(
        containing texts: String...,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        expectSuccess(sourceLocation: sourceLocation)
        for text in texts {
            #expect(
                textContent?.contains(text) != true,
                "Expected NOT to contain '\(text)', but it was found",
                sourceLocation: sourceLocation
            )
        }
    }
}

// MARK: - MockReminderService Extensions

extension MockReminderService {
    /// Configure the mock with standard lists
    func withStandardLists() -> Self {
        self.mockLists = TestFixtures.standardLists
        return self
    }

    /// Configure the mock with a custom set of reminders
    func with(reminders: [ReminderModel]) -> Self {
        self.mockReminders = reminders
        return self
    }

    /// Configure the mock with a custom set of lists
    func with(lists: [ReminderListModel]) -> Self {
        self.mockLists = lists
        return self
    }

    /// Configure with filter test reminders (overdue, today, upcoming, future, basic)
    func withFilterTestReminders() -> Self {
        self.mockReminders = TestFixtures.filterTestReminders
        return self
    }
}

// MARK: - Tool Call Helpers

/// Execute a tool call with minimal boilerplate
func callTool(
    _ name: String,
    arguments: [String: Value]? = nil,
    reminderService: MockReminderService = MockReminderService(),
    readOnly: Bool = false
) async -> CallTool.Result {
    await handleToolCall(
        name: name,
        arguments: arguments,
        reminderService: reminderService,
        logger: testLogger,
        readOnly: readOnly
    )
}

/// Execute query_reminders tool with common defaults
func queryReminders(
    filter: String? = nil,
    search: String? = nil,
    days: Int? = nil,
    listId: String? = nil,
    includeDone: Bool? = nil,
    service: MockReminderService = MockReminderService()
) async -> CallTool.Result {
    var args: [String: Value] = [:]

    if let filter = filter {
        args["filter"] = .string(filter)
    }
    if let search = search {
        args["search"] = .string(search)
    }
    if let days = days {
        args["days"] = .int(days)
    }
    if let listId = listId {
        args["listId"] = .string(listId)
    }
    if let includeDone = includeDone {
        args["includeDone"] = .bool(includeDone)
    }

    return await callTool(
        "query_reminders",
        arguments: args.isEmpty ? nil : args,
        reminderService: service
    )
}

/// Execute manage_reminder_list tool
func manageReminderList(
    action: String,
    title: String? = nil,
    color: String? = nil,
    id: String? = nil,
    service: MockReminderService = MockReminderService(),
    readOnly: Bool = false
) async -> CallTool.Result {
    var args: [String: Value] = ["action": .string(action)]

    if let title = title {
        args["title"] = .string(title)
    }
    if let color = color {
        args["color"] = .string(color)
    }
    if let id = id {
        args["id"] = .string(id)
    }

    return await callTool(
        "manage_reminder_list",
        arguments: args,
        reminderService: service,
        readOnly: readOnly
    )
}

/// Execute overview tool
func getOverview(
    service: MockReminderService = MockReminderService()
) async -> CallTool.Result {
    await callTool("overview", reminderService: service)
}
