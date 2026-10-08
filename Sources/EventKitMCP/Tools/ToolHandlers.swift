import EventKitService
import Foundation
import Logging
import MCP

// MARK: - Error Response Builders

extension CallTool.Result {
    private static func text(_ text: String, isError: Bool? = nil) -> Self {
        .init(
            content: [.text(text: text, annotations: nil, _meta: nil)],
            isError: isError
        )
    }

    static func success<Output: Codable>(
        _ text: String,
        structuredContent: Output
    ) throws -> Self {
        try .init(
            content: [.text(text: text, annotations: nil, _meta: nil)],
            structuredContent: structuredContent
        )
    }

    static func failure(_ message: String) -> Self {
        text(message, isError: true)
    }
}

/// Refusals that come from the tool name rather than its arguments.
enum ToolCallError: Error, LocalizedError {
    case readOnly(String)
    case unknownTool(String)

    var errorDescription: String? {
        switch self {
        case .readOnly(let name): "Operation '\(name)' is not allowed in read-only mode"
        case .unknownTool(let name): "Unknown tool: \(name)"
        }
    }
}

// MARK: - Tool Call Handler

public func handleToolCall(
    name: String,
    arguments: [String: Value]?,
    reminderService: ReminderServiceProtocol,
    logger: Logger,
    readOnly: Bool = false,
    now: Date = Date()
) async -> CallTool.Result {
    do {
        if readOnly && ToolRegistry.mutatingTools.contains(name) {
            throw ToolCallError.readOnly(name)
        }

        switch name {
        // Unified query tool
        case "query_reminders":
            return try await handleQueryReminders(arguments, reminderService: reminderService, now: now)

        // Write reminders (unified create/update/delete)
        case "write_reminders":
            return try await handleWriteReminders(arguments, reminderService: reminderService)

        // List operations
        case "get_reminder_lists":
            return try await handleGetLists(reminderService: reminderService)
        case "manage_reminder_list":
            return try await handleManageReminderList(arguments, reminderService: reminderService)

        // Dashboard
        case "overview":
            return try await handleGetOverview(reminderService: reminderService, now: now)

        default:
            throw ToolCallError.unknownTool(name)
        }
    } catch {
        logger.error(
            "Tool execution failed",
            metadata: [
                "tool": "\(name)",
                "error": "\(error.localizedDescription)"
            ])
        return .failure("Error: \(error.localizedDescription)")
    }
}

// MARK: - Query Reminders Handler (unified)

private func handleQueryReminders(
    _ arguments: [String: Value]?,
    reminderService: ReminderServiceProtocol,
    now: Date
) async throws -> CallTool.Result {
    let search = arguments?["search"]?.stringValue
    let includeDone = arguments?["includeDone"]?.boolValue ?? false
    let listId = arguments?["listId"]?.stringValue
    let filter = try requireFilter(arguments?["filter"]?.stringValue)
    let days = try requireDays(arguments?["days"])
    let limit = try requireLimit(arguments?["limit"])
    let offset = try requireOffset(arguments?["offset"])

    let reminders = try await reminderService.getReminders(
        listId: listId,
        includeDone: includeDone
    )

    let timeFilteredReminders: [ReminderModel]

    switch filter {
    case .overdue:
        timeFilteredReminders = ReminderFilters.overdue(reminders, before: now)
    case .today:
        timeFilteredReminders = ReminderFilters.today(reminders, relativeTo: now)
    case .upcoming:
        timeFilteredReminders = ReminderFilters.upcoming(reminders, days: days, from: now)
    case .all:
        timeFilteredReminders = reminders
    }

    let matchingReminders = ReminderFilters.ordered(
        try search.map {
            try ReminderFilters.matching(timeFilteredReminders, pattern: $0)
        } ?? timeFilteredReminders)

    if matchingReminders.isEmpty {
        var hint: String
        if let search {
            let filterScope = filter == .all ? "" : " with filter='\(filter.rawValue)'"
            let listScope = listId == nil ? "" : " in the selected list"
            hint = "No reminders found matching '\(search)'\(filterScope)\(listScope)."
            hint += " Try a broader search term"
            if !includeDone {
                hint += " or set includeDone=true"
            }
            hint += "."
        } else {
            switch filter {
            case .overdue:
                hint = "No overdue reminders found. Try filter='today' or filter='upcoming'."
            case .today:
                hint = "No reminders due today. Try filter='overdue' or filter='upcoming'."
            case .upcoming:
                hint =
                    "No upcoming reminders in the next \(days) days. Try increasing 'days' parameter or use filter='all'."
            case .all:
                hint = "No reminders found."
                if !includeDone {
                    hint += " Set includeDone=true to include done reminders."
                }
                if listId != nil {
                    hint += " Try removing listId to search all lists."
                }
            }
        }
        return try .success(
            hint,
            structuredContent: QueryRemindersOutput(
                count: 0,
                totalCount: 0,
                offset: offset,
                hasMore: false,
                reminders: []
            )
        )
    }

    let page = Array(matchingReminders.dropFirst(offset).prefix(limit))
    let hasMore = offset + page.count < matchingReminders.count
    let pageSummary = "Showing \(page.count) of \(matchingReminders.count) matching reminder(s) from offset \(offset)."
    let text =
        if page.isEmpty {
            "No reminders at offset \(offset). \(matchingReminders.count) reminder(s) match; use a smaller offset."
        } else if search == nil && !hasMore && offset == 0 {
            formatReminders(page)
        } else if search != nil {
            "Found \(matchingReminders.count) reminder(s). \(pageSummary)\n\(formatReminders(page))"
        } else {
            "\(pageSummary)\n\(formatReminders(page))"
        }

    return try .success(
        text,
        structuredContent: QueryRemindersOutput(
            count: page.count,
            totalCount: matchingReminders.count,
            offset: offset,
            hasMore: hasMore,
            reminders: page.map(\.output)
        )
    )
}

