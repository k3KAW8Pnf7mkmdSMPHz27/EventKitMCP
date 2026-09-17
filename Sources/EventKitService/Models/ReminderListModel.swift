import Foundation

// MARK: - Reminder List Model

/// A simplified representation of a reminder list (calendar) for MCP transport
public struct ReminderListModel: Sendable, Identifiable {
    public let id: String
    public let title: String
    public let color: String?
    public let isSubscribed: Bool
    public let isImmutable: Bool
    public let sourceTitle: String?
    public let reminderCount: Int?

    public init(
        id: String,
        title: String,
        color: String? = nil,
        isSubscribed: Bool = false,
        isImmutable: Bool = false,
        sourceTitle: String? = nil,
        reminderCount: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.color = color
        self.isSubscribed = isSubscribed
        self.isImmutable = isImmutable
        self.sourceTitle = sourceTitle
        self.reminderCount = reminderCount
    }
}

// MARK: - Create List Request

/// Parameters for creating a new reminder list
public struct CreateListRequest: Sendable {
    public let title: String
    public let color: String?

    public init(title: String, color: String? = nil) {
        self.title = title
        self.color = color
    }
}
