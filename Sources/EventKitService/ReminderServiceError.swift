import Foundation

// MARK: - Errors

/// Errors that can occur during reminder operations
public enum ReminderServiceError: Error, LocalizedError, Equatable {
    case accessDenied
    case listNotFound(String)
    case reminderNotFound(String)
    case noValidSource
    case listAccessDenied(String)
    /// No `listId` was given and the default list is outside the allowlist; names no list, since the caller supplied none.
    case defaultListNotAllowed
    /// A reminder exists but sits outside the allowlist.
    ///
    /// Carries only the caller-supplied reminder ID and describes itself exactly as
    /// `reminderNotFound`, so a caller can't confirm that a guessed ID exists outside its
    /// allowed lists, nor learn which list holds it.
    case reminderAccessDenied(String)
    case listCreationBlocked
    case invalidURL(String)
    case invalidTimeZone(String)
    case invalidAlarm
    case relativeAlarmRequiresStartDate
    case operationTimedOut

    public var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "Access to reminders was denied"
        case .listNotFound(let id):
            return "Reminder list not found: \(id)"
        case .reminderNotFound(let id), .reminderAccessDenied(let id):
            return "Reminder not found: \(id)"
        case .noValidSource:
            return "No valid source found for creating reminder lists"
        case .listAccessDenied(let id):
            return "Access to reminder list '\(id)' is not allowed"
        case .defaultListNotAllowed:
            return "The default reminder list is outside --allowed-lists; pass listId"
        case .listCreationBlocked:
            return "Creating new reminder lists is not allowed when --allowed-lists is active"
        case .invalidURL(let value):
            return "Invalid URL: '\(value)'"
        case .invalidTimeZone(let identifier):
            return "Unknown time zone: '\(identifier)'"
        case .invalidAlarm:
            return "Invalid alarm definition"
        case .relativeAlarmRequiresStartDate:
            return "Relative alarms require a start date"
        case .operationTimedOut:
            return "The EventKit operation timed out"
        }
    }
}
