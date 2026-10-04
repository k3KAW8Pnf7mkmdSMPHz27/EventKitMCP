import EventKit
import Foundation

extension ReminderService {
    // MARK: - Lists

    func getListsImpl() async throws -> [ReminderListModel] {
        guard let calendars = queryableCalendars() else { return [] }
        return calendars.map { EventKitMapping.mapCalendarToList($0) }
    }

    func getListImpl(id: String) async throws -> ReminderListModel? {
        guard isListAllowed(id: id) else {
            throw ReminderServiceError.listAccessDenied(id)
        }
        guard let calendar = reminderStore.calendar(withIdentifier: id) else {
            return nil
        }
        return EventKitMapping.mapCalendarToList(calendar)
    }

    func createListImpl(_ request: CreateListRequest) async throws -> ReminderListModel {
        // Block list creation when allowlist is active
        if listAccess.isRestricted {
            throw ReminderServiceError.listCreationBlocked
        }

        let calendar = EKCalendar(for: .reminder, eventStore: eventStore)
        calendar.title = request.title

        // Find the default source for reminders
        guard let source = findDefaultSource() else {
            throw ReminderServiceError.noValidSource
        }
        calendar.source = source

        if let colorHex = request.color {
            calendar.cgColor = EventKitMapping.colorFromHex(colorHex)
        }

        try reminderStore.saveCalendar(calendar, commit: true)
        logger.info("Created reminder list", metadata: ["title": "\(request.title)"])

        return EventKitMapping.mapCalendarToList(calendar)
    }

    func deleteListImpl(id: String) async throws {
        guard isListAllowed(id: id) else {
            throw ReminderServiceError.listAccessDenied(id)
        }
        guard let calendar = reminderStore.calendar(withIdentifier: id) else {
            throw ReminderServiceError.listNotFound(id)
        }

        try reminderStore.removeCalendar(calendar, commit: true)
        logger.info("Deleted reminder list", metadata: ["id": "\(id)"])
    }

    private func findDefaultSource() -> EKSource? {
        // Try to find the local source first
        if let local = reminderStore.sources.first(where: { $0.sourceType == .local }) {
            return local
        }

        // Fall back to iCloud
        if let icloud = reminderStore.sources.first(where: { $0.sourceType == .calDAV && $0.title == "iCloud" }) {
            return icloud
        }

        // Use any available source
        return reminderStore.sources.first(where: { $0.sourceType != .birthdays })
    }
}
