import EventKit
import Foundation
import Testing

@testable import EventKitService

/// Drives create, update and delete against `StubReminderStore`. Each case builds its
/// own fixture and reads EventKit objects back through the stub, never from the actor.
@Suite("Reminder service write path")
struct ReminderServiceWriteTests {
    /// 2026-01-06 01:30 UTC, which is 10:30 the same day in Tokyo.
    private static let instant = Date(timeIntervalSince1970: 1_767_663_000)

    private struct Fixture {
        let service: ReminderService
        let store: StubReminderStore
        let workId: String
        let homeId: String
        let existingId: String
        let hiddenId: String

        func reminder(_ id: String) throws -> EKReminder {
            try #require(store.calendarItem(withIdentifier: id) as? EKReminder)
        }
    }

    /// Work and Home lists with one reminder each; `allowed` builds the allowlist from their IDs.
    private static func fixture(
        defaultToHome: Bool = false,
        allowed: (_ work: String, _ home: String) -> Set<String>? = { _, _ in nil }
    ) -> Fixture {
        let eventStore = EKEventStore()
        let work = EKCalendar(for: .reminder, eventStore: eventStore)
        work.title = "Work"
        let home = EKCalendar(for: .reminder, eventStore: eventStore)
        home.title = "Home"
        let existing = EKReminder(eventStore: eventStore)
        existing.calendar = work
        existing.title = "Existing"
        let hidden = EKReminder(eventStore: eventStore)
        hidden.calendar = home
        hidden.title = "Hidden"
        let store = StubReminderStore(
            calendars: [work, home],
            reminders: [existing, hidden],
            defaultCalendar: defaultToHome ? home : work
        )
        let ids = (work.calendarIdentifier, home.calendarIdentifier)
        let reminderIds = (existing.calendarItemIdentifier, hidden.calendarItemIdentifier)
        let service = ReminderService(
            eventStore: eventStore,
            reminderStore: store,
            allowedListIds: allowed(ids.0, ids.1),
            operationTimeout: .seconds(2)
        )
        return Fixture(
            service: service, store: store, workId: ids.0, homeId: ids.1,
            existingId: reminderIds.0, hiddenId: reminderIds.1
        )
    }

    // MARK: - Create

    @Test("Create writes every field to the reminder it saves")
    func createWritesEveryField() async throws {
        let f = Self.fixture()
        let model = try await f.service.createReminder(
            CreateReminderRequest(
                title: "New",
                notes: "Bring slides",
                listId: f.workId,
                dueDate: Self.instant,
                dueTimeZone: "Asia/Tokyo",
                priority: .high,
                recurrenceRule: "FREQ=WEEKLY",
                location: "Office",
                url: "https://example.com/a",
                startDate: Self.instant,
                startTimeZone: "Asia/Tokyo",
                alarms: [.relative(minutesBefore: 10), .absolute(Self.instant)]
            ))

        #expect(f.store.saved.count == 1)
        let saved = try #require(f.store.saved.last)
        #expect(model.id == saved.calendarItemIdentifier)
        #expect(saved.calendar.calendarIdentifier == f.workId)
        #expect(saved.title == "New")
        #expect(saved.notes == "Bring slides")
        #expect(saved.priority == ReminderPriority.high.rawValue)
        #expect(saved.location == "Office")
        #expect(saved.url?.absoluteString == "https://example.com/a")
        #expect(saved.recurrenceRules?.map(RRuleParser.format) == ["FREQ=WEEKLY"])
        #expect(sameAlarms(saved.alarms, [.relative(minutesBefore: 10), .absolute(Self.instant)]))
        for components in [saved.dueDateComponents, saved.startDateComponents] {
            let parts = try #require(components)
            #expect(parts.timeZone?.identifier == "Asia/Tokyo")
            #expect([parts.year, parts.month, parts.day, parts.hour, parts.minute] == [2026, 1, 6, 10, 30])
        }
    }

