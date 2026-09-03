import Foundation
import JSONSchema
import MCP
import Testing
@testable import EventKitMCP

@Suite("Tool schema contract tests")
struct ToolSchemaContractTests {
    @Test("Every tool advertises an output schema and successful output validates")
    func allSuccessfulResultsValidate() async throws {
        let service = MockReminderService()
        service.mockLists = [TestFixtures.workList]
        service.mockReminders = [TestFixtures.basicTask]

        let calls: [(String, [String: Value]?)] = [
            ("query_reminders", nil),
            ("write_reminders", [
                "upsert": .array([.object(["title": .string("Contract test")])])
            ]),
            ("get_reminder_lists", nil),
            ("manage_reminder_list", [
                "action": .string("create"),
                "title": .string("Contract list")
            ]),
            ("overview", nil)
        ]

        let tools = ToolRegistry.allTools()
        #expect(tools.count == 5)

        for (name, arguments) in calls {
            let tool = try #require(tools.first { $0.name == name })
            let outputSchema = try #require(tool.outputSchema)
            let result = await callTool(name, arguments: arguments, reminderService: service)
            #expect(result.isError != true)
            let structuredContent = try #require(result.structuredContent)
            #expect(try validates(structuredContent, against: outputSchema), "Invalid structured output for \(name)")
            #expect(!result.content.isEmpty)
        }
    }

    @Test("Read-only registry exposes only query, lists, and overview")
    func readOnlyTools() {
        #expect(Set(ToolRegistry.allTools(readOnly: true).map(\.name)) == [
            "query_reminders", "get_reminder_lists", "overview"
        ])
    }

    @Test("Generated input schemas expose enum and expanded reminder fields")
    func inputContracts() throws {
        let encoder = JSONEncoder()
        let tools = ToolRegistry.allTools()
        let query = try #require(tools.first { $0.name == "query_reminders" })
        let write = try #require(tools.first { $0.name == "write_reminders" })
        let manage = try #require(tools.first { $0.name == "manage_reminder_list" })
        let queryJSON = String(decoding: try encoder.encode(query.inputSchema), as: UTF8.self)
        let writeJSON = String(decoding: try encoder.encode(write.inputSchema), as: UTF8.self)
        let manageJSON = String(decoding: try encoder.encode(manage.inputSchema), as: UTF8.self)

        for value in ["all", "overdue", "today", "upcoming"] { #expect(queryJSON.contains(value)) }
        for field in ["location", "url", "startDate", "startTimeZone", "dueTimeZone", "alarms"] {
            #expect(writeJSON.contains(field))
        }
        for value in ["none", "low", "medium", "high"] { #expect(writeJSON.contains(value)) }
        #expect(manageJSON.contains("create"))
        #expect(manageJSON.contains("delete"))
    }

    private func validates(_ instance: Value, against schemaValue: Value) throws -> Bool {
        let encoder = JSONEncoder()
        let schemaJSON = String(decoding: try encoder.encode(schemaValue), as: UTF8.self)
        let instanceJSON = String(decoding: try encoder.encode(instance), as: UTF8.self)
        return try Schema(instance: schemaJSON).validate(instance: instanceJSON).isValid
    }
}
