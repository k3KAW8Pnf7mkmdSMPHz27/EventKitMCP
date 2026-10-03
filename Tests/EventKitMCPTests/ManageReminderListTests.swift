import Foundation
import Testing

@testable import EventKitMCP
@testable import EventKitService
import MCP

@MainActor
@Suite("Manage Reminder List Handler Tests")
struct ManageReminderListTests {

    // MARK: - Create action

    @Test("Create action creates a new list")
    func testCreateAction() async throws {
        let service = MockReminderService()

        let result = await manageReminderList(action: "create", title: "New List", service: service)

        result.expectText(containing: "Created reminder list:", "New List")

        #expect(service.mockLists.count == 1)
        #expect(service.mockLists.first?.title == "New List")
    }

    @Test("Create action with color")
    func testCreateActionWithColor() async throws {
        let service = MockReminderService()

        let result = await manageReminderList(
            action: "create",
            title: "Colored List",
            color: "#FF5733",
            service: service
        )

        result.expectText(containing: "Created reminder list:", "Colored List")

        #expect(service.mockLists.first?.color == "#FF5733")
    }

    @Test("Create action requires title")
    func testCreateActionRequiresTitle() async throws {
        let service = MockReminderService()

        let result = await manageReminderList(action: "create", service: service)

        result.expectError(containing: "Missing required parameter: title")
        #expect(result.textContent?.contains("create action") == true)
    }

    // MARK: - Delete action

    @Test("Delete action deletes a list")
    func testDeleteAction() async throws {
        let service = MockReminderService()
        service.mockLists = [
            ReminderListModel(id: "list-1", title: "To Delete")
        ]

        let result = await manageReminderList(action: "delete", id: "list-1", service: service)

        result.expectText(containing: "Deleted reminder list: list-1")

        #expect(service.mockLists.isEmpty)
    }

    @Test("Delete action requires id")
    func testDeleteActionRequiresId() async throws {
        let service = MockReminderService()

        let result = await manageReminderList(action: "delete", service: service)

        result.expectError(containing: "Missing required parameter: id")
        #expect(result.textContent?.contains("delete action") == true)
    }

    // MARK: - Validation

    @Test("Missing action returns error")
    func testMissingAction() async throws {
        let service = MockReminderService()

        let result = await callTool("manage_reminder_list", reminderService: service)

        result.expectError(containing: "Missing required parameter: action")
    }

    @Test("Invalid action returns error")
    func testInvalidAction() async throws {
        let service = MockReminderService()

        let result = await manageReminderList(action: "update", service: service)

        result.expectError(containing: "Invalid action: 'update'")
        #expect(result.textContent?.contains("'create' or 'delete'") == true)
    }

    @Test("Action must match the advertised enum")
    func testActionMustMatchSchemaEnum() async throws {
        let service = MockReminderService()

        let result = await manageReminderList(action: "CREATE", title: "Test List", service: service)

        #expect(result.isError == true)
        #expect(service.mockLists.isEmpty)
    }
}