    @Test("A floating all-day due date is stored as a calendar day with no zone")
    func createFloatingAllDay() async throws {
        let f = Self.fixture()
        _ = try await f.service.createReminder(CreateReminderRequest(title: "x", dueDate: Self.instant, isAllDay: true))
        let due = try #require(f.store.saved.last?.dueDateComponents)
        var local = Calendar(identifier: .gregorian)
        local.timeZone = .current
        let localDay = local.dateComponents([.year, .month, .day], from: Self.instant)
        #expect(due.timeZone == nil)
        #expect([due.year, due.month, due.day] == [localDay.year, localDay.month, localDay.day])
        #expect(due.hour == nil && due.minute == nil)
    }

    // EventKit keeps one zone and one all-day form per reminder, and setting the start
    // date rewrites the due date to match. The server sets due first, so start wins.
    @Test("Due and start share one zone and all-day form, and the start date's wins")
    func startDateRewritesDueDate() async throws {
        let f = Self.fixture()
        _ = try await f.service.createReminder(
            CreateReminderRequest(
                title: "x", dueDate: Self.instant, dueTimeZone: "Asia/Tokyo", startDate: Self.instant,
                startTimeZone: "Europe/Paris"))
        let rezoned = try #require(f.store.saved.last?.dueDateComponents)
        #expect(rezoned.timeZone?.identifier == "Europe/Paris")
        #expect([rezoned.day, rezoned.hour, rezoned.minute] == [6, 2, 30])

        _ = try await f.service.createReminder(
            CreateReminderRequest(
                title: "y", dueDate: Self.instant, dueTimeZone: "Asia/Tokyo", startDate: Self.instant,
                isStartAllDay: true))
        let flattened = try #require(f.store.saved.last?.dueDateComponents)
        #expect(flattened.timeZone == nil)
        #expect(flattened.hour == nil)
    }

    @Test("Create without a list uses the default list")
    func createUsesDefaultList() async throws {
        let f = Self.fixture()
        let model = try await f.service.createReminder(CreateReminderRequest(title: "Default"))
        #expect(model.listId == f.workId)
        #expect(try #require(f.store.saved.last).calendar.calendarIdentifier == f.workId)
    }

