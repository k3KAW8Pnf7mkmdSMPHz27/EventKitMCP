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

/// Input schema for query_reminders tool - unified query interface
@Schemable
struct QueryRemindersInput {
    /// Filter: "all" (default), "overdue", "today", "upcoming"
    var filter: String?
    /// Days for "upcoming" filter (default: 7)
    var days: Int?
    /// List ID to filter by
    var listId: String?
    /// Regex search pattern for id/title/notes
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
    /// Start date in ISO 8601 format. Set to null to remove existing start date.
    var startDate: String?
    /// Priority: none, low, medium, high
    var priority: String?
    /// Target list ID (for create or move)
    var listId: String?
    /// Recurrence rule in RRULE format (RFC 5545). Examples: "FREQ=DAILY", "FREQ=WEEKLY;BYDAY=MO,WE,FR", "FREQ=MONTHLY;BYDAY=2TU;COUNT=10". Set to null to remove existing recurrence.
    var recurrence: String?
    /// Location text
    var location: String?
    /// URL to attach to the reminder
    var url: String?
    /// Alarm offsets in minutes before due date (e.g., [0, 15, 60] = at time, 15min before, 1hr before). Set to null to remove all alarms.
    var alarms: [Int]?
}

// MARK: - List Operations

/// Input schema for manage_reminder_list tool - create or delete lists
@Schemable
struct ManageReminderListInput {
    /// Action to perform: "create" or "delete"
    var action: String
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
