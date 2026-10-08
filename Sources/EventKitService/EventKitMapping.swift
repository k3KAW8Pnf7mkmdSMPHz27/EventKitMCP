import CoreLocation
import EventKit
import Foundation

/// Conversions between EventKit objects and the service models; no store access.
enum EventKitMapping {
    static func mapCalendarToList(_ calendar: EKCalendar) -> ReminderListModel {
        ReminderListModel(
            id: calendar.calendarIdentifier,
            title: calendar.title,
            color: hexFromColor(calendar.cgColor),
            isSubscribed: calendar.isSubscribed,
            isImmutable: calendar.isImmutable,
            sourceTitle: calendar.source?.title
        )
    }

    static func mapReminderToModel(_ reminder: EKReminder) -> ReminderModel {
        let dueDate: Date?
        let isAllDay: Bool

        if let components = reminder.dueDateComponents {
            dueDate = calendar(for: components).date(from: components)
            // Date-only if hour component is nil (not just 0)
            isAllDay = components.hour == nil
        } else {
            dueDate = nil
            isAllDay = false
        }

        // Extract start date
        let startDate: Date?
        let isStartAllDay: Bool

        if let components = reminder.startDateComponents {
            startDate = calendar(for: components).date(from: components)
            isStartAllDay = components.hour == nil
        } else {
            startDate = nil
            isStartAllDay = false
        }

        // Convert recurrence rule to RRULE string
        let recurrenceRule: String? = reminder.recurrenceRules?.first.map { RRuleParser.format($0) }

        let alarmModels: [ReminderAlarmModel]?
        if let ekAlarms = reminder.alarms, !ekAlarms.isEmpty {
            alarmModels = ekAlarms.compactMap(mapAlarm)
        } else {
            alarmModels = nil
        }

        return ReminderModel(
            id: reminder.calendarItemIdentifier,
            title: reminder.title ?? "",
            // The store saves cleared notes as "", which callers cleared with null.
            notes: reminder.notes?.isEmpty == false ? reminder.notes : nil,
            done: reminder.isCompleted,
            priority: ReminderPriority(eventKitPriority: reminder.priority),
            dueDate: dueDate,
            dueTimeZone: reminder.dueDateComponents?.timeZone?.identifier,
            isAllDay: isAllDay,
            doneDate: reminder.completionDate,
            listId: reminder.calendar.calendarIdentifier,
            listName: reminder.calendar.title,
            recurrenceRule: recurrenceRule,
            url: reminder.url?.absoluteString,
            startDate: startDate,
            startTimeZone: reminder.startDateComponents?.timeZone?.identifier,
            isStartAllDay: isStartAllDay,
            alarms: alarmModels
        )
    }

    private static func calendar(for components: DateComponents) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        if let timeZone = components.timeZone { calendar.timeZone = timeZone }
        return calendar
    }

    static func dateComponents(from value: ReminderDateValue) throws -> DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        if let identifier = value.timeZoneIdentifier {
            guard let timeZone = TimeZone(identifier: identifier) else {
                throw ReminderServiceError.invalidTimeZone(identifier)
            }
            calendar.timeZone = timeZone
        }
        var components = calendar.dateComponents(
            value.isAllDay ? [.year, .month, .day] : [.year, .month, .day, .hour, .minute],
            from: value.date
        )
        components.timeZone = value.timeZoneIdentifier == nil ? nil : calendar.timeZone
        return components
    }

    static func validatedURL(_ string: String) throws -> URL {
        guard let url = URL(string: string), let scheme = url.scheme, !scheme.isEmpty else {
            throw ReminderServiceError.invalidURL(string)
        }
        return url
    }

    /// EventKit alarms for these models; relative ones need a due date and a non-negative offset.
    /// Reminders counts a relative alarm back from the due date, whatever the start date is.
    static func makeAlarms(_ models: [ReminderAlarmModel], hasDueDate: Bool) throws -> [EKAlarm] {
        try models.map { model in
            if case .relative(let minutes) = model {
                guard hasDueDate else { throw ReminderServiceError.relativeAlarmRequiresDueDate }
                guard minutes >= 0 else { throw ReminderServiceError.invalidAlarm }
            }
            return makeAlarm(model)
        }
    }

    private static func makeAlarm(_ model: ReminderAlarmModel) -> EKAlarm {
        switch model {
        case .relative(let minutes):
            return EKAlarm(relativeOffset: TimeInterval(-minutes * 60))
        case .absolute(let date):
            return EKAlarm(absoluteDate: date)
        case .location(let location, let proximity):
            let structured = EKStructuredLocation(title: location.title)
            structured.geoLocation = CLLocation(latitude: location.latitude, longitude: location.longitude)
            structured.radius = location.radius
            let alarm = EKAlarm()
            alarm.structuredLocation = structured
            alarm.proximity = proximity == .enter ? .enter : proximity == .leave ? .leave : .none
            return alarm
        }
    }

    static func mapAlarm(_ alarm: EKAlarm) -> ReminderAlarmModel? {
        if let structured = alarm.structuredLocation, let coordinate = structured.geoLocation?.coordinate {
            let proximity: ReminderAlarmModel.Proximity =
                switch alarm.proximity {
                case .enter: .enter
                case .leave: .leave
                default: .none
                }
            return .location(
                .init(
                    title: structured.title ?? "",
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude,
                    radius: structured.radius
                ),
                proximity: proximity
            )
        }
        if let date = alarm.absoluteDate { return .absolute(date) }
        return .relative(minutesBefore: Int(-alarm.relativeOffset / 60))
    }

    static func colorFromHex(_ hex: String) -> CGColor? {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        // Reject rather than silently yielding black: the return type promises failure is
        // representable, and callers outside this module do not pass through requireColor.
        guard hexSanitized.count == 6 else { return nil }
        var rgb: UInt64 = 0
        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else { return nil }

        let red = CGFloat((rgb & 0xFF0000) >> 16) / 255.0
        let green = CGFloat((rgb & 0x00FF00) >> 8) / 255.0
        let blue = CGFloat(rgb & 0x0000FF) / 255.0

        // Hex colours are sRGB; CGColor(red:green:blue:alpha:) is Generic RGB, which the store shifts.
        return CGColor(srgbRed: red, green: green, blue: blue, alpha: 1.0)
    }

    static func hexFromColor(_ cgColor: CGColor?) -> String? {
        guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
            let color = cgColor?.converted(to: sRGB, intent: .defaultIntent, options: nil),
            let components = color.components,
            components.count >= 3
        else {
            return nil
        }

        let red = Int((components[0] * 255).rounded())
        let green = Int((components[1] * 255).rounded())
        let blue = Int((components[2] * 255).rounded())

        return String(format: "#%02X%02X%02X", red, green, blue)
    }
}
