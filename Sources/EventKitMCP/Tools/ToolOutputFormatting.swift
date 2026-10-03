import EventKitService
import Foundation

// MARK: - Structured Output

private func formatISO8601(_ date: Date) -> String {
    Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(date)
}

extension ReminderModel {
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

extension ReminderListModel {
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

// MARK: - Formatting Helpers

func formatReminders(_ reminders: [ReminderModel]) -> String {
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

func formatLists(_ lists: [ReminderListModel]) -> String {
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

func formatList(_ list: ReminderListModel) -> String {
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
