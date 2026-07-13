import Foundation
import Logging
import Testing

@testable import EventKitMCP
@testable import EventKitService
import MCP

@Suite("Manage Reminder List Handler Tests")
struct ManageReminderListTests {
    let logger = Logger(label: "test")

    // MARK: - Create action

    @Test("Create action creates a new list")
    func testCreateAction() async throws {
        let mockService = MockReminderService()

        let result = await handleToolCall(
            name: "manage_reminder_list",
            arguments: [
                "action": .string("create"),
                "title": .string("New List")
            ],
            reminderService: mockService,

            logger: logger,
            readOnly: false
        )

        #expect(result.isError == nil || result.isError == false)
        if case .text(let text, _, _) = result.content[0] {
            #expect(text.contains("Created reminder list:"))
            #expect(text.contains("New List"))
        } else {
            Issue.record("Expected text content")
        }

        #expect(mockService.mockLists.count == 1)
        #expect(mockService.mockLists.first?.title == "New List")
    }

    @Test("Create action with color")
    func testCreateActionWithColor() async throws {
        let mockService = MockReminderService()

        let result = await handleToolCall(
            name: "manage_reminder_list",
            arguments: [
                "action": .string("create"),
                "title": .string("Colored List"),
                "color": .string("#FF5733")
            ],
            reminderService: mockService,

            logger: logger,
            readOnly: false
        )

        #expect(result.isError == nil || result.isError == false)
        if case .text(let text, _, _) = result.content[0] {
            #expect(text.contains("Created reminder list:"))
            #expect(text.contains("Colored List"))
        } else {
            Issue.record("Expected text content")
        }

        #expect(mockService.mockLists.first?.color == "#FF5733")
    }

    @Test("Create action requires title")
    func testCreateActionRequiresTitle() async throws {
        let mockService = MockReminderService()

        let result = await handleToolCall(
            name: "manage_reminder_list",
            arguments: [
                "action": .string("create")
            ],
            reminderService: mockService,

            logger: logger,
            readOnly: false
        )

        #expect(result.isError == true)
        if case .text(let text, _, _) = result.content[0] {
            #expect(text.contains("Missing required parameter: title"))
            #expect(text.contains("create action"))
        } else {
            Issue.record("Expected text content")
        }
    }

    // MARK: - Delete action

    @Test("Delete action deletes a list")
    func testDeleteAction() async throws {
        let mockService = MockReminderService()
        mockService.mockLists = [
            ReminderListModel(id: "list-1", title: "To Delete", color: nil, isSubscribed: false, isImmutable: false, sourceTitle: nil)
        ]

        let result = await handleToolCall(
            name: "manage_reminder_list",
            arguments: [
                "action": .string("delete"),
                "id": .string("list-1")
            ],
            reminderService: mockService,

            logger: logger,
            readOnly: false
        )

        #expect(result.isError == nil || result.isError == false)
        if case .text(let text, _, _) = result.content[0] {
            #expect(text.contains("Deleted reminder list: list-1"))
        } else {
            Issue.record("Expected text content")
        }

        #expect(mockService.mockLists.isEmpty)
    }

    @Test("Delete action requires id")
    func testDeleteActionRequiresId() async throws {
        let mockService = MockReminderService()

        let result = await handleToolCall(
            name: "manage_reminder_list",
            arguments: [
                "action": .string("delete")
            ],
            reminderService: mockService,

            logger: logger,
            readOnly: false
        )

        #expect(result.isError == true)
        if case .text(let text, _, _) = result.content[0] {
            #expect(text.contains("Missing required parameter: id"))
            #expect(text.contains("delete action"))
        } else {
            Issue.record("Expected text content")
        }
    }

    // MARK: - Validation

    @Test("Missing action returns error")
    func testMissingAction() async throws {
        let mockService = MockReminderService()

        let result = await handleToolCall(
            name: "manage_reminder_list",
            arguments: nil,
            reminderService: mockService,

            logger: logger,
            readOnly: false
        )

        #expect(result.isError == true)
        if case .text(let text, _, _) = result.content[0] {
            #expect(text.contains("Missing required parameter: action"))
        } else {
            Issue.record("Expected text content")
        }
    }

    @Test("Invalid action returns error")
    func testInvalidAction() async throws {
        let mockService = MockReminderService()

        let result = await handleToolCall(
            name: "manage_reminder_list",
            arguments: [
                "action": .string("update")
            ],
            reminderService: mockService,

            logger: logger,
            readOnly: false
        )

        #expect(result.isError == true)
        if case .text(let text, _, _) = result.content[0] {
            #expect(text.contains("Invalid action: 'update'"))
            #expect(text.contains("'create' or 'delete'"))
        } else {
            Issue.record("Expected text content")
        }
    }

    @Test("Action is case insensitive")
    func testActionCaseInsensitive() async throws {
        let mockService = MockReminderService()

        let result = await handleToolCall(
            name: "manage_reminder_list",
            arguments: [
                "action": .string("CREATE"),
                "title": .string("Test List")
            ],
            reminderService: mockService,

            logger: logger,
            readOnly: false
        )

        #expect(result.isError == nil || result.isError == false)
        #expect(mockService.mockLists.count == 1)
    }

    // MARK: - Read-only mode

    @Test("Blocked in read-only mode")
    func testBlockedInReadOnlyMode() async throws {
        let mockService = MockReminderService()

        let result = await handleToolCall(
            name: "manage_reminder_list",
            arguments: [
                "action": .string("create"),
                "title": .string("Test")
            ],
            reminderService: mockService,

            logger: logger,
            readOnly: true
        )

        #expect(result.isError == true)
        if case .text(let text, _, _) = result.content[0] {
            #expect(text.contains("not allowed in read-only mode"))
        } else {
            Issue.record("Expected text content")
        }

        #expect(mockService.mockLists.isEmpty)
    }

    // MARK: - Color validation

    @Test("Invalid color format returns error")
    func testInvalidColorFormat() async throws {
        let mockService = MockReminderService()

        let result = await handleToolCall(
            name: "manage_reminder_list",
            arguments: [
                "action": .string("create"),
                "title": .string("Test"),
                "color": .string("not-a-color")
            ],
            reminderService: mockService,

            logger: logger,
            readOnly: false
        )

        #expect(result.isError == true)
        if case .text(let text, _, _) = result.content[0] {
            #expect(text.contains("Invalid color format"))
        } else {
            Issue.record("Expected text content")
        }
    }
}
