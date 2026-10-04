import EventKitService
import Foundation

/// What the overview reports, computed once and rendered both as text and as structured output.
struct OverviewSnapshot {
    static let upcomingDays = 7
    static let overdueShown = 10

    struct ListStats {
        let list: ReminderListModel
        var incomplete = 0
        var overdue = 0
        var high = 0
        var medium = 0
    }

    let now: Date
    let listCount: Int
    let incompleteCount: Int
    let scheduledCount: Int
    /// Lists with incomplete reminders, in list order.
    let listStats: [ListStats]
    let attention: [ReminderModel]
    let overdue: [ReminderModel]
    let today: [ReminderModel]
    let upcoming: [ReminderModel]
    /// Upcoming reminders counted per local calendar day, earliest first.
    let upcomingByDay: [(day: Date, count: Int)]

    init(lists: [ReminderListModel], reminders: [ReminderModel], now: Date) {
        self.now = now
        listCount = lists.count
        incompleteCount = reminders.count
        scheduledCount = reminders.count(where: { $0.dueDate != nil })
        attention = ReminderFilters.needsAttention(reminders)
        overdue = ReminderFilters.overdue(reminders, before: now)
        today = ReminderFilters.today(reminders, relativeTo: now)
        upcoming = ReminderFilters.upcoming(reminders, days: Self.upcomingDays, from: now)

        let overdueIds = Set(overdue.map(\.id))
        var stats = Dictionary(lists.map { ($0.id, ListStats(list: $0)) }) { first, _ in first }
        for reminder in reminders {
            stats[reminder.listId]?.incomplete += 1
            if overdueIds.contains(reminder.id) { stats[reminder.listId]?.overdue += 1 }
            if reminder.priority == .high { stats[reminder.listId]?.high += 1 }
            if reminder.priority == .medium { stats[reminder.listId]?.medium += 1 }
        }
        listStats = lists.compactMap { stats[$0.id] }.filter { $0.incomplete > 0 }

        let calendar = Calendar.current
        let byDay = Dictionary(grouping: upcoming.compactMap(\.dueDate)) { calendar.startOfDay(for: $0) }
        upcomingByDay = byDay.keys.sorted().map { ($0, byDay[$0]?.count ?? 0) }
    }

    var unscheduledOtherCount: Int { incompleteCount - scheduledCount - attention.count }

    var output: OverviewOutput {
        let day = Date.ISO8601FormatStyle(timeZone: .current).year().month().day()
        return OverviewOutput(
            listCount: listCount,
            incompleteCount: incompleteCount,
            overdueCount: overdue.count,
            todayCount: today.count,
            upcomingCount: upcoming.count,
            attentionCount: attention.count,
            lists: listStats.map {
                ListStatsOutput(
                    id: $0.list.id,
                    title: $0.list.title,
                    incompleteCount: $0.incomplete,
                    overdueCount: $0.overdue,
                    highPriorityCount: $0.high,
                    mediumPriorityCount: $0.medium
                )
            },
            attention: attention.map(\.output),
            overdue: overdue.prefix(Self.overdueShown).map(\.output),
            today: today.map(\.output),
            upcomingByDay: upcomingByDay.map { UpcomingDayOutput(date: day.format($0.day), count: $0.count) }
        )
    }

    func render() -> String {
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
            "SUMMARY: \(scheduledCount) scheduled (\(overdue.count) overdue, \(today.count) today, \(upcoming.count) upcoming) + \(attention.count) unscheduled high/medium priority + \(unscheduledOtherCount) other unscheduled"
        )
        lines.append("")

        if !listStats.isEmpty {
            lines.append("LISTS:")
            for stats in listStats {
                var parts = ["\(stats.incomplete) incomplete"]
                if stats.overdue > 0 { parts.append("\(stats.overdue) overdue") }
                if stats.high > 0 { parts.append("\(stats.high) high") }
                if stats.medium > 0 { parts.append("\(stats.medium) medium") }
                lines.append("- \(stats.list.title): \(parts.joined(separator: ", "))")
            }
        }

        if !attention.isEmpty {
            lines.append("")
            lines.append("ATTENTION (high/medium priority, no due date):")
            for r in attention {
                lines.append("- \(r.title)\(priorityLabel(r.priority)) in \(r.listName)")
            }
        }

        if !overdue.isEmpty {
            lines.append("")
            lines.append("OVERDUE:")
            for r in overdue.prefix(Self.overdueShown) {
                let dueStr = r.dueDate.map(monthDay) ?? ""
                lines.append("- \(r.title)\(priorityLabel(r.priority)) in \(r.listName), due \(dueStr)")
            }
            if overdue.count > Self.overdueShown {
                lines.append("... and \(overdue.count - Self.overdueShown) more overdue")
            }
        }

        if !today.isEmpty {
            lines.append("")
            lines.append("TODAY:")
            for r in today {
                let timeStr = timeOnly(r)
                if timeStr.isEmpty {
                    lines.append("- \(r.title)\(priorityLabel(r.priority)) in \(r.listName)")
                } else {
                    lines.append("- \(r.title)\(priorityLabel(r.priority)) in \(r.listName) at \(timeStr)")
                }
            }
        }

        if !upcomingByDay.isEmpty {
            lines.append("")
            lines.append("UPCOMING (\(Self.upcomingDays) days):")
            for (day, count) in upcomingByDay {
                lines.append("- \(monthDay(day)): \(count) reminder\(count == 1 ? "" : "s")")
            }
        }

        lines.append("")
        if overdue.count > Self.overdueShown {
            lines.append(
                "TIPS: Notes hidden. query_reminders shows full details. \(overdue.count) overdue total (\(Self.overdueShown) shown)."
            )
        } else {
            lines.append("TIPS: Notes hidden. query_reminders shows full details (notes, URLs, recurrence).")
        }

        return lines.joined(separator: "\n")
    }
}

private func priorityLabel(_ priority: ReminderPriority) -> String {
    switch priority {
    case .high: return " (high)"
    case .medium: return " (medium)"
    case .low, .none: return ""
    }
}

private func monthDay(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "MMM d"
    return formatter.string(from: date)
}

private func timeOnly(_ reminder: ReminderModel) -> String {
    guard !reminder.isAllDay, let date = reminder.dueDate else { return "" }
    let formatter = DateFormatter()
    formatter.timeStyle = .short
    formatter.dateStyle = .none
    return formatter.string(from: date)
}
