import EventKit
import Foundation
import Testing

@testable import EventKitService

/// Exercises the allowlist glue in `ReminderService` against an injected store.
/// Unsaved `EKCalendar`s get real identifiers at creation and need no Reminders
/// access, so this runs in CI.
@Suite("Allowlist against the reminder store")
struct AllowlistReminderStoreTests {
    private struct Fixture {
        let service: ReminderService
        let store: StubReminderStore
        let ids: [String]
    }

    /// Builds calendars titled `titles`, then a service whose allowlist is chosen from their IDs.
    private static func fixture(
        titles: [String] = ["Work", "Home"],
        allowed: ([String]) -> Set<String>?
    ) -> Fixture {
        let eventStore = EKEventStore()
        let calendars = titles.map { title in
            let calendar = EKCalendar(for: .reminder, eventStore: eventStore)
            calendar.title = title
            return calendar
        }
        let ids = calendars.map(\.calendarIdentifier)
        let store = StubReminderStore(calendars: calendars)
        let service = ReminderService(
            eventStore: eventStore,
            reminderStore: store,
            allowedListIds: allowed(ids),
            operationTimeout: .seconds(2)
        )
        return Fixture(service: service, store: store, ids: ids)
    }

    @Test("A stale allowlist never builds a predicate, so it can't become 'all calendars'")
    func staleAllowlistFailsClosed() async throws {
        // EventKit reads an empty calendar filter as every calendar. The bug this
        // guards: filtering a stale allowlist down to [] and querying with it.
        let f = Self.fixture { _ in ["no-such-list"] }
        #expect(try await f.service.getReminders(listId: nil, includeDone: false).isEmpty)
        #expect(try await f.service.getReminders(listId: nil, includeDone: true).isEmpty)
        #expect(f.store.predicateCalendarCounts.isEmpty)
        #expect(try await f.service.getLists().isEmpty)
    }

    @Test("A resolving allowlist queries exactly its calendars")
    func resolvingAllowlistQueriesItsCalendars() async throws {
        let f = Self.fixture { ids in [ids[1], "stale"] }
        _ = try await f.service.getReminders(listId: nil, includeDone: false)
        #expect(f.store.predicateCalendarCounts == [1])

        let lists = try await f.service.getLists()
        #expect(lists.map(\.id) == [f.ids[1]])
        #expect(lists.map(\.title) == ["Home"])
    }

    @Test("Unrestricted queries every calendar and lists them in source order")
    func unrestrictedUsesAll() async throws {
        let f = Self.fixture { _ in nil }
        _ = try await f.service.getReminders(listId: nil, includeDone: true)
        #expect(f.store.predicateCalendarCounts == [2])
        #expect(try await f.service.getLists().map(\.id) == f.ids)
    }

    @Test("Validation names the unresolved IDs and is fatal only when none resolve")
    func validationReportsUnresolved() async throws {
        let partial = try await Self.fixture { ids in [ids[0], "stale"] }.service.validateAllowedLists()
        #expect(partial.isRestricted)
        #expect(partial.resolvedCount == 1)
        #expect(partial.unresolvedIds == ["stale"])
        #expect(!partial.isFatal)

        let none = try await Self.fixture { _ in ["gone"] }.service.validateAllowedLists()
        #expect(none.resolvedCount == 0)
        #expect(none.unresolvedIds == ["gone"])
        #expect(none.isFatal)

        let open = try await Self.fixture { _ in nil }.service.validateAllowedLists()
        #expect(!open.isRestricted)
        #expect(!open.isFatal)
    }

    @Test("Validation that cannot reach the event store throws instead of passing")
    func validationTimesOutClosed() async throws {
        // The old fallback answered a busy gate as "unrestricted", and startup carried on.
        let eventStore = EKEventStore()
        let calendar = EKCalendar(for: .reminder, eventStore: eventStore)
        let gate = EventStoreOperationGate()
        let service = ReminderService(
            eventStore: eventStore,
            reminderStore: StubReminderStore(calendars: [calendar]),
            allowedListIds: [calendar.calendarIdentifier],
            operationTimeout: .milliseconds(10),
            operationGate: gate
        )
        try await gate.acquire(timeout: .seconds(1))
        await #expect(throws: ReminderServiceError.operationTimedOut) {
            try await service.validateAllowedLists()
        }
        await gate.release()
        #expect(try await service.validateAllowedLists().resolvedCount == 1)
    }

    @Test("A machine with no lists is empty, not misconfigured, unless restricted")
    func emptyStoreDistinguishesRestriction() async throws {
        let open = Self.fixture(titles: []) { _ in nil }
        _ = try await open.service.getReminders(listId: nil, includeDone: true)
        #expect(open.store.predicateCalendarCounts == [0])
        #expect(!(try await open.service.validateAllowedLists().isFatal))

        let restricted = Self.fixture(titles: []) { _ in ["anything"] }
        #expect(try await restricted.service.getReminders(listId: nil, includeDone: true).isEmpty)
        #expect(restricted.store.predicateCalendarCounts.isEmpty)
        #expect(try await restricted.service.validateAllowedLists().isFatal)
    }

    @Test("A list query checks the allowlist before looking the list up")
    func listQueryPrecedence() async throws {
        let f = Self.fixture { ids in [ids[0], "gone-but-allowed"] }
        await #expect(throws: ReminderServiceError.listAccessDenied(f.ids[1])) {
            try await f.service.getReminders(listId: f.ids[1], includeDone: false)
        }
        await #expect(throws: ReminderServiceError.listAccessDenied("gone-and-hidden")) {
            try await f.service.getReminders(listId: "gone-and-hidden", includeDone: false)
        }
        await #expect(throws: ReminderServiceError.listNotFound("gone-but-allowed")) {
            try await f.service.getReminders(listId: "gone-but-allowed", includeDone: false)
        }
        #expect(f.store.predicateCalendarCounts.isEmpty)

        _ = try await f.service.getReminders(listId: f.ids[0], includeDone: false)
        #expect(f.store.predicateCalendarCounts == [1])
    }
}
