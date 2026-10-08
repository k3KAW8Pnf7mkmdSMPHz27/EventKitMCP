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
    let lists = try await reminderService.getLists()
    let reminders = try await reminderService.getReminders(listId: nil, includeDone: false)

    // Categorize reminders using shared filters
    let overdue = ReminderFilters.overdue(reminders, before: now)
    let today = ReminderFilters.today(reminders, relativeTo: now)
    let upcoming = ReminderFilters.upcoming(reminders, days: 7, from: now)
    let attention = ReminderFilters.needsAttention(reminders)

    // Count scheduled (has due date) vs unscheduled
    let scheduled = reminders.filter { $0.dueDate != nil }
    let unscheduled = reminders.filter { $0.dueDate == nil }

    let output = formatOverview(
        now: now,
        lists: lists,
        countsByList: countByList(reminders),
        overdueByList: countByList(overdue),
        highPriorityByList: countByList(reminders.filter { $0.priority == .high }),
        mediumPriorityByList: countByList(reminders.filter { $0.priority == .medium }),
        scheduledCount: scheduled.count,
        unscheduledAttentionCount: attention.count,
        unscheduledOtherCount: unscheduled.count - attention.count,
        overdue: overdue,
        today: today,
        upcoming: upcoming,
        attention: attention
    )

    return try .success(
        output,
        structuredContent: OverviewOutput(
            listCount: lists.count,
            incompleteCount: reminders.count,
            overdueCount: overdue.count,
            todayCount: today.count,
            upcomingCount: upcoming.count,
            attentionCount: attention.count
        )
    )
}

private func formatOverview(
    now: Date,
    lists: [ReminderListModel],
    countsByList: [String: Int],
    overdueByList: [String: Int],
    highPriorityByList: [String: Int],
    mediumPriorityByList: [String: Int],
    scheduledCount: Int,
    unscheduledAttentionCount: Int,
    unscheduledOtherCount: Int,
    overdue: [ReminderModel],
    today: [ReminderModel],
    upcoming: [ReminderModel],
    attention: [ReminderModel]
) -> String {
    var lines: [String] = []

    // Header with date/time and timezone
    let dateFormatter = DateFormatter()
    dateFormatter.dateFormat = DateFormatter.dateFormat(
        fromTemplate: "EEE MMM d, yyyy h:mm a",
        options: 0,
        locale: Locale.current
    )
    let weekdayFormatter = DateFormatter()
    weekdayFormatter.dateFormat = "EEEE"  // Full weekday name
    let timezone = TimeZone.current.identifier
    lines.append(
        "Overview as of \(dateFormatter.string(from: now)) (\(timezone)). Today is \(weekdayFormatter.string(from: now))."
    )
    lines.append("")

    // Summary counts - focus on actionable items first
    lines.append(
        "SUMMARY: \(scheduledCount) scheduled (\(overdue.count) overdue, \(today.count) today, \(upcoming.count) upcoming) + \(unscheduledAttentionCount) unscheduled high/medium priority + \(unscheduledOtherCount) other unscheduled"
    )
    lines.append("")

    // Lists with counts (only show lists with incomplete reminders)
    let listsWithReminders = lists.filter { (countsByList[$0.id] ?? 0) > 0 }
    if !listsWithReminders.isEmpty {
        lines.append("LISTS:")
        for list in listsWithReminders {
            let count = countsByList[list.id] ?? 0
            var stats = ["\(count) incomplete"]
            if let od = overdueByList[list.id], od > 0 { stats.append("\(od) overdue") }
            if let hi = highPriorityByList[list.id], hi > 0 { stats.append("\(hi) high") }
            if let med = mediumPriorityByList[list.id], med > 0 { stats.append("\(med) medium") }
            lines.append("- \(list.title): \(stats.joined(separator: ", "))")
        }
    }

    // Attention section (high priority, no due date)
    if !attention.isEmpty {
        lines.append("")
        lines.append("ATTENTION (high/medium priority, no due date):")
        for r in attention {
            lines.append("- \(r.title)\(formatPriorityLabel(r.priority)) in \(r.listName)")
        }
    }

    // Overdue section (truncated to first 10)
    if !overdue.isEmpty {
        lines.append("")
        lines.append("OVERDUE:")
        let maxOverdue = 10
        for r in overdue.prefix(maxOverdue) {
            let priorityStr = formatPriorityLabel(r.priority)
            let dueStr = r.dueDate.map(monthDay) ?? ""
            lines.append("- \(r.title)\(priorityStr) in \(r.listName), due \(dueStr)")
        }
        if overdue.count > maxOverdue {
            lines.append("... and \(overdue.count - maxOverdue) more overdue")
        }
    }

    // Today section
    if !today.isEmpty {
        lines.append("")
        lines.append("TODAY:")
        for r in today {
            let priorityStr = formatPriorityLabel(r.priority)
            let timeStr = formatTimeOnly(r)
            if timeStr.isEmpty {
                lines.append("- \(r.title)\(priorityStr) in \(r.listName)")
            } else {
                lines.append("- \(r.title)\(priorityStr) in \(r.listName) at \(timeStr)")
            }
        }
    }

    // Upcoming section (grouped by date)
    if !upcoming.isEmpty {
        lines.append("")
        lines.append("UPCOMING (7 days):")

        let calendar = Calendar.current
        let grouped = Dictionary(grouping: upcoming) { r -> Date in
            guard let due = r.dueDate else { return Date.distantFuture }
            return calendar.startOfDay(for: due)
        }

        for date in grouped.keys.sorted() {
            let count = grouped[date]?.count ?? 0
            lines.append("- \(monthDay(date)): \(count) reminder\(count == 1 ? "" : "s")")
        }
    }

    // Tips - single line, concise
    if overdue.count > 10 {
        lines.append("")
        lines.append(
            "TIPS: Notes hidden. query_reminders shows full details. \(overdue.count) overdue total (10 shown).")
    } else {
        lines.append("")
        lines.append("TIPS: Notes hidden. query_reminders shows full details (notes, URLs, recurrence).")
    }

    return lines.joined(separator: "\n")
}

private func formatPriorityLabel(_ priority: ReminderPriority) -> String {
    switch priority {
    case .high: return " (high)"
    case .medium: return " (medium)"
    case .low, .none: return ""
    }
}

private func countByList(_ reminders: [ReminderModel]) -> [String: Int] {
    Dictionary(grouping: reminders, by: \.listId).mapValues(\.count)
}

private func monthDay(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "MMM d"
    return formatter.string(from: date)
}

private func formatTimeOnly(_ reminder: ReminderModel) -> String {
    // If all-day reminder, no time to show
    if reminder.isAllDay {
        return ""
    }
    guard let date = reminder.dueDate else {
        return ""
    }
    let formatter = DateFormatter()
    formatter.timeStyle = .short
    formatter.dateStyle = .none
    return formatter.string(from: date)
}