// MARK: - Basic Reminder Handlers

private func handleGetLists(reminderService: ReminderServiceProtocol) async throws -> CallTool.Result {
    let lists = try await reminderService.getLists()
    return try .success(
        formatLists(lists),
        structuredContent: GetReminderListsOutput(lists: lists.map(\.output))
    )
}

/// Upper bound on combined upsert and delete operations in one write_reminders call.
/// Matches the query pagination ceiling.
private let maximumBatchSize = 100

private func handleWriteReminders(
    _ arguments: [String: Value]?,
    reminderService: ReminderServiceProtocol
) async throws -> CallTool.Result {
    let upsertArray = arguments?["upsert"]?.arrayValue ?? []
    let deleteArray = arguments?["delete"]?.arrayValue ?? []

    if upsertArray.isEmpty && deleteArray.isEmpty {
        throw ParseError.invalidParameter(
            "input", value: "{}", expected: "At least one of 'upsert' or 'delete' required")
    }

    // Each element is a serialized EventKit write behind the operation gate, so an
    // unbounded batch pushes concurrent callers into operationTimedOut.
    let batchCount = upsertArray.count + deleteArray.count
    if batchCount > maximumBatchSize {
        throw ParseError.invalidParameter(
            "input",
            value: "\(batchCount) operations",
            expected: "At most \(maximumBatchSize) combined 'upsert' and 'delete' operations per call"
        )
    }

    // Track results
    var deletedReminders: [ReminderModel] = []
    var createdReminders: [ReminderModel] = []
    var updatedReminders: [ReminderModel] = []
    var failures: [(id: String, error: String)] = []

    // 1. Process deletes first (avoid updating items that will be deleted)
    for (index, element) in deleteArray.enumerated() {
        guard let id = element.stringValue else {
            failures.append((id: "delete[\(index)]", error: "Invalid item format: expected a reminder ID string"))
            continue
        }
        do {
            let deleted = try await reminderService.deleteReminder(id: id)
            deletedReminders.append(deleted)
        } catch {
            failures.append((id: id, error: error.localizedDescription))
        }
    }

    // 2. Process upserts
    for (index, itemValue) in upsertArray.enumerated() {
        guard let itemObj = itemValue.objectValue else {
            failures.append((id: "upsert[\(index)]", error: "Invalid item format: expected an object"))
            continue
        }

        let id = itemObj["id"]?.stringValue

        if let id = id {
            // UPDATE path (has id)
            do {
                let request = UpdateReminderRequest(
                    id: id,
                    title: itemObj["title"]?.stringValue,
                    notes: try parseStringField(itemObj, key: "notes"),
                    done: itemObj["done"]?.boolValue,
                    dueDate: try parseDateField(itemObj, key: "dueDate", timeZoneKey: "dueTimeZone"),
                    priority: try requirePriority(itemObj["priority"]?.stringValue),
                    listId: itemObj["listId"]?.stringValue,
                    recurrenceRule: try parseRecurrenceField(itemObj),
                    url: try parseURLField(itemObj),
                    startDate: try parseDateField(itemObj, key: "startDate", timeZoneKey: "startTimeZone"),
                    alarms: try parseAlarmsField(itemObj)
                )
                let reminder = try await reminderService.updateReminder(request)
                updatedReminders.append(reminder)
            } catch {
                failures.append((id: id, error: error.localizedDescription))
            }
        } else {
            // CREATE path (no id) - title required
            guard let title = itemObj["title"]?.stringValue else {
                failures.append((id: "upsert[\(index)]", error: "Missing title for new reminder"))
                continue
            }

            do {
                // The update path's parsers, with null meaning the same as omitted.
                let dueDate = try parseDateField(itemObj, key: "dueDate", timeZoneKey: "dueTimeZone").setValue
                let startDate = try parseDateField(itemObj, key: "startDate", timeZoneKey: "startTimeZone").setValue
                let request = CreateReminderRequest(
                    title: title,
                    notes: try parseStringField(itemObj, key: "notes").setValue,
                    listId: itemObj["listId"]?.stringValue,
                    dueDate: dueDate?.date,
                    dueTimeZone: dueDate?.timeZoneIdentifier,
                    isAllDay: dueDate?.isAllDay ?? false,
                    priority: try requirePriority(itemObj["priority"]?.stringValue),
                    recurrenceRule: try parseRecurrenceField(itemObj).setValue,
                    url: try parseURLField(itemObj).setValue,
                    startDate: startDate?.date,
                    startTimeZone: startDate?.timeZoneIdentifier,
                    isStartAllDay: startDate?.isAllDay ?? false,
                    alarms: try parseAlarmsField(itemObj).setValue,
                    done: itemObj["done"]?.boolValue ?? false
                )
                let reminder = try await reminderService.createReminder(request)
                createdReminders.append(reminder)
            } catch {
                failures.append((id: title, error: error.localizedDescription))
            }
        }
    }

    // 3. Format output
    let text = formatWriteResult(
        deleted: deletedReminders,
        deleteTotal: deleteArray.count,
        created: createdReminders,
        updated: updatedReminders,
        failures: failures
    )
    return try .success(
        text,
        structuredContent: WriteRemindersOutput(
            deleted: deletedReminders.map(\.output),
            created: createdReminders.map(\.output),
            updated: updatedReminders.map(\.output),
            failures: failures.map { FailureOutput(id: $0.id, error: $0.error) }
        )
    )
}

