import EventKitService
import Foundation

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
            let end = calendar.date(byAdding: .day, value: days + 1, to: today)
        else { return [] }
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
