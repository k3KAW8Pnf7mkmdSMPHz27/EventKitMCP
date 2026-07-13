import Foundation
import Logging
import Testing

@testable import EventKitMCP
@testable import EventKitService
import MCP

@Suite("Input Validation Tests")
struct InputValidationTests {

    // MARK: - Filter Validation Tests

    @Test("query_reminders with valid filter succeeds")
    func testValidFilter() async throws {
        for filter in ["all", "overdue", "today", "upcoming"] {
            let result = await queryReminders(filter: filter)
            result.expectSuccess()
        }
    }

    @Test("query_reminders with invalid filter returns error")
    func testInvalidFilter() async throws {
        let result = await queryReminders(filter: "tomorrow")
        result.expectError(containing: "Invalid filter")
        #expect(result.textContent?.contains("tomorrow") == true)
        #expect(result.textContent?.contains("'all', 'overdue', 'today', or 'upcoming'") == true)
    }

    // MARK: - Days Validation Tests

    @Test("query_reminders with valid days succeeds")
    func testValidDays() async throws {
        let result = await queryReminders(filter: "upcoming", days: 14)
        result.expectSuccess()
    }

    @Test("query_reminders with string days returns error")
    func testInvalidDaysString() async throws {
        let result = await callTool(
            "query_reminders",
            arguments: [
                "filter": .string("upcoming"),
                "days": .string("seven")
            ]
        )
        result.expectError(containing: "Invalid days value")
        #expect(result.textContent?.contains("seven") == true)
    }

    @Test("query_reminders with zero days returns error")
    func testInvalidDaysZero() async throws {
        let result = await queryReminders(filter: "upcoming", days: 0)
        result.expectError(containing: "Invalid days value")
        #expect(result.textContent?.contains("positive integer") == true)
    }

    @Test("query_reminders with negative days returns error")
    func testInvalidDaysNegative() async throws {
        let result = await queryReminders(filter: "upcoming", days: -5)
        result.expectError(containing: "Invalid days value")
    }

    // MARK: - Color Validation Tests

    @Test("manage_reminder_list create with valid hex color succeeds")
    func testValidColorWithHash() async throws {
        let result = await manageReminderList(
            action: "create",
            title: "Test List",
            color: "#FF5733"
        )
        result.expectSuccess()
    }

    @Test("manage_reminder_list create with hex color without hash succeeds")
    func testValidColorWithoutHash() async throws {
        let result = await manageReminderList(
            action: "create",
            title: "Test List",
            color: "FF5733"
        )
        result.expectSuccess()
    }

    @Test("manage_reminder_list create with color name returns error")
    func testInvalidColorName() async throws {
        let result = await manageReminderList(
            action: "create",
            title: "Test List",
            color: "red"
        )
        result.expectError(containing: "Invalid color format")
        #expect(result.textContent?.contains("red") == true)
        #expect(result.textContent?.contains("hex format") == true)
    }

    @Test("manage_reminder_list create with short hex returns error")
    func testInvalidColorShortHex() async throws {
        let result = await manageReminderList(
            action: "create",
            title: "Test List",
            color: "#F53"
        )
        result.expectError(containing: "Invalid color format")
    }

    @Test("manage_reminder_list create without color succeeds")
    func testNoColorProvided() async throws {
        let result = await manageReminderList(action: "create", title: "Test List")
        result.expectSuccess()
    }
}
