import ArgumentParser
import EventKitService
import Foundation
import JSONSchemaBuilder
import Logging
import MCP

// MARK: - Main Entry Point

@main
struct EventKitMCPServer: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "eventkit-mcp-server",
        abstract: "MCP server for Apple Reminders via EventKit",
        version: eventKitServiceVersion
    )

    @Flag(name: .shortAndLong, help: "Enable verbose logging")
    var verbose = false

    @Flag(name: .long, help: "Log to stderr instead of suppressing logs")
    var logToStderr = false

    @Flag(name: .long, help: "Disable mutating operations (create, update, delete)")
    var readOnly = false

    @Option(name: .long, help: "Comma-separated list of reminder list IDs to allow access to")
    var allowedLists: String?

    mutating func run() async throws {
        // Configure logging
        let logLevel: Logger.Level = verbose ? .debug : .info

        if logToStderr {
            LoggingSystem.bootstrap { label in
                var handler = StreamLogHandler.standardError(label: label)
                handler.logLevel = logLevel
                return handler
            }
        } else {
            // Suppress logging by default (stdout is used for MCP communication)
            LoggingSystem.bootstrap { _ in
                SwiftLogNoOpLogHandler()
            }
        }

        var logger = Logger(label: "eventkit-mcp")
        logger.logLevel = logLevel
        logger.info("Starting EventKit MCP Server")

        // Parse allowed lists
        let allowedListIds: Set<String>? = allowedLists.map { listString in
            Set(listString.split(separator: ",")
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty })
        }

        // Initialize services
        let reminderService = ReminderService(
            logger: Logger(label: "eventkit.service"),
            allowedListIds: allowedListIds
        )

        // Request access to reminders
        do {
            let granted = try await reminderService.requestAccess()
            if !granted {
                logger.error("Access to reminders was denied")
                throw ExitCode.failure
            }
            logger.info("Reminders access granted")
        } catch {
            logger.error("Failed to request reminders access: \(error.localizedDescription)")
            throw ExitCode.failure
        }

        // Create MCP server with official SDK
        let server = Server(
            name: "eventkit-mcp-server",
            version: eventKitServiceVersion,
            title: "EventKit Reminders",
            capabilities: .init(
                tools: .init(listChanged: false)
            )
        )

        // Register tool handlers
        await ToolRegistry.registerHandlers(
            server: server,
            reminderService: reminderService,
            logger: logger,
            readOnly: readOnly
        )

        if readOnly {
            logger.info("Running in read-only mode - mutating operations disabled")
        }

        if let ids = allowedListIds {
            logger.info("List access restricted to \(ids.count) list(s)")
        }

        logger.info("Server configured, starting transport")

        // Start with stdio transport
        let transport = StdioTransport()
        try await server.start(transport: transport)
        await server.waitUntilCompleted()
    }
}

// MARK: - Tool Registration

enum ToolRegistry {
    static func registerHandlers(
        server: Server,
        reminderService: ReminderServiceProtocol,
        logger: Logger,
        readOnly: Bool = false
    ) async {
        // Register tools list handler
        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: allTools(readOnly: readOnly))
        }

        // Register tool call handler
        await server.withMethodHandler(CallTool.self) { params in
            await handleToolCall(
                name: params.name,
                arguments: params.arguments,
                reminderService: reminderService,
                logger: logger,
                readOnly: readOnly
            )
        }
    }

    /// Mutating tool names that should be blocked in read-only mode
    static let mutatingTools: Set<String> = [
        "write_reminders",
        "manage_reminder_list"
    ]

    /// Creates all tool definitions using @Schemable-generated schemas
    static func allTools(readOnly: Bool = false) -> [Tool] {
        let tools: [Tool] = [
            // Unified query tool
            Tool(
                name: "query_reminders",
                title: "Query Reminders",
                description: "Query reminders by list, time filter, and regex search. Supplied constraints are combined. Results are paginated: limit defaults to 25 (maximum 100), and offset selects the next page. Use regex alternation (id1|id2|id3) to match multiple IDs in one call.",
                inputSchema: SchemaHelpers.schemaToValue(QueryRemindersInput.self),
                annotations: .init(readOnlyHint: true, idempotentHint: true, openWorldHint: false),
                outputSchema: SchemaHelpers.schemaToValue(QueryRemindersOutput.self)
            ),

            // Write reminders (unified create/update/delete)
            Tool(
                name: "write_reminders",
                title: "Write Reminders",
                description: "Create, update, or delete reminders. BATCH MULTIPLE OPERATIONS in one call for efficiency. Use 'upsert' array: items without 'id' create new reminders, items with 'id' update existing. Use 'delete' array for IDs to permanently remove. PREFER marking reminders done (done: true) over deleting—done reminders preserve history and can be reviewed later. Only delete for duplicates, mistakes, or when explicitly requested.",
                inputSchema: SchemaHelpers.schemaToValue(WriteRemindersInput.self),
                annotations: .init(destructiveHint: true, idempotentHint: false, openWorldHint: false),
                outputSchema: SchemaHelpers.schemaToValue(WriteRemindersOutput.self)
            ),

            // List operations
            Tool(
                name: "get_reminder_lists",
                title: "Get Reminder Lists",
                description: "Get all reminder lists",
                inputSchema: SchemaHelpers.schemaToValue(EmptyInput.self),
                annotations: .init(readOnlyHint: true, idempotentHint: true, openWorldHint: false),
                outputSchema: SchemaHelpers.schemaToValue(GetReminderListsOutput.self)
            ),
            Tool(
                name: "manage_reminder_list",
                title: "Manage Reminder List",
                description: "Create or delete reminder lists. Use action='create' with title (and optional color), or action='delete' with id.",
                inputSchema: SchemaHelpers.schemaToValue(ManageReminderListInput.self),
                annotations: .init(destructiveHint: true, idempotentHint: false, openWorldHint: false),
                outputSchema: SchemaHelpers.schemaToValue(ManageReminderListOutput.self)
            ),

            // Dashboard
            Tool(
                name: "overview",
                title: "Overview",
                description: "Get a concise overview: current date/time with timezone, scheduled vs unscheduled breakdown (with overdue/today/upcoming counts), all lists with counts, high-priority unscheduled items needing attention, overdue and today's reminders with details, and upcoming week summary",
                inputSchema: SchemaHelpers.schemaToValue(OverviewInput.self),
                annotations: .init(readOnlyHint: true, idempotentHint: true, openWorldHint: false),
                outputSchema: SchemaHelpers.schemaToValue(OverviewOutput.self)
            )
        ]

        if readOnly {
            return tools.filter { !mutatingTools.contains($0.name) }
        }
        return tools
    }
}

// MARK: - No-Op Log Handler

/// A log handler that discards all log messages
struct SwiftLogNoOpLogHandler: LogHandler {
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .critical

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { nil }
        set { }
    }

    func log(event: LogEvent) {
        // Discard all logs
    }
}
