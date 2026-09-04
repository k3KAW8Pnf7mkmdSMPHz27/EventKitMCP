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

    /// Create error response for missing required parameter
    static func missingParameter(_ name: String, for action: String? = nil) -> Self {
        let actionSuffix = action.map { " (required for \($0) action)" } ?? ""
        return .failure("Missing required parameter: \(name)\(actionSuffix)")
    }

    /// Create error response for invalid parameter value
    static func invalidParameter(_ name: String, value: String, expected: String) -> Self {
        .failure("Invalid \(name): '\(value)'. \(expected)")
    }

    /// Create error response for disallowed operation
    static func notAllowed(_ reason: String) -> Self {
        .failure(reason)
    }

    /// Create error response for not found
    static func notFound(_ type: String, id: String) -> Self {
        .failure("\(type) not found: \(id)")
    }
}

// MARK: - Reminder Filters

enum ReminderFilters {
    /// Filter to reminders that are overdue (due date before start of today)
    /// Sorted by priority (high first), then by due date (most overdue first)
    static func overdue(_ reminders: [ReminderModel], before date: Date = Date()) -> [ReminderModel] {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        return reminders.filter { r in
            guard let due = r.dueDate else { return false }
            return due < startOfDay
        }.sorted { a, b in
            let aPriority = a.priority.sortRank
            let bPriority = b.priority.sortRank
            if aPriority != bPriority {
                return aPriority < bPriority
            }
            // Secondary: due date (earliest/most overdue first)
            return (a.dueDate ?? date) < (b.dueDate ?? date)
        }
    }

    /// Filter to reminders due today
    static func today(_ reminders: [ReminderModel], relativeTo date: Date = Date()) -> [ReminderModel] {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        guard let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else { return [] }
        return reminders.filter { r in
            guard let due = r.dueDate else { return false }
            return due >= startOfDay && due < endOfDay
        }.sorted { ($0.dueDate ?? date) < ($1.dueDate ?? date) }
    }

    /// Filter to reminders due within the specified number of days
    static func upcoming(_ reminders: [ReminderModel], days: Int, from date: Date = Date()) -> [ReminderModel] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: date)
        guard let start = calendar.date(byAdding: .day, value: 1, to: today),
              let end = calendar.date(byAdding: .day, value: days + 1, to: today) else { return [] }
        return reminders.filter { r in
            guard let due = r.dueDate else { return false }
            return due >= start && due < end
        }.sorted { ($0.dueDate ?? date) < ($1.dueDate ?? date) }
    }

    /// Filter to high/medium priority reminders without due dates (need attention)
    static func needsAttention(_ reminders: [ReminderModel]) -> [ReminderModel] {
        reminders.filter { r in
            r.dueDate == nil && (r.priority == .high || r.priority == .medium)
        }
    }

    static func matching(_ reminders: [ReminderModel], pattern: String) throws -> [ReminderModel] {
        let expression: NSRegularExpression
        do {
            expression = try NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        } catch {
            throw ParseError.invalidSearchPattern(pattern)
        }

        return reminders.filter { reminder in
            [reminder.id, reminder.title, reminder.notes]
                .compactMap { $0 }
                .contains { value in
                    expression.firstMatch(
                        in: value,
                        range: NSRange(value.startIndex..., in: value)
                    ) != nil
                }
        }
    }

    static func ordered(_ reminders: [ReminderModel]) -> [ReminderModel] {
        reminders.sorted { lhs, rhs in
            switch (lhs.dueDate, rhs.dueDate) {
            case let (left?, right?) where left != right:
                return left < right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                let titleOrder = lhs.title.caseInsensitiveCompare(rhs.title)
                return titleOrder == .orderedSame ? lhs.id < rhs.id : titleOrder == .orderedAscending
            }
        }
    }
}

private extension ReminderPriority {
    var sortRank: Int {
        switch self {
        case .high: 0
        case .medium: 1
        case .low: 2
        case .none: 3
        }
    }
}

private func formatISO8601(_ date: Date) -> String {
    Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(date)
}

private extension Value {
    var numberValue: Double? {
        switch self {
        case .int(let value): Double(value)
        case .double(let value): value
        default: nil
        }
    }
}

