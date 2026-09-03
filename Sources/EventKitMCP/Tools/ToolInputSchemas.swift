import Foundation
import JSONSchema
import JSONSchemaBuilder
import MCP

// MARK: - Schema to MCP Value Bridge

/// Namespace for schema conversion utilities
enum SchemaHelpers {
    /// Converts a JSONSchemaBuilder schema to MCP's Value type for tool input schemas
    static func schemaToValue<T: Schemable>(_ type: T.Type) -> Value {
        let definition = T.schema.definition()

        // Encode the schema definition to JSON, then decode to dictionary
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        guard let jsonData = try? encoder.encode(definition),
              let jsonObject = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            // Fallback to empty object schema if encoding fails
            return .object(["type": .string("object")])
        }

        return convertJSONToValue(jsonObject)
    }

    /// Recursively converts JSONSchema dictionary to MCP Value
    private static func convertJSONToValue(_ json: [String: Any]) -> Value {
        var result: [String: Value] = [:]

        for (key, value) in json {
            result[key] = anyToValue(value)
        }

        return .object(result)
    }

    private static func anyToValue(_ value: Any) -> Value {
        switch value {
        case let string as String:
            return .string(string)
        case let int as Int:
            return .int(int)
        case let double as Double:
            return .double(double)
        case let bool as Bool:
            return .bool(bool)
        case let array as [Any]:
            return .array(array.map { anyToValue($0) })
        case let dict as [String: Any]:
            return convertJSONToValue(dict)
        default:
            return .null
        }
    }
}

// MARK: - Query Reminders (unified query tool)

@Schemable
enum QueryFilter: String, Codable, CaseIterable {
    case all, overdue, today, upcoming
}

@Schemable
enum ReminderPriorityInput: String, Codable, CaseIterable {
    case none, low, medium, high
}

@Schemable
enum ReminderListAction: String, Codable, CaseIterable {
    case create, delete
}

/// Input schema for query_reminders tool - unified query interface
@Schemable
struct QueryRemindersInput {
    /// Filter: "all" (default), "overdue", "today", "upcoming"
    var filter: QueryFilter?
    /// Days for "upcoming" filter (default: 7)
    var days: Int?
    /// List ID to filter by
    var listId: String?
    /// Regex search pattern for id/title/notes, applied within the selected list and time filter
    var search: String?
    /// Include done reminders (default: false)
    var includeDone: Bool?
}

// MARK: - Write Reminders (unified upsert + delete)

/// Input schema for write_reminders tool
@Schemable
struct WriteRemindersInput {
    /// Reminders to create (no id) or update (with id)
    var upsert: [UpsertReminderItem]?
    /// Reminder IDs to permanently delete. Prefer setting done=true for finished tasks—only delete duplicates, mistakes, or when user explicitly requests deletion
    var delete: [String]?
}

/// A reminder to create or update
@Schemable
struct UpsertReminderItem {
    /// ID of existing reminder to update (omit to create new)
    var id: String?
    /// Title (required for create, optional for update)
    var title: String?
    /// Notes
    var notes: String?
    /// Mark done (true) or not done (false). Preferred way to handle finished tasks—preserves history unlike delete
    var done: Bool?
    /// Due date in ISO 8601 format
    var dueDate: String?
    /// IANA time-zone identifier for dueDate; omit for a floating date.
    var dueTimeZone: String?
    /// Start date in ISO 8601 format. Set to null to remove existing start date.
    var startDate: String?
    /// IANA time-zone identifier for startDate; omit for a floating date.
    var startTimeZone: String?
    /// Priority: none, low, medium, high
    var priority: ReminderPriorityInput?
    /// Target list ID (for create or move)
    var listId: String?
    /// Recurrence rule in RRULE format (RFC 5545). Examples: "FREQ=DAILY", "FREQ=WEEKLY;BYDAY=MO,WE,FR", "FREQ=MONTHLY;BYDAY=2TU;COUNT=10". Set to null to remove existing recurrence.
    var recurrence: String?
    /// Location text
    var location: String?
    /// URL to attach to the reminder
    var url: String?
    /// Relative, absolute, or location alarms. Relative alarms use the reminder start date. Set to null to remove all alarms.
    var alarms: [ReminderAlarmInput]?
}

@Schemable
struct ReminderAlarmInput {
    /// Alarm kind: relative, absolute, or location.
    var kind: String
    /// Non-negative minutes before startDate for a relative alarm.
    var minutesBefore: Int?
    /// ISO 8601 timestamp for an absolute alarm.
    var absoluteDate: String?
    /// enter or leave for a location alarm.
    var proximity: String?
    var title: String?
    var latitude: Double?
    var longitude: Double?
    var radius: Double?
}

// MARK: - List Operations

/// Input schema for manage_reminder_list tool - create or delete lists
@Schemable
struct ManageReminderListInput {
    /// Action to perform: "create" or "delete"
    var action: ReminderListAction
    /// Title for create action
    var title: String?
    /// Hex color for create action (e.g., "#FF5733")
    var color: String?
    /// List ID for delete action
    var id: String?
}

// MARK: - Overview

/// Input schema for overview tool (no parameters needed)
@Schemable
struct OverviewInput {}

// MARK: - Empty Input (for tools with no parameters)

/// Input schema for tools with no parameters
@Schemable
struct EmptyInput {}

// MARK: - Output contracts

@Schemable
struct AlarmOutput: Codable {
    var kind: String
    var minutesBefore: Int?
    var absoluteDate: String?
    var proximity: String?
    var title: String?
    var latitude: Double?
    var longitude: Double?
    var radius: Double?
}

@Schemable
struct ReminderOutput: Codable {
    var id: String
    var title: String
    var notes: String?
    var done: Bool
    var priority: String
    var dueDate: String?
    var dueTimeZone: String?
    var isAllDay: Bool
    var doneDate: String?
    var listId: String
    var listName: String
    var recurrence: String?
    var url: String?
    var location: String?
    var startDate: String?
    var startTimeZone: String?
    var isStartAllDay: Bool
    var alarms: [AlarmOutput]?
}

@Schemable
struct FailureOutput: Codable {
    var id: String
    var error: String
}

@Schemable
struct QueryRemindersOutput: Codable {
    var count: Int
    var reminders: [ReminderOutput]
}

@Schemable
struct WriteRemindersOutput: Codable {
    var deleted: [ReminderOutput]
    var created: [ReminderOutput]
    var updated: [ReminderOutput]
    var failures: [FailureOutput]
}

@Schemable
struct ReminderListOutput: Codable {
    var id: String
    var title: String
    var color: String?
    var isSubscribed: Bool
    var isImmutable: Bool
    var sourceTitle: String?
}

@Schemable
struct GetReminderListsOutput: Codable {
    var lists: [ReminderListOutput]
}

@Schemable
struct ManageReminderListOutput: Codable {
    var action: String
    var id: String
    var list: ReminderListOutput?
}

@Schemable
struct OverviewOutput: Codable {
    var listCount: Int
    var incompleteCount: Int
    var overdueCount: Int
    var todayCount: Int
    var upcomingCount: Int
    var attentionCount: Int
}
