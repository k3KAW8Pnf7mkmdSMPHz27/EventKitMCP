import Foundation

// MARK: - Reminder Model

/// A simplified representation of a reminder for MCP transport
public struct ReminderModel: Codable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let notes: String?
    public let done: Bool
    public let priority: ReminderPriority
    public let dueDate: Date?
    public let dueTimeZone: String?
    /// True if the reminder is date-only (all-day), false if it has a specific time
    public let isAllDay: Bool
    public let doneDate: Date?
    public let listId: String
    public let listName: String
    public let creationDate: Date?
    public let lastModifiedDate: Date?
    /// Recurrence rule in RRULE format (RFC 5545), e.g., "FREQ=WEEKLY;BYDAY=MO,WE,FR"
    public let recurrenceRule: String?
    public let url: String?
    public let location: String?
    public let startDate: Date?
    public let startTimeZone: String?
    public let isStartAllDay: Bool
    public let alarms: [ReminderAlarmModel]?

    /// Convenience property for backward compatibility
    public var hasRecurrenceRules: Bool {
        recurrenceRule != nil
    }

    public init(
        id: String,
        title: String,
        notes: String? = nil,
        done: Bool = false,
        priority: ReminderPriority = .none,
        dueDate: Date? = nil,
        dueTimeZone: String? = nil,
        isAllDay: Bool = false,
        doneDate: Date? = nil,
        listId: String,
        listName: String,
        creationDate: Date? = nil,
        lastModifiedDate: Date? = nil,
        recurrenceRule: String? = nil,
        url: String? = nil,
        location: String? = nil,
        startDate: Date? = nil,
        startTimeZone: String? = nil,
        isStartAllDay: Bool = false,
        alarms: [ReminderAlarmModel]? = nil
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.done = done
        self.priority = priority
        self.dueDate = dueDate
        self.dueTimeZone = dueTimeZone
        self.isAllDay = isAllDay
        self.doneDate = doneDate
        self.listId = listId
        self.listName = listName
        self.creationDate = creationDate
        self.lastModifiedDate = lastModifiedDate
        self.recurrenceRule = recurrenceRule
        self.url = url
        self.location = location
        self.startDate = startDate
        self.startTimeZone = startTimeZone
        self.isStartAllDay = isStartAllDay
        self.alarms = alarms
    }
}

// MARK: - Reminder Priority

/// Priority levels for reminders
public enum ReminderPriority: Int, Codable, Sendable, CaseIterable {
    case none = 0
    case high = 1
    case medium = 5
    case low = 9

    public var displayName: String {
        switch self {
        case .none: return "None"
        case .high: return "High"
        case .medium: return "Medium"
        case .low: return "Low"
        }
    }

    /// Initialize from EventKit priority value (0-9)
    public init(eventKitPriority: Int) {
        switch eventKitPriority {
        case 0:
            self = .none
        case 1...4:
            self = .high
        case 5:
            self = .medium
        case 6...9:
            self = .low
        default:
            self = .none
        }
    }
}

// MARK: - Create Reminder Request

/// Parameters for creating a new reminder
public struct CreateReminderRequest: Codable, Sendable {
    public let title: String
    public let notes: String?
    public let listId: String?
    public let dueDate: Date?
    public let dueTimeZone: String?
    /// True if the reminder is date-only (all-day), false if it has a specific time
    public let isAllDay: Bool
    public let priority: ReminderPriority?
    /// Recurrence rule in RRULE format (RFC 5545)
    public let recurrenceRule: String?
    public let location: String?
    public let url: String?
    public let startDate: Date?
    public let startTimeZone: String?
    public let isStartAllDay: Bool
    public let alarms: [ReminderAlarmModel]?

    public init(
        title: String,
        notes: String? = nil,
        listId: String? = nil,
        dueDate: Date? = nil,
        dueTimeZone: String? = nil,
        isAllDay: Bool = false,
        priority: ReminderPriority? = nil,
        recurrenceRule: String? = nil,
        location: String? = nil,
        url: String? = nil,
        startDate: Date? = nil,
        startTimeZone: String? = nil,
        isStartAllDay: Bool = false,
        alarms: [ReminderAlarmModel]? = nil
    ) {
        self.title = title
        self.notes = notes
        self.listId = listId
        self.dueDate = dueDate
        self.dueTimeZone = dueTimeZone
        self.isAllDay = isAllDay
        self.priority = priority
        self.recurrenceRule = recurrenceRule
        self.location = location
        self.url = url
        self.startDate = startDate
        self.startTimeZone = startTimeZone
        self.isStartAllDay = isStartAllDay
        self.alarms = alarms
    }
}

// MARK: - Update Reminder Request

/// A three-state mutation for an optional reminder field.
public enum ReminderFieldUpdate<Value: Sendable>: Sendable {
    case unchanged
    case clear
    case set(Value)
}

extension ReminderFieldUpdate: Codable where Value: Codable {}
extension ReminderFieldUpdate: Equatable where Value: Equatable {}

/// A date and its EventKit component metadata, updated as one coherent value.
public struct ReminderDateValue: Codable, Sendable, Equatable {
    public let date: Date
    public let timeZoneIdentifier: String?
    public let isAllDay: Bool

    public init(date: Date, timeZoneIdentifier: String? = nil, isAllDay: Bool) {
        self.date = date
        self.timeZoneIdentifier = timeZoneIdentifier
        self.isAllDay = isAllDay
    }
}

/// Parameters for updating an existing reminder
public struct UpdateReminderRequest: Codable, Sendable {
    public let id: String
    public let title: String?
    public let notes: ReminderFieldUpdate<String>
    public let done: Bool?
    public let dueDate: ReminderFieldUpdate<ReminderDateValue>
    public let priority: ReminderPriority?
    public let listId: String?
    public let recurrenceRule: ReminderFieldUpdate<String>
    public let location: ReminderFieldUpdate<String>
    public let url: ReminderFieldUpdate<String>
    public let startDate: ReminderFieldUpdate<ReminderDateValue>
    public let alarms: ReminderFieldUpdate<[ReminderAlarmModel]>

    public init(
        id: String,
        title: String? = nil,
        notes: ReminderFieldUpdate<String> = .unchanged,
        done: Bool? = nil,
        dueDate: ReminderFieldUpdate<ReminderDateValue> = .unchanged,
        priority: ReminderPriority? = nil,
        listId: String? = nil,
        recurrenceRule: ReminderFieldUpdate<String> = .unchanged,
        location: ReminderFieldUpdate<String> = .unchanged,
        url: ReminderFieldUpdate<String> = .unchanged,
        startDate: ReminderFieldUpdate<ReminderDateValue> = .unchanged,
        alarms: ReminderFieldUpdate<[ReminderAlarmModel]> = .unchanged
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.done = done
        self.dueDate = dueDate
        self.priority = priority
        self.listId = listId
        self.recurrenceRule = recurrenceRule
        self.location = location
        self.url = url
        self.startDate = startDate
        self.alarms = alarms
    }
}
