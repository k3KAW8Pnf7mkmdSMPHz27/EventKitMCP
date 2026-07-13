import EventKitService
import Foundation
import Logging
import MCP

// MARK: - Tool Services Container

/// Container for all services and configuration needed by tool handlers
public struct ToolServices: Sendable {
    public let reminders: ReminderServiceProtocol
    public let logger: Logger
    public let readOnly: Bool

    public init(
        reminders: ReminderServiceProtocol,
        logger: Logger,
        readOnly: Bool = false
    ) {
        self.reminders = reminders
        self.logger = logger
        self.readOnly = readOnly
    }
}

// MARK: - Error Response Builders

extension CallTool.Result {
    /// Create error response for missing required parameter
    static func missingParameter(_ name: String, for action: String? = nil) -> Self {
        let actionSuffix = action.map { " (required for \($0) action)" } ?? ""
        return .init(
            content: [.text("Missing required parameter: \(name)\(actionSuffix)")],
            isError: true
        )
    }

    /// Create error response for invalid parameter value
    static func invalidParameter(_ name: String, value: String, expected: String) -> Self {
        .init(
            content: [.text("Invalid \(name): '\(value)'. \(expected)")],
            isError: true
        )
    }

    /// Create error response for disallowed operation
    static func notAllowed(_ reason: String) -> Self {
        .init(content: [.text(reason)], isError: true)
    }

    /// Create error response for not found
    static func notFound(_ type: String, id: String) -> Self {
        .init(content: [.text("\(type) not found: \(id)")], isError: true)
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
            // Primary: priority (high=1 < medium=5 < low=9 < none=0, but we want high first)
            let priorityOrder: [ReminderPriority: Int] = [.high: 0, .medium: 1, .low: 2, .none: 3]
            let aPriority = priorityOrder[a.priority] ?? 3
            let bPriority = priorityOrder[b.priority] ?? 3
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
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!
        return reminders.filter { r in
            guard let due = r.dueDate else { return false }
            return due >= startOfDay && due < endOfDay
        }.sorted { ($0.dueDate ?? date) < ($1.dueDate ?? date) }
    }

    /// Filter to reminders due within the specified number of days
    static func upcoming(_ reminders: [ReminderModel], days: Int, from date: Date = Date()) -> [ReminderModel] {
        let calendar = Calendar.current
        let endOfToday = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date))!
        let futureDate = calendar.date(byAdding: .day, value: days, to: date)!
        return reminders.filter { r in
            guard let due = r.dueDate else { return false }
            return due >= endOfToday && due <= futureDate
        }.sorted { ($0.dueDate ?? date) < ($1.dueDate ?? date) }
    }

    /// Filter to high/medium priority reminders without due dates (need attention)
    static func needsAttention(_ reminders: [ReminderModel]) -> [ReminderModel] {
        reminders.filter { r in
            r.dueDate == nil && (r.priority == .high || r.priority == .medium)
        }
    }
}

// MARK: - Batch Operation Helpers

struct BatchResult<T> {
    let successes: [(id: String, item: T)]
    let failures: [(id: String, error: String)]

    var successCount: Int { successes.count }
    var failureCount: Int { failures.count }
    var total: Int { successCount + failureCount }

    static var empty: BatchResult<T> { .init(successes: [], failures: []) }
}

enum BatchOperations {
    /// Execute an operation for each ID, collecting successes and failures
    static func execute<T>(
        ids: [String],
        operation: (String) async throws -> T
    ) async -> BatchResult<T> {
        var successes: [(id: String, item: T)] = []
        var failures: [(id: String, error: String)] = []

        for id in ids {
            do {
                let result = try await operation(id)
                successes.append((id: id, item: result))
            } catch {
                failures.append((id: id, error: error.localizedDescription))
            }
        }

        return BatchResult(successes: successes, failures: failures)
    }