private extension ReminderModel {
    var output: ReminderOutput {
        ReminderOutput(
            id: id,
            title: title,
            notes: notes,
            done: done,
            priority: priority.displayName.lowercased(),
            dueDate: dueDate.map(formatISO8601),
            dueTimeZone: dueTimeZone,
            isAllDay: isAllDay,
            doneDate: doneDate.map(formatISO8601),
            listId: listId,
            listName: listName,
            recurrence: recurrenceRule,
            url: url,
            location: location,
            startDate: startDate.map(formatISO8601),
            startTimeZone: startTimeZone,
            isStartAllDay: isStartAllDay,
            alarms: alarms?.map(\.output)
        )
    }
}

private extension ReminderAlarmModel {
    var output: AlarmOutput {
        switch self {
        case .relative(let minutesBefore):
            AlarmOutput(
                kind: kind.rawValue,
                minutesBefore: minutesBefore,
                absoluteDate: nil,
                proximity: nil,
                title: nil,
                latitude: nil,
                longitude: nil,
                radius: nil
            )
        case .absolute(let date):
            AlarmOutput(
                kind: kind.rawValue,
                minutesBefore: nil,
                absoluteDate: formatISO8601(date),
                proximity: nil,
                title: nil,
                latitude: nil,
                longitude: nil,
                radius: nil
            )
        case .location(let location, let proximity):
            AlarmOutput(
                kind: kind.rawValue,
                minutesBefore: nil,
                absoluteDate: nil,
                proximity: proximity.rawValue,
                title: location.title,
                latitude: location.latitude,
                longitude: location.longitude,
                radius: location.radius
            )
        }
    }
}

private extension ReminderListModel {
    var output: ReminderListOutput {
        ReminderListOutput(
            id: id,
            title: title,
            color: color,
            isSubscribed: isSubscribed,
            isImmutable: isImmutable,
            sourceTitle: sourceTitle
        )
    }
}

// MARK: - Tool Call Handler

public func handleToolCall(
    name: String,
    arguments: [String: Value]?,
    reminderService: ReminderServiceProtocol,
    logger: Logger,
    readOnly: Bool = false
) async -> CallTool.Result {
    // Block mutating operations in read-only mode
    if readOnly && ToolRegistry.mutatingTools.contains(name) {
        return .notAllowed("Operation '\(name)' is not allowed in read-only mode")
    }

    do {
        switch name {
        // Unified query tool
        case "query_reminders":
            return try await handleQueryReminders(arguments, reminderService: reminderService)

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
            return try await handleGetOverview(reminderService: reminderService)

        default:
            return .failure("Unknown tool: \(name)")
        }
    } catch {
        logger.error("Tool execution failed", metadata: [
            "tool": "\(name)",
            "error": "\(error.localizedDescription)"
        ])
        return .failure("Error: \(error.localizedDescription)")
    }
}

// MARK: - Query Reminders Handler (unified)

