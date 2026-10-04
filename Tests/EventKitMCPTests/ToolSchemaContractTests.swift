import Foundation
import JSONSchema
import MCP
import Testing
@testable import EventKitMCP
@testable import EventKitService

@MainActor
@Suite("Tool schema contract tests")
struct ToolSchemaContractTests {
    @Test("Every tool advertises an output schema and successful output validates")
    func allSuccessfulResultsValidate() async throws {
        let service = MockReminderService()
        service.mockLists = [TestFixtures.workList]
        service.mockReminders = [
            ReminderModel(
                id: "contract-reminder",
                title: "Contract reminder",
                dueDate: TestFixtures.todayNoon,
                dueTimeZone: "America/Chicago",
                listId: TestFixtures.workList.id,
                listName: TestFixtures.workList.title,
                startDate: TestFixtures.todayNoon,
                startTimeZone: "America/Chicago",
                alarms: [
                    .relative(minutesBefore: 15),
                    .absolute(TestFixtures.todayNoon),
                    .location(
                        .init(title: "Office", latitude: 41.8781, longitude: -87.6298, radius: 100),
                        proximity: .enter
                    )
                ]
            )
        ]

        let tools = ToolRegistry.allTools()
        #expect(tools.count == Self.calls.count)

        for (name, arguments) in Self.calls {
            let tool = try #require(tools.first { $0.name == name })
            let outputSchema = try #require(tool.outputSchema)
            let result = await callTool(name, arguments: arguments, reminderService: service)
            #expect(result.isError != true)
            let structuredContent = try #require(result.structuredContent)
            #expect(try validates(structuredContent, against: outputSchema), "Invalid structured output for \(name)")
            #expect(!result.content.isEmpty)
        }
    }

    @Test("Read-only mode refuses every mutating tool before it reaches the service")
    func readOnlyRefusesMutations() async {
        for (name, arguments) in Self.calls where ToolRegistry.mutatingTools.contains(name) {
            let service = MockReminderService()
            let result = await callTool(name, arguments: arguments, reminderService: service, readOnly: true)
            result.expectError(containing: "not allowed in read-only mode")
            #expect(service.mockLists.isEmpty && service.mockReminders.isEmpty, "\(name) reached the service")
        }
    }

    @Test("Read-only mode still serves every read-only tool")
    func readOnlyServesReads() async {
        for (name, arguments) in Self.calls where !ToolRegistry.mutatingTools.contains(name) {
            let result = await callTool(name, arguments: arguments, readOnly: true)
            result.expectSuccess()
        }
    }