    /// Format a batch result for display
    static func format<T>(
        _ result: BatchResult<T>,
        noun: String,
        pastVerb: String,
        formatter: ([(id: String, item: T)]) -> String
    ) -> String {
        var output = "\(pastVerb.capitalized) \(result.successCount) of \(result.total) \(noun)"

        if !result.successes.isEmpty {
            output += ":\n\n" + formatter(result.successes)
        }

        if !result.failures.isEmpty {
            output += "\n\nFailed:\n" + result.failures.map { "- \($0.id): \($0.error)" }.joined(separator: "\n")
        }

        return output
    }

    /// Format a batch result for delete operations (just IDs)
    static func formatDeleted(_ result: BatchResult<Void>, noun: String) -> String {
        var output = "Deleted \(result.successCount) of \(result.total) \(noun)"

        if !result.successes.isEmpty {
            output += ":\n" + result.successes.map { "- \($0.id)" }.joined(separator: "\n")
        }

        if !result.failures.isEmpty {
            output += "\n\nFailed:\n" + result.failures.map { "- \($0.id): \($0.error)" }.joined(separator: "\n")
        }

        return output
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
            return .init(content: [.text("Unknown tool: \(name)")], isError: true)
        }
    } catch {
        logger.error("Tool execution failed", metadata: [
            "tool": "\(name)",
            "error": "\(error.localizedDescription)"
        ])
        return .init(content: [.text( "Error: \(error.localizedDescription)")], isError: true)
    }
}

// MARK: - Query Reminders Handler (unified)

private func handleQueryReminders(
    _ arguments: [String: Value]?,
    reminderService: ReminderServiceProtocol
) async throws -> CallTool.Result {
    let search = arguments?["search"]?.stringValue
    let includeDone = arguments?["includeDone"]?.boolValue ?? false

    if let search = search {
        // Search-based fetch
        let reminders = try await reminderService.searchReminders(
            query: search,
            includeDone: includeDone
        )

        if reminders.isEmpty {
            var hint = "No reminders found matching '\(search)'."
            if !includeDone {
                hint += " Try a broader search term or set includeDone=true to search done reminders."
            } else {
                hint += " Try a broader search term."
            }
            return .init(content: [.text(hint)])
        }

        return .init(content: [.text("Found \(reminders.count) reminder(s):\n\(formatReminders(reminders))")])
    }

    // Filter-based fetch (default)
    let listId = arguments?["listId"]?.stringValue
    let filter = try requireFilter(arguments?["filter"]?.stringValue)
    let days = try requireDays(arguments?["days"])

    let reminders = try await reminderService.getReminders(
        listId: listId,
        includeDone: includeDone
    )

    let now = Date()
    let filteredReminders: [ReminderModel]

    switch filter {
    case "overdue":
        filteredReminders = ReminderFilters.overdue(reminders, before: now)
    case "today":
        filteredReminders = ReminderFilters.today(reminders, relativeTo: now)
    case "upcoming":
        filteredReminders = ReminderFilters.upcoming(reminders, days: days, from: now)
    default: // "all"
        filteredReminders = reminders
    }

    if filteredReminders.isEmpty {
        var hint: String
        switch filter {
        case "overdue":
            hint = "No overdue reminders found. Try filter='today' or filter='upcoming'."
        case "today":
            hint = "No reminders due today. Try filter='overdue' or filter='upcoming'."
        case "upcoming":
            hint = "No upcoming reminders in the next \(days) days. Try increasing 'days' parameter or use filter='all'."
        default: // "all"
            hint = "No reminders found."
            if !includeDone {
                hint += " Set includeDone=true to include done reminders."
            }
            if listId != nil {
                hint += " Try removing listId to search all lists."
            }
        }
        return .init(content: [.text(hint)])
    }

    return .init(content: [.text(formatReminders(filteredReminders))])
}

// MARK: - Basic Reminder Handlers