private func handleQueryReminders(
    _ arguments: [String: Value]?,
    reminderService: ReminderServiceProtocol
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

    let now = Date()
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

    let matchingReminders = ReminderFilters.ordered(try search.map {
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
                hint = "No upcoming reminders in the next \(days) days. Try increasing 'days' parameter or use filter='all'."
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
    let text = if page.isEmpty {
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

private func handleWriteReminders(
    _ arguments: [String: Value]?,
    reminderService: ReminderServiceProtocol
) async throws -> CallTool.Result {
    let upsertArray = arguments?["upsert"]?.arrayValue ?? []
    let deleteArray = arguments?["delete"]?.arrayValue ?? []

    if upsertArray.isEmpty && deleteArray.isEmpty {
        return .invalidParameter("input", value: "{}", expected: "At least one of 'upsert' or 'delete' required")
    }

    // Track results
    var deletedReminders: [ReminderModel] = []
    var createdReminders: [ReminderModel] = []
    var updatedReminders: [ReminderModel] = []
    var failures: [(id: String, error: String)] = []

    // 1. Process deletes first (avoid updating items that will be deleted)
    let deleteIds = deleteArray.compactMap { $0.stringValue }
    if deleteIds.count != deleteArray.count {
        return .invalidParameter("delete", value: "non-string element", expected: "Every element must be a reminder ID string")
    }
    for id in deleteIds {
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
            failures.append((id: "upsert[\(index)]", error: "Invalid item format"))
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
                    location: try parseStringField(itemObj, key: "location"),
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
                // Parse recurrence; null is equivalent to omission during creation.
                let recurrenceRule = try parseRecurrenceField(itemObj).setValue

                // Parse due date with time info to determine isAllDay
                let dateInfo = try requireDateWithTimeInfo(itemObj["dueDate"]?.stringValue)

                // Parse start date
                let startDateInfo = try requireDateWithTimeInfo(itemObj["startDate"]?.stringValue)

                // Parse alarms
                let createAlarms = try parseAlarmsField(itemObj).setValue
                if createAlarms?.contains(where: { $0.kind == .relative }) == true,
                   startDateInfo == nil {
                    throw ParseError.invalidAlarms("relative alarms require startDate")
                }

                let request = CreateReminderRequest(
                    title: title,
                    notes: itemObj["notes"]?.stringValue,
                    listId: itemObj["listId"]?.stringValue,
                    dueDate: dateInfo?.date,
                    dueTimeZone: try parseTimeZone(itemObj["dueTimeZone"]),
                    isAllDay: dateInfo?.isAllDay ?? false,  // false if no date
                    priority: try requirePriority(itemObj["priority"]?.stringValue),
                    recurrenceRule: recurrenceRule,
                    location: itemObj["location"]?.stringValue,
                    url: try parseURL(itemObj["url"]),
                    startDate: startDateInfo?.date,
                    startTimeZone: try parseTimeZone(itemObj["startTimeZone"]),
                    isStartAllDay: startDateInfo?.isAllDay ?? false,
                    alarms: createAlarms
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
        deleteTotal: deleteIds.count,
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
    if summaryParts.isEmpty && failures.isEmpty {
        summaryParts.append("No changes made")
    }
    lines.append(summaryParts.joined(separator: ". ") + (summaryParts.isEmpty ? "" : "."))

    // Deleted reminders (with full details)
    if !deleted.isEmpty {
        lines.append("")
        lines.append("Deleted:")
        lines.append(formatReminders(deleted))
    }

    // Created reminders
    if !created.isEmpty {
        lines.append("")
        lines.append("Created:")
        lines.append(formatReminders(created))
    }

    // Updated reminders
    if !updated.isEmpty {
        lines.append("")
        lines.append("Updated:")
        lines.append(formatReminders(updated))
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
        return .missingParameter("action")
    }
    guard let action = ReminderListAction(rawValue: actionValue) else {
        return .invalidParameter("action", value: actionValue, expected: "Use 'create' or 'delete'")
    }

    switch action {
    case .create:
        guard let title = arguments?["title"]?.stringValue else {
            return .missingParameter("title", for: "create")
        }
        let request = CreateListRequest(
            title: title,
            color: try requireColor(arguments?["color"]?.stringValue)
        )
        let list = try await reminderService.createList(request)
        return try .success(
            "Created reminder list:\n\(formatList(list))",
            structuredContent: ManageReminderListOutput(action: "create", id: list.id, list: list.output)
        )

    case .delete:
        guard let id = arguments?["id"]?.stringValue else {
            return .missingParameter("id", for: "delete")
        }
        try await reminderService.deleteList(id: id)
        return try .success(
            "Deleted reminder list: \(id)",
            structuredContent: ManageReminderListOutput(action: "delete", id: id, list: nil)
        )
    }
}

// MARK: - Formatting Helpers

private func formatReminders(_ reminders: [ReminderModel]) -> String {
    if reminders.isEmpty {
        return "No reminders found"
    }
    return reminders.map { formatReminder($0) }.joined(separator: "\n---\n")
}

private func formatReminder(_ reminder: ReminderModel) -> String {
    var lines: [String] = []

    let status = reminder.done ? "[x]" : "[ ]"
    lines.append("\(status) \(reminder.title)")
    lines.append("  ID: \(reminder.id)")
    lines.append("  List: \(reminder.listName)")

    if let notes = reminder.notes, !notes.isEmpty {
        lines.append("  Notes: \(notes)")
    }

    if reminder.priority != .none {
        lines.append("  Priority: \(reminder.priority.displayName)")
    }

    if let dueDate = reminder.dueDate {
        if reminder.isAllDay {
            lines.append("  Due: \(formatDateOnly(dueDate))")
        } else {
            lines.append("  Due: \(formatDateTime(dueDate))")
        }
    }

    if let startDate = reminder.startDate {
        if reminder.isStartAllDay {
            lines.append("  Start: \(formatDateOnly(startDate))")
        } else {
            lines.append("  Start: \(formatDateTime(startDate))")
        }
    }

    if let doneDate = reminder.doneDate {
        lines.append("  Done: \(formatDateTime(doneDate))")
    }

    if let rrule = reminder.recurrenceRule {
        lines.append("  Recurrence: \(rrule)")
    }

    if let url = reminder.url, !url.isEmpty {
        lines.append("  URL: \(url)")
    }

    if let location = reminder.location, !location.isEmpty {
        lines.append("  Location: \(location)")
    }

    if let alarms = reminder.alarms, !alarms.isEmpty {
        let alarmStrs = alarms.map { alarm -> String in
            switch alarm {
            case .relative(let minutes):
                return minutes == 0 ? "at start" : "\(minutes) min before start"
            case .absolute(let date):
                return "at \(formatDateTime(date))"
            case .location(let location, let proximity):
                let action = proximity == .leave ? "leaving" : "entering"
                return "when \(action) \(location.title)"
            }
        }
        lines.append("  Alarms: \(alarmStrs.joined(separator: ", "))")
    }

    return lines.joined(separator: "\n")
}

private func formatLists(_ lists: [ReminderListModel]) -> String {
    if lists.isEmpty {
        return "No reminder lists found"
    }

    return lists.map { list in
        var line = "• \(list.title) (ID: \(list.id))"
        if let source = list.sourceTitle {
            line += " [\(source)]"
        }
        return line
    }.joined(separator: "\n")
}

private func formatList(_ list: ReminderListModel) -> String {
    var lines: [String] = []
    lines.append("Title: \(list.title)")
    lines.append("ID: \(list.id)")
    if let color = list.color {
        lines.append("Color: \(color)")
    }
    if let source = list.sourceTitle {
        lines.append("Source: \(source)")
    }
    if list.isSubscribed {
        lines.append("Subscribed: Yes")
    }
    if list.isImmutable {
        lines.append("Immutable: Yes")
    }
    return lines.joined(separator: "\n")
}

private func formatDateTime(_ date: Date) -> String {
    date.formatted(date: .abbreviated, time: .shortened)
}

private func formatDateOnly(_ date: Date) -> String {
    date.formatted(date: .abbreviated, time: .omitted)
}

// MARK: - Parsing Helpers

enum ParseError: Error, LocalizedError {
    case invalidSearchPattern(String)
    case invalidDateFormat(String)
    case invalidPriorityValue(String)
    case invalidFilterValue(String)
    case invalidDaysValue(String)
    case invalidColorFormat(String)
    case invalidRRule(String, String)
    case invalidURL(String)
    case invalidTimeZone(String)
    case invalidAlarms(String)
    case invalidStringValue(String)
    case invalidPagination(String)

    var errorDescription: String? {
        switch self {
        case .invalidSearchPattern(let value):
            return "Invalid search pattern: '\(value)'"
        case .invalidDateFormat(let value):
            return "Invalid date format: '\(value)'. Use ISO8601 (e.g., '2026-01-06T10:00:00Z', '2026-01-06T10:00:00-06:00', '2026-01-06T10:00:00', or '2026-01-06')"
        case .invalidPriorityValue(let value):
            return "Invalid priority: '\(value)'. Use 'high', 'medium', 'low', or 'none'"
        case .invalidFilterValue(let value):
            return "Invalid filter: '\(value)'. Use 'all', 'overdue', 'today', or 'upcoming'"
        case .invalidDaysValue(let value):
            return "Invalid days value: '\(value)'. Must be a positive integer"
        case .invalidColorFormat(let value):
            return "Invalid color format: '\(value)'. Use hex format (e.g., '#FF5733' or 'FF5733')"
        case .invalidRRule(let value, let reason):
            return "Invalid RRULE: '\(value)'. \(reason)"
        case .invalidURL(let value):
            return "Invalid URL: '\(value)'"
        case .invalidTimeZone(let value):
            return "Unknown time zone: '\(value)'"
        case .invalidAlarms(let reason):
            return "Invalid alarms: \(reason)"
        case .invalidStringValue(let field):
            return "Invalid \(field): expected a string or null"
        case .invalidPagination(let reason):
            return "Invalid pagination: \(reason)"
        }
    }
}

/// Result of parsing a date string, including whether time was specified
private struct ParsedDate {
    let date: Date
    let hasTime: Bool
}

/// Parse date string and detect if it includes a time component
private func parseDateWithTimeInfo(_ string: String?) -> ParsedDate? {
    guard let string = string else { return nil }

    let formatter = ISO8601DateFormatter()

    // ISO8601 with fractional seconds - has time
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: string) {
        return ParsedDate(date: date, hasTime: true)
    }

    // ISO8601 without fractional seconds - has time
    formatter.formatOptions = [.withInternetDateTime]
    if let date = formatter.date(from: string) {
        return ParsedDate(date: date, hasTime: true)
    }

    // Fallback: local datetime (no timezone = local time) - has time
    let localFormatter = DateFormatter()
    localFormatter.locale = Locale(identifier: "en_US_POSIX")
    localFormatter.timeZone = TimeZone.current

    localFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    if let date = localFormatter.date(from: string) {
        return ParsedDate(date: date, hasTime: true)
    }

    // Date-only format - no time (all-day)
    localFormatter.dateFormat = "yyyy-MM-dd"
    if let date = localFormatter.date(from: string) {
        return ParsedDate(date: date, hasTime: false)
    }

    return nil
}

private func parseDate(_ string: String?) -> Date? {
    parseDateWithTimeInfo(string)?.date
}

/// Parse date with time info and explicit error when format is invalid
/// Returns (date, isAllDay) where isAllDay is true if the input was date-only format
private func requireDateWithTimeInfo(_ string: String?) throws -> (date: Date, isAllDay: Bool)? {
    guard let string = string else { return nil }
    guard let parsed = parseDateWithTimeInfo(string) else {
        throw ParseError.invalidDateFormat(string)
    }
    return (parsed.date, !parsed.hasTime)
}

/// Parse date with explicit error when format is invalid
private func requireDate(_ string: String?) throws -> Date? {
    guard let string = string else { return nil }
    guard let date = parseDate(string) else {
        throw ParseError.invalidDateFormat(string)
    }
    return date
}

private func parsePriority(_ string: String?) -> ReminderPriority? {
    guard let input = string.flatMap(ReminderPriorityInput.init(rawValue:)) else { return nil }
    switch input {
    case .high: return .high
    case .medium: return .medium
    case .low: return .low
    case .none: return ReminderPriority.none
    }
}

/// Parse priority with explicit error when value is invalid
private func requirePriority(_ string: String?) throws -> ReminderPriority? {
    guard let string = string else { return nil }
    guard let priority = parsePriority(string) else {
        throw ParseError.invalidPriorityValue(string)
    }
    return priority
}

/// Parse filter with explicit error when value is invalid
private func requireFilter(_ string: String?) throws -> QueryFilter {
    let value = string ?? QueryFilter.all.rawValue
    guard let filter = QueryFilter(rawValue: value) else {
        throw ParseError.invalidFilterValue(value)
    }
    return filter
}

/// Parse days with explicit error when value is invalid
private func requireDays(_ value: Value?) throws -> Int {
    guard let value = value else { return 7 }
    guard let days = value.intValue, days > 0 else {
        let description: String
        if let str = value.stringValue {
            description = str
        } else if let num = value.doubleValue {
            description = String(num)
        } else {
            description = "invalid value"
        }
        throw ParseError.invalidDaysValue(description)
    }
    return days
}

private func requireLimit(_ value: Value?) throws -> Int {
    guard let value else { return 25 }
    guard let limit = value.intValue, (1...100).contains(limit) else {
        throw ParseError.invalidPagination("limit must be an integer from 1 through 100")
    }
    return limit
}

private func requireOffset(_ value: Value?) throws -> Int {
    guard let value else { return 0 }
    guard let offset = value.intValue, offset >= 0 else {
        throw ParseError.invalidPagination("offset must be a non-negative integer")
    }
    return offset
}

/// Parse color with explicit error when format is invalid
private func requireColor(_ string: String?) throws -> String? {
    guard let color = string else { return nil }
    let pattern = "^#?[0-9A-Fa-f]{6}$"
    guard color.range(of: pattern, options: .regularExpression) != nil else {
        throw ParseError.invalidColorFormat(color)
    }
    return color
}

/// Parse alarms field from upsert item (3-state: missing=unchanged, null=remove, array=set).
private func parseAlarmsField(
    _ itemObj: [String: Value]
) throws -> ReminderFieldUpdate<[ReminderAlarmModel]> {
    guard let value = itemObj["alarms"] else {
        return .unchanged
    }
    if case .null = value {
        return .clear
    }
    guard let array = value.arrayValue else {
        throw ParseError.invalidAlarms("expected an array or null")
    }
    var alarms: [ReminderAlarmModel] = []
    for (index, element) in array.enumerated() {
        guard let object = element.objectValue, let kind = object["kind"]?.stringValue else {
            throw ParseError.invalidAlarms("element \(index) must be an alarm object with a kind")
        }
        switch kind {
        case "relative":
            guard let minutes = object["minutesBefore"]?.intValue, minutes >= 0 else {
                throw ParseError.invalidAlarms("relative element \(index) needs non-negative integer minutesBefore")
            }
            alarms.append(.relative(minutesBefore: minutes))
        case "absolute":
            guard let value = object["absoluteDate"]?.stringValue,
                  let date = parseDate(value) else {
                throw ParseError.invalidAlarms("absolute element \(index) needs a valid absoluteDate")
            }
            alarms.append(.absolute(date))
        case "location":
            guard let title = object["title"]?.stringValue,
                  let latitude = object["latitude"]?.numberValue,
                  let longitude = object["longitude"]?.numberValue,
                  let radius = object["radius"]?.numberValue,
                  radius >= 0,
                  let proximityValue = object["proximity"]?.stringValue,
                  let proximity = ReminderAlarmModel.Proximity(rawValue: proximityValue),
                  proximity != .none else {
                throw ParseError.invalidAlarms("location element \(index) needs title, coordinates, non-negative radius, and enter/leave proximity")
            }
            guard (-90...90).contains(latitude), (-180...180).contains(longitude) else {
                throw ParseError.invalidAlarms("location element \(index) has invalid coordinates")
            }
            alarms.append(.location(
                .init(title: title, latitude: latitude, longitude: longitude, radius: radius),
                proximity: proximity
            ))
        default:
            throw ParseError.invalidAlarms("unknown kind '\(kind)' at element \(index)")
        }
    }
    return .set(alarms)
}

private func parseDateField(
    _ object: [String: Value],
    key: String,
    timeZoneKey: String
) throws -> ReminderFieldUpdate<ReminderDateValue> {
    guard let value = object[key] else { return .unchanged }
    if value.isNull { return .clear }
    guard let string = value.stringValue, let parsed = parseDateWithTimeInfo(string) else {
        throw ParseError.invalidDateFormat(value.stringValue ?? "(non-string value)")
    }
    return .set(ReminderDateValue(
        date: parsed.date,
        timeZoneIdentifier: try parseTimeZone(object[timeZoneKey]),
        isAllDay: !parsed.hasTime
    ))
}

private func parseStringField(
    _ object: [String: Value],
    key: String
) throws -> ReminderFieldUpdate<String> {
    guard let value = object[key] else { return .unchanged }
    if value.isNull { return .clear }
    guard let string = value.stringValue else {
        throw ParseError.invalidStringValue(key)
    }
    return .set(string)
}

private func parseURL(_ value: Value?) throws -> String? {
    guard let value else { return nil }
    if value.isNull { return nil }
    guard let string = value.stringValue,
          let url = URL(string: string),
          url.scheme?.isEmpty == false else {
        throw ParseError.invalidURL(value.stringValue ?? "(non-string value)")
    }
    return string
}

private func parseURLField(_ object: [String: Value]) throws -> ReminderFieldUpdate<String> {
    guard let value = object["url"] else { return .unchanged }
    if value.isNull { return .clear }
    guard let url = try parseURL(value) else { return .unchanged }
    return .set(url)
}

private func parseTimeZone(_ value: Value?) throws -> String? {
    guard let value else { return nil }
    if value.isNull { return nil }
    guard let identifier = value.stringValue, TimeZone(identifier: identifier) != nil else {
        throw ParseError.invalidTimeZone(value.stringValue ?? "(non-string value)")
    }
    return identifier
}

/// Parse recurrence field from upsert item
private func parseRecurrenceField(_ itemObj: [String: Value]) throws -> ReminderFieldUpdate<String> {
    guard let value = itemObj["recurrence"] else {
        return .unchanged
    }

    if case .null = value {
        return .clear
    }

    guard let rrule = value.stringValue else {
        throw ParseError.invalidRRule("(non-string value)", "Recurrence must be an RRULE string")
    }

    // Validate by parsing (RRuleParser will throw if invalid)
    do {
        _ = try RRuleParser.parse(rrule)
    } catch {
        throw ParseError.invalidRRule(rrule, error.localizedDescription)
    }

    return .set(rrule)
}

private extension ReminderFieldUpdate {
    var setValue: Value? {
        guard case .set(let value) = self else { return nil }
        return value
    }
}

// MARK: - Overview Handler

private func handleGetOverview(
    reminderService: ReminderServiceProtocol
) async throws -> CallTool.Result {
    let lists = try await reminderService.getLists()
    let reminders = try await reminderService.getReminders(listId: nil, includeDone: false)

    let now = Date()

    // Categorize reminders using shared filters
    let overdue = ReminderFilters.overdue(reminders, before: now)
    let today = ReminderFilters.today(reminders, relativeTo: now)
    let upcoming = ReminderFilters.upcoming(reminders, days: 7, from: now)
    let attention = ReminderFilters.needsAttention(reminders)

    // Count incomplete reminders per list
    let countsByList = Dictionary(grouping: reminders, by: \.listId)
        .mapValues { $0.count }

    // Per-list stats for overdue and priority
    let overdueByList = Dictionary(grouping: overdue, by: \.listId)
        .mapValues { $0.count }
    let highPriorityByList = Dictionary(grouping: reminders.filter { $0.priority == .high }, by: \.listId)
        .mapValues { $0.count }
    let mediumPriorityByList = Dictionary(grouping: reminders.filter { $0.priority == .medium }, by: \.listId)
        .mapValues { $0.count }

    // Count scheduled (has due date) vs unscheduled
    let scheduled = reminders.filter { $0.dueDate != nil }
    let unscheduled = reminders.filter { $0.dueDate == nil }
    let unscheduledAttention = unscheduled.filter { $0.priority == .high || $0.priority == .medium }

    let output = formatOverview(
        now: now,
        lists: lists,
        countsByList: countsByList,
        overdueByList: overdueByList,
        highPriorityByList: highPriorityByList,
        mediumPriorityByList: mediumPriorityByList,
        scheduledCount: scheduled.count,
        unscheduledAttentionCount: unscheduledAttention.count,
        unscheduledOtherCount: unscheduled.count - unscheduledAttention.count,
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
    lines.append("Overview as of \(dateFormatter.string(from: now)) (\(timezone)). Today is \(weekdayFormatter.string(from: now)).")
    lines.append("")

    // Summary counts - focus on actionable items first
    lines.append("SUMMARY: \(scheduledCount) scheduled (\(overdue.count) overdue, \(today.count) today, \(upcoming.count) upcoming) + \(unscheduledAttentionCount) unscheduled high/medium priority + \(unscheduledOtherCount) other unscheduled")
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
            let priorityStr = r.priority == .high ? " (high)" : " (medium)"
            lines.append("- \(r.title)\(priorityStr) in \(r.listName)")
        }
    }

    // Overdue section (truncated to first 10)
    if !overdue.isEmpty {
        lines.append("")
        lines.append("OVERDUE:")
        let maxOverdue = 10
        for r in overdue.prefix(maxOverdue) {
            let priorityStr = formatPriorityLabel(r.priority)
            let dueStr = r.dueDate.map { formatRelativeDate($0) } ?? ""
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

        let sortedDates = grouped.keys.sorted()
        let upcomingDateFormatter = DateFormatter()
        upcomingDateFormatter.dateFormat = "MMM d"
        for date in sortedDates {
            let count = grouped[date]?.count ?? 0
            lines.append("- \(upcomingDateFormatter.string(from: date)): \(count) reminder\(count == 1 ? "" : "s")")
        }
    }

    // Tips - single line, concise
    if overdue.count > 10 {
        lines.append("")
        lines.append("TIPS: Notes hidden. query_reminders shows full details. \(overdue.count) overdue total (10 shown).")
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

private func formatRelativeDate(_ date: Date) -> String {
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