private func formatWriteResult(
    deleted: [ReminderModel],
    deleteTotal: Int,
    created: [ReminderModel],
    updated: [ReminderModel],
    failures: [(id: String, error: String)]
) -> String {
    var lines: [String] = []

    // Summary line
    var summaryParts: [String] = []
    if deleteTotal > 0 {
        summaryParts.append("Deleted \(deleted.count) of \(deleteTotal)")
    }
    if !created.isEmpty {
        summaryParts.append("Created \(created.count)")
    }
    if !updated.isEmpty {
        summaryParts.append("Updated \(updated.count)")
    }
    if summaryParts.isEmpty {
        summaryParts.append("No changes made")
    }
    lines.append(summaryParts.joined(separator: ". ") + ".")

    for (heading, reminders) in [("Deleted:", deleted), ("Created:", created), ("Updated:", updated)]
    where !reminders.isEmpty {
        lines.append("")
        lines.append(heading)
        lines.append(formatReminders(reminders))
    }

    // Failures
    if !failures.isEmpty {
        lines.append("")
        lines.append("Failed:")
        for failure in failures {
            lines.append("- \(failure.id): \(failure.error)")
        }
    }

    return lines.joined(separator: "\n")
}

// MARK: - List Handlers

private func handleManageReminderList(
    _ arguments: [String: Value]?,
    reminderService: ReminderServiceProtocol
) async throws -> CallTool.Result {
    guard let actionValue = arguments?["action"]?.stringValue else {
        throw ParseError.missingParameter("action", action: nil)
    }
    guard let action = ReminderListAction(rawValue: actionValue) else {
        throw ParseError.invalidParameter("action", value: actionValue, expected: "Use 'create' or 'delete'")
    }

    switch action {
    case .create:
        guard let title = arguments?["title"]?.stringValue else {
            throw ParseError.missingParameter("title", action: "create")
        }
        let request = CreateListRequest(
            title: title,
            color: try requireColor(arguments?["color"]?.stringValue)
        )
        let list = try await reminderService.createList(request)
        return try .success(
            "Created reminder list:\n\(formatList(list))",
            structuredContent: ManageReminderListOutput(action: action, id: list.id, list: list.output)
        )

    case .delete:
        guard let id = arguments?["id"]?.stringValue else {
            throw ParseError.missingParameter("id", action: "delete")
        }
        try await reminderService.deleteList(id: id)
        return try .success(
            "Deleted reminder list: \(id)",
            structuredContent: ManageReminderListOutput(action: action, id: id, list: nil)
        )
    }
}

private extension ReminderFieldUpdate {
    var setValue: Value? {
        guard case .set(let value) = self else { return nil }
        return value
    }
}

// MARK: - Overview Handler

private func handleGetOverview(
    reminderService: ReminderServiceProtocol,
    now: Date
) async throws -> CallTool.Result {
    let snapshot = OverviewSnapshot(
        lists: try await reminderService.getLists(),
        reminders: try await reminderService.getReminders(listId: nil, includeDone: false),
        now: now
    )
    return try .success(snapshot.render(), structuredContent: snapshot.output)
}