private func handleGetLists(reminderService: ReminderServiceProtocol) async throws -> CallTool.Result {
    let lists = try await reminderService.getLists()
    return .init(content: [.text( formatLists(lists))])
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
                // Parse recurrence: check if key exists to distinguish null from missing
                let (recurrenceRule, removeRecurrence) = try parseRecurrenceField(itemObj)

                // Parse due date with time info to determine isAllDay
                let dateInfo = try requireDateWithTimeInfo(itemObj["dueDate"]?.stringValue)

                // Parse start date (3-state)
                let startDateInfo = try parseStartDateField(itemObj)

                // Parse alarms (3-state)
                let (alarmOffsets, removeAlarms) = parseAlarmsField(itemObj)

                let request = UpdateReminderRequest(
                    id: id,
                    title: itemObj["title"]?.stringValue,
                    notes: itemObj["notes"]?.stringValue,
                    done: itemObj["done"]?.boolValue,
                    dueDate: dateInfo?.date,
                    isAllDay: dateInfo?.isAllDay,  // nil if no date provided, preserves existing
                    priority: try requirePriority(itemObj["priority"]?.stringValue),
                    listId: itemObj["listId"]?.stringValue,
                    recurrenceRule: recurrenceRule,
                    removeRecurrence: removeRecurrence,
                    location: itemObj["location"]?.stringValue,
                    url: itemObj["url"]?.stringValue,
                    startDate: startDateInfo.date,
                    isStartAllDay: startDateInfo.isAllDay,
                    removeStartDate: startDateInfo.remove,
                    alarms: alarmOffsets,
                    removeAlarms: removeAlarms
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
                // Parse recurrence (for create, we only need the rule, not removeRecurrence)
                let (recurrenceRule, _) = try parseRecurrenceField(itemObj)

                // Parse due date with time info to determine isAllDay
                let dateInfo = try requireDateWithTimeInfo(itemObj["dueDate"]?.stringValue)

                // Parse start date
                let startDateInfo = try requireDateWithTimeInfo(itemObj["startDate"]?.stringValue)

                // Parse alarms
                let (createAlarms, _) = parseAlarmsField(itemObj)

                let request = CreateReminderRequest(
                    title: title,
                    notes: itemObj["notes"]?.stringValue,
                    listId: itemObj["listId"]?.stringValue,
                    dueDate: dateInfo?.date,
                    isAllDay: dateInfo?.isAllDay ?? false,  // false if no date
                    priority: try requirePriority(itemObj["priority"]?.stringValue),
                    recurrenceRule: recurrenceRule,
                    location: itemObj["location"]?.stringValue,
                    url: itemObj["url"]?.stringValue,
                    startDate: startDateInfo?.date,
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
    return .init(content: [.text(formatWriteResult(
        deleted: deletedReminders,
        deleteTotal: deleteIds.count,
        created: createdReminders,
        updated: updatedReminders,
        failures: failures
    ))])
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
    guard let action = arguments?["action"]?.stringValue else {
        return .missingParameter("action")
    }

    switch action.lowercased() {
    case "create":
        guard let title = arguments?["title"]?.stringValue else {
            return .missingParameter("title", for: "create")
        }
        let request = CreateListRequest(
            title: title,
            color: try requireColor(arguments?["color"]?.stringValue)
        )
        let list = try await reminderService.createList(request)
        return .init(content: [.text("Created reminder list:\n\(formatList(list))")])

    case "delete":
        guard let id = arguments?["id"]?.stringValue else {
            return .missingParameter("id", for: "delete")
        }
        try await reminderService.deleteList(id: id)
        return .init(content: [.text("Deleted reminder list: \(id)")])

    default:
        return .invalidParameter("action", value: action, expected: "Use 'create' or 'delete'")
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
        let alarmStrs = alarms.map { offset -> String in
            if offset == 0 {
                return "at time of event"
            } else if offset >= 60 && offset % 60 == 0 {
                let hours = offset / 60
                return "\(hours) hr before"
            } else {
                return "\(offset) min before"
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
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter.string(from: date)
}

private func formatDateOnly(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .none
    return formatter.string(from: date)
}

// MARK: - Parsing Helpers

enum ParseError: Error, LocalizedError {
    case invalidDateFormat(String)
    case invalidPriorityValue(String)
    case invalidFilterValue(String)
    case invalidDaysValue(String)
    case invalidColorFormat(String)
    case invalidRRule(String, String)

    var errorDescription: String? {
        switch self {
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
    guard let string = string?.lowercased() else { return nil }

    switch string {
    case "high": return .high
    case "medium": return .medium
    case "low": return .low
    case "none": return ReminderPriority.none
    default: return nil
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
private func requireFilter(_ string: String?) throws -> String {
    let value = string ?? "all"
    let validFilters = ["all", "overdue", "today", "upcoming"]
    guard validFilters.contains(value) else {
        throw ParseError.invalidFilterValue(value)
    }
    return value
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

/// Parse color with explicit error when format is invalid
private func requireColor(_ string: String?) throws -> String? {
    guard let color = string else { return nil }
    let pattern = "^#?[0-9A-Fa-f]{6}$"
    guard color.range(of: pattern, options: .regularExpression) != nil else {
        throw ParseError.invalidColorFormat(color)
    }
    return color
}

/// Parse alarms field from upsert item (3-state: missing=unchanged, null=remove, array=set)
private func parseAlarmsField(_ itemObj: [String: Value]) -> (alarms: [Int]?, remove: Bool) {
    guard let value = itemObj["alarms"] else {
        return (nil, false)
    }
    if case .null = value {
        return (nil, true)
    }
    guard let array = value.arrayValue else {
        return (nil, false)
    }
    let offsets = array.compactMap { $0.intValue }
    return (offsets.isEmpty ? nil : offsets, false)
}

/// Parse start date field from upsert item (3-state: missing=unchanged, null=remove, string=set)
private func parseStartDateField(_ itemObj: [String: Value]) throws -> (date: Date?, isAllDay: Bool?, remove: Bool) {
    guard let value = itemObj["startDate"] else {
        return (nil, nil, false)
    }
    if case .null = value {
        return (nil, nil, true)
    }
    guard let dateString = value.stringValue else {
        throw ParseError.invalidDateFormat("(non-string value)")
    }
    guard let parsed = parseDateWithTimeInfo(dateString) else {
        throw ParseError.invalidDateFormat(dateString)
    }
    return (parsed.date, !parsed.hasTime, false)
}

/// Parse recurrence field from upsert item
/// Returns (recurrenceRule, removeRecurrence) tuple
/// - If key is missing: (nil, false) - leave unchanged
/// - If key is null: (nil, true) - remove recurrence
/// - If key is string: (rrule, false) - set/update recurrence
private func parseRecurrenceField(_ itemObj: [String: Value]) throws -> (String?, Bool) {
    // Check if key exists at all
    guard let value = itemObj["recurrence"] else {
        return (nil, false)  // Key not present, leave unchanged
    }

    // Check for explicit null
    if case .null = value {
        return (nil, true)  // Explicit null means remove recurrence
    }

    // Must be a string
    guard let rrule = value.stringValue else {
        throw ParseError.invalidRRule("(non-string value)", "Recurrence must be an RRULE string")
    }

    // Validate by parsing (RRuleParser will throw if invalid)
    do {
        _ = try RRuleParser.parse(rrule)
    } catch {
        throw ParseError.invalidRRule(rrule, error.localizedDescription)
    }

    return (rrule, false)
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

    return .init(content: [.text(output)])
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

// MARK: - Value Extensions

extension Value {
    var stringValue: String? {
        if case .string(let value) = self {
            return value
        }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self {
            return value
        }
        return nil
    }

    var intValue: Int? {
        if case .int(let value) = self {
            return value
        }
        return nil
    }

    var doubleValue: Double? {
        switch self {
        case .double(let value): return value
        case .int(let value): return Double(value)
        default: return nil
        }
    }

    var arrayValue: [Value]? {
        if case .array(let values) = self {
            return values
        }
        return nil
    }

    var objectValue: [String: Value]? {
        if case .object(let dict) = self {
            return dict
        }
        return nil
    }
}