    @Test("Create checks the allowlist before looking the list up")
    func createListPrecedence() async throws {
        for target in ["home", "gone-and-hidden", "gone-but-allowed"] {
            let f = Self.fixture { work, _ in [work, "gone-but-allowed"] }
            let listId = target == "home" ? f.homeId : target
            let expected: ReminderServiceError =
                target == "gone-but-allowed" ? .listNotFound(listId) : .listAccessDenied(listId)
            await #expect(throws: expected) {
                try await f.service.createReminder(CreateReminderRequest(title: "x", listId: listId))
            }
            #expect(f.store.saved.isEmpty, "\(target)")
        }
    }

    @Test("Create refuses a default list outside the allowlist and names it")
    func createHiddenDefaultList() async throws {
        let f = Self.fixture(defaultToHome: true) { work, _ in [work] }
        await #expect(throws: ReminderServiceError.listAccessDenied(f.homeId)) {
            try await f.service.createReminder(CreateReminderRequest(title: "x"))
        }
        #expect(f.store.saved.isEmpty)
    }

    @Test("Create refuses a relative alarm without a start date and saves nothing")
    func createRelativeAlarmNeedsStart() async throws {
        let f = Self.fixture()
        await #expect(throws: ReminderServiceError.relativeAlarmRequiresStartDate) {
            try await f.service.createReminder(
                CreateReminderRequest(title: "x", alarms: [.relative(minutesBefore: 5)]))
        }
        #expect(f.store.saved.isEmpty)
    }

    // MARK: - Update

    @Test("Update sets, replaces, keeps and clears every three-state field")
    func updateThreeStateFields() async throws {
        let f = Self.fixture()
        let reminder = try f.reminder(f.existingId)

        _ = try await f.service.updateReminder(
            UpdateReminderRequest(
                id: f.existingId,
                notes: .set("n"),
                dueDate: .set(ReminderDateValue(date: Self.instant, timeZoneIdentifier: "Asia/Tokyo", isAllDay: false)),
                recurrenceRule: .set("FREQ=DAILY"),
                location: .set("Office"),
                url: .set("https://example.com"),
                startDate: .set(
                    ReminderDateValue(date: Self.instant, timeZoneIdentifier: "Asia/Tokyo", isAllDay: true)),
                alarms: .set([.relative(minutesBefore: 5)])
            ))
        #expect(reminder.notes == "n")
        #expect(reminder.startDateComponents?.timeZone?.identifier == "Asia/Tokyo")
        #expect(reminder.startDateComponents?.day == 6 && reminder.startDateComponents?.hour == nil)
        #expect(reminder.location == "Office")
        #expect(reminder.url?.absoluteString == "https://example.com")

        _ = try await f.service.updateReminder(
            UpdateReminderRequest(
                id: f.existingId,
                recurrenceRule: .set("FREQ=WEEKLY"),
                alarms: .set([.relative(minutesBefore: 30), .absolute(Self.instant)])
            ))
        #expect(reminder.recurrenceRules?.map(RRuleParser.format) == ["FREQ=WEEKLY"])
        #expect(sameAlarms(reminder.alarms, [.relative(minutesBefore: 30), .absolute(Self.instant)]))

        _ = try await f.service.updateReminder(UpdateReminderRequest(id: f.existingId, title: "Renamed"))
        #expect(reminder.title == "Renamed")
        #expect(reminder.notes == "n" && reminder.location == "Office" && reminder.url != nil)
        #expect(reminder.dueDateComponents != nil && reminder.startDateComponents != nil)
        #expect(reminder.recurrenceRules?.count == 1 && reminder.alarms?.count == 2)

        _ = try await f.service.updateReminder(
            UpdateReminderRequest(
                id: f.existingId, notes: .clear, dueDate: .clear, recurrenceRule: .clear, location: .clear,
                url: .clear, startDate: .clear, alarms: .clear
            ))
        #expect(reminder.notes == nil && reminder.location == nil && reminder.url == nil)
        #expect(reminder.dueDateComponents == nil && reminder.startDateComponents == nil)
        #expect((reminder.recurrenceRules ?? []).isEmpty && (reminder.alarms ?? []).isEmpty)
        #expect(f.store.saved.count == 4)
    }

    // EventKit stamps the completion date, in whole seconds, every time the flag is set,
    // even on a reminder already done. So a second `done: true` moves it.
    @Test("Completing stamps a completion date and reopening clears it")
    func completionDate() async throws {
        let f = Self.fixture()
        let reminder = try f.reminder(f.existingId)

        _ = try await f.service.updateReminder(UpdateReminderRequest(id: f.existingId, done: true))
        #expect(reminder.isCompleted)
        #expect(reminder.completionDate != nil)

        _ = try await f.service.updateReminder(UpdateReminderRequest(id: f.existingId, done: false))
        #expect(!reminder.isCompleted)
        #expect(reminder.completionDate == nil)
    }

    @Test("Update applies the start date before validating relative alarms")
    func startDateBeforeAlarms() async throws {
        let f = Self.fixture()
        _ = try await f.service.updateReminder(
            UpdateReminderRequest(
                id: f.existingId,
                startDate: .set(ReminderDateValue(date: Self.instant, isAllDay: false)),
                alarms: .set([.relative(minutesBefore: 5)])
            ))
        #expect(try f.reminder(f.existingId).alarms?.count == 1)

        await #expect(throws: ReminderServiceError.relativeAlarmRequiresStartDate) {
            try await f.service.updateReminder(
                UpdateReminderRequest(id: f.existingId, startDate: .clear, alarms: .set([.relative(minutesBefore: 5)])))
        }
        #expect(f.store.saved.count == 1)
    }

    @Test("Moving a reminder checks the allowlist before looking the target list up")
    func moveListPrecedence() async throws {
        for target in ["home", "gone-and-hidden", "gone-but-allowed"] {
            let f = Self.fixture { work, _ in [work, "gone-but-allowed"] }
            let listId = target == "home" ? f.homeId : target
            let expected: ReminderServiceError =
                target == "gone-but-allowed" ? .listNotFound(listId) : .listAccessDenied(listId)
            await #expect(throws: expected) {
                try await f.service.updateReminder(UpdateReminderRequest(id: f.existingId, listId: listId))
            }
            #expect(f.store.saved.isEmpty, "\(target)")
        }

        let f = Self.fixture()
        _ = try await f.service.updateReminder(UpdateReminderRequest(id: f.existingId, listId: f.homeId))
        #expect(try f.reminder(f.existingId).calendar.calendarIdentifier == f.homeId)
    }

    // MARK: - Hidden and missing reminders

    @Test("A reminder in a hidden list reads, updates and deletes like a missing one")
    func hiddenReminderLooksMissing() async throws {
        let f = Self.fixture { work, _ in [work] }

        #expect(try await f.service.getReminder(id: f.hiddenId) == nil)
        #expect(try await f.service.getReminder(id: "missing") == nil)
        #expect(try await f.service.getReminder(id: f.existingId)?.title == "Existing")

        await #expect(throws: ReminderServiceError.reminderAccessDenied(f.hiddenId)) {
            try await f.service.updateReminder(UpdateReminderRequest(id: f.hiddenId, title: "x"))
        }
        await #expect(throws: ReminderServiceError.reminderNotFound("missing")) {
            try await f.service.updateReminder(UpdateReminderRequest(id: "missing", title: "x"))
        }
        await #expect(throws: ReminderServiceError.reminderAccessDenied(f.hiddenId)) {
            try await f.service.deleteReminder(id: f.hiddenId)
        }
        await #expect(throws: ReminderServiceError.reminderNotFound("missing")) {
            try await f.service.deleteReminder(id: "missing")
        }
        #expect(f.store.saved.isEmpty && f.store.removed.isEmpty)
        #expect(try f.reminder(f.hiddenId).title == "Hidden")
    }

    // MARK: - Delete

    @Test("Delete removes the reminder and returns it as it was")
    func deleteReturnsPriorModel() async throws {
        let f = Self.fixture()
        let model = try await f.service.deleteReminder(id: f.existingId)
        #expect(model.id == f.existingId)
        #expect(model.title == "Existing")
        #expect(model.listId == f.workId)
        #expect(f.store.removed.map(\.calendarItemIdentifier) == [f.existingId])
        #expect(try await f.service.getReminder(id: f.existingId) == nil)
    }

    // MARK: - Lists

    @Test("Creating a list is blocked when restricted and needs a source otherwise")
    func createListGuards() async {
        let restricted = Self.fixture { work, _ in [work] }
        await #expect(throws: ReminderServiceError.listCreationBlocked) {
            try await restricted.service.createList(CreateListRequest(title: "New"))
        }
        let open = Self.fixture()
        await #expect(throws: ReminderServiceError.noValidSource) {
            try await open.service.createList(CreateListRequest(title: "New"))
        }
    }

    @Test("Deleting a list checks the allowlist before looking it up")
    func deleteListPrecedence() async throws {
        for target in ["home", "gone-and-hidden", "gone-but-allowed"] {
            let f = Self.fixture { work, _ in [work, "gone-but-allowed"] }
            let listId = target == "home" ? f.homeId : target
            let expected: ReminderServiceError =
                target == "gone-but-allowed" ? .listNotFound(listId) : .listAccessDenied(listId)
            await #expect(throws: expected) { try await f.service.deleteList(id: listId) }
            #expect(f.store.removedCalendars.isEmpty, "\(target)")
        }

        let f = Self.fixture { work, _ in [work] }
        try await f.service.deleteList(id: f.workId)
        #expect(f.store.removedCalendars == [f.workId])
    }

    /// EventKit orders alarms itself, so compare them as a collection.
    private func sameAlarms(_ alarms: [EKAlarm]?, _ expected: [ReminderAlarmModel]) -> Bool {
        let actual = (alarms ?? []).compactMap(EventKitMapping.mapAlarm)
        return actual.count == expected.count && expected.allSatisfy(actual.contains)
    }
}