    @Test("Read-only registry exposes only query, lists, and overview")
    func readOnlyTools() {
        #expect(
            Set(ToolRegistry.allTools(readOnly: true).map(\.name)) == [
                "query_reminders", "get_reminder_lists", "overview"
            ])
    }

    @Test("Every tool declares a mutation stance, and the read-only gate matches it")
    func mutationStanceIsDeclaredAndEnforced() {
        // The gate is derived from `readOnlyHint`, so a tool that declares neither
        // readOnlyHint nor destructiveHint would be classified by omission rather than
        // intent. Require the stance to be explicit.
        for tool in ToolRegistry.allTools() {
            let isReadOnly = tool.annotations.readOnlyHint == true
            let isDestructive = tool.annotations.destructiveHint == true
            #expect(
                isReadOnly != isDestructive,
                "\(tool.name) must declare exactly one of readOnlyHint or destructiveHint"
            )
            #expect(ToolRegistry.mutatingTools.contains(tool.name) == !isReadOnly)
        }

        // Read-only listing and the call guard must agree on every tool.
        let exposed = Set(ToolRegistry.allTools(readOnly: true).map(\.name))
        #expect(exposed.isDisjoint(with: ToolRegistry.mutatingTools))
    }

    @Test("Tool contract matches the checked-in snapshot")
    func toolContractMatchesSnapshot() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        let actual = String(decoding: try encoder.encode(ToolRegistry.allTools()), as: UTF8.self) + "\n"
        let snapshot = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Contract/tool-contract.json")

        if ProcessInfo.processInfo.environment["UPDATE_TOOL_CONTRACT"] == "1" {
            try actual.write(to: snapshot, atomically: true, encoding: .utf8)
            return
        }

        let expected = try String(contentsOf: snapshot, encoding: .utf8)
        guard actual != expected else { return }
        let actualLines = actual.split(separator: "\n", omittingEmptySubsequences: false)
        let expectedLines = expected.split(separator: "\n", omittingEmptySubsequences: false)
        let line =
            zip(actualLines, expectedLines).enumerated().first { $1.0 != $1.1 }?.offset
            ?? min(actualLines.count, expectedLines.count)
        let was = line < expectedLines.count ? String(expectedLines[line]) : "<end of file>"
        let now = line < actualLines.count ? String(actualLines[line]) : "<end of file>"
        Issue.record(
            """
            Tool contract changed at tool-contract.json:\(line + 1)
              snapshot: \(was)
              current:  \(now)
            Rerun with UPDATE_TOOL_CONTRACT=1 and review the diff; it decides the PR title.
            """)
    }

    @Test("README names every tool and every input property")
    func readmeNamesEveryToolAndInputProperty() throws {
        let readme = try String(
            contentsOf: URL(filePath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appending(path: "README.md"),
            encoding: .utf8
        )
        for tool in ToolRegistry.allTools() {
            #expect(readme.contains("`\(tool.name)`"), "README does not name \(tool.name)")
            for name in Self.propertyNames(tool.inputSchema).sorted() {
                #expect(
                    readme.contains("`\(name)`") || readme.contains("\"\(name)\""),
                    "README does not name \(tool.name) input \(name)"
                )
            }
        }
    }

    @Test("Representative inputs validate against their advertised schemas")
    func representativeInputsValidate() throws {
        let tools = ToolRegistry.allTools()
        let query = try #require(tools.first { $0.name == "query_reminders" })
        let write = try #require(tools.first { $0.name == "write_reminders" })
        let manage = try #require(tools.first { $0.name == "manage_reminder_list" })

        #expect(
            try validates(
                .object([
                    "filter": .string("upcoming"),
                    "days": .int(14),
                    "limit": .int(25),
                    "offset": .int(0),
                    "search": .string("release|follow-up")
                ]), against: query.inputSchema))
        #expect(
            try validates(
                .object([
                    "upsert": .array([
                        .object([
                            "title": .string("Call the office"),
                            "startDate": .string("2026-09-04T14:00:00-05:00"),
                            "alarms": .array([
                                .object([
                                    "kind": .string("relative"),
                                    "minutesBefore": .int(15)
                                ])
                            ])
                        ])
                    ])
                ]), against: write.inputSchema))
        #expect(
            try validates(
                .object([
                    "action": .string("create"),
                    "title": .string("Work")
                ]), against: manage.inputSchema))

        #expect(
            try !validates(
                .object([
                    "upsert": .array([
                        .object([
                            "title": .string("Invalid alarm"),
                            "alarms": .array([.object(["kind": .string("sometimes")])])
                        ])
                    ])
                ]), against: write.inputSchema))
        #expect(
            try !validates(
                .object([
                    "upsert": .array([
                        .object([
                            "title": .string("Legacy alarm shorthand"),
                            "alarms": .array([.int(15)])
                        ])
                    ])
                ]), against: write.inputSchema))
    }

    /// One minimal valid call per tool.
    private static let calls: [(String, [String: Value]?)] = [
        ("query_reminders", nil),
        (
            "write_reminders",
            [
                "upsert": .array([.object(["title": .string("Contract test")])])
            ]
        ),
        ("get_reminder_lists", nil),
        (
            "manage_reminder_list",
            [
                "action": .string("create"),
                "title": .string("Contract list")
            ]
        ),
        ("overview", nil)
    ]

    /// Every property name in a schema, including nested objects and array items.
    private static func propertyNames(_ schema: Value) -> Set<String> {
        guard case .object(let object) = schema else { return [] }
        var names: Set<String> = []
        if case .object(let properties)? = object["properties"] {
            for (name, child) in properties {
                names.insert(name)
                names.formUnion(propertyNames(child))
            }
        }
        for key in ["items", "additionalProperties"] {
            if let child = object[key] { names.formUnion(propertyNames(child)) }
        }
        for key in ["anyOf", "oneOf", "allOf"] {
            if case .array(let children)? = object[key] {
                for child in children { names.formUnion(propertyNames(child)) }
            }
        }
        return names
    }

    private func validates(_ instance: Value, against schemaValue: Value) throws -> Bool {
        let encoder = JSONEncoder()
        let schemaJSON = String(decoding: try encoder.encode(schemaValue), as: UTF8.self)
        let instanceJSON = String(decoding: try encoder.encode(instance), as: UTF8.self)
        return try Schema(instance: schemaJSON).validate(instance: instanceJSON).isValid
    }
}
