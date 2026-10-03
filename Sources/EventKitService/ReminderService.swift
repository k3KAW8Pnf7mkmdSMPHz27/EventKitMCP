import EventKit
import Foundation
import Logging
import CoreLocation

// MARK: - Reminder Service Implementation

/// Service for interacting with Apple Reminders via EventKit
public actor ReminderService: ReminderServiceProtocol {
    private struct PendingReminderFetch {
        let id: UUID
        let continuation: CheckedContinuation<[ReminderModel], any Error>
        var request: Any?
        var timeoutTask: Task<Void, Never>?
    }

    let eventStore: EKEventStore
    let reminderStore: any ReminderStore
    let logger: Logger
    let listAccess: ListAccessPolicy
    private let operationGate = EventStoreOperationGate()
    private let operationTimeout: Duration
    private var pendingReminderFetch: PendingReminderFetch?

    public init(
        logger: Logger = Logger(label: "eventkit.reminder-service"),
        allowedListIds: Set<String>? = nil,
        operationTimeout: Duration = .seconds(15)
    ) {
        self.init(
            eventStore: EKEventStore(),
            reminderStore: nil,
            logger: logger,
            allowedListIds: allowedListIds,
            operationTimeout: operationTimeout
        )
    }

    init(
        eventStore: EKEventStore,
        reminderStore: (any ReminderStore)?,
        logger: Logger = Logger(label: "eventkit.reminder-service"),
        allowedListIds: Set<String>? = nil,
        operationTimeout: Duration = .seconds(15)
    ) {
        self.eventStore = eventStore
        self.reminderStore = reminderStore ?? eventStore
        self.logger = logger
        self.listAccess = ListAccessPolicy(allowedIds: allowedListIds)
        self.operationTimeout = operationTimeout
    }

    // MARK: - Serialized protocol boundary

    public func requestAccess() async throws -> Bool {
        try await withExclusiveEventStoreAccess { try await $0.requestAccessImpl() }
    }

    public func getLists() async throws -> [ReminderListModel] {
        try await withExclusiveEventStoreAccess { try await $0.getListsImpl() }
    }

    /// Check the configured allowlist against the lists that actually exist.
    ///
    /// Call once after access is granted. A stale or mistyped `--allowed-lists` entry
    /// would otherwise narrow silently, and an entry matching nothing at all would
    /// leave the restriction in place with no lists behind it.
    public func validateAllowedLists() async -> AllowedListValidation {
        await withGateOrUnvalidated { service in
            let available = Set(
                service.reminderStore.reminderCalendars().map(\.calendarIdentifier)
            )
            return AllowedListValidation(
                isRestricted: service.listAccess.isRestricted,
                resolvedCount: service.listAccess.allowedIds?.intersection(available).count ?? 0,
                unresolvedIds: service.listAccess.unresolvedIds(available: available)
            )
        }
    }

    private func withGateOrUnvalidated(
        _ body: @Sendable (isolated ReminderService) async -> AllowedListValidation
    ) async -> AllowedListValidation {
        guard (try? await operationGate.acquire(timeout: operationTimeout)) != nil else {
            return .unrestricted
        }
        let result = await body(self)
        await operationGate.release()
        return result
    }

    public func getList(id: String) async throws -> ReminderListModel? {
        try await withExclusiveEventStoreAccess { try await $0.getListImpl(id: id) }
    }

    public func createList(_ request: CreateListRequest) async throws -> ReminderListModel {
        try await withExclusiveEventStoreAccess { try await $0.createListImpl(request) }
    }

    public func deleteList(id: String) async throws {
        try await withExclusiveEventStoreAccess { try await $0.deleteListImpl(id: id) }
    }

    public func getReminders(listId: String?, includeDone: Bool) async throws -> [ReminderModel] {
        try await withExclusiveEventStoreAccess {
            try await $0.getRemindersImpl(listId: listId, includeDone: includeDone)
        }
    }

    public func getReminder(id: String) async throws -> ReminderModel? {
        try await withExclusiveEventStoreAccess { try await $0.getReminderImpl(id: id) }
    }

    public func createReminder(_ request: CreateReminderRequest) async throws -> ReminderModel {
        try await withExclusiveEventStoreAccess { try await $0.createReminderImpl(request) }
    }

    public func updateReminder(_ request: UpdateReminderRequest) async throws -> ReminderModel {
        try await withExclusiveEventStoreAccess { try await $0.updateReminderImpl(request) }
    }

    @discardableResult
    public func deleteReminder(id: String) async throws -> ReminderModel {
        try await withExclusiveEventStoreAccess { try await $0.deleteReminderImpl(id: id) }
    }

    private func withExclusiveEventStoreAccess<Result: Sendable>(
        _ operation: @Sendable (isolated ReminderService) async throws -> Result
    ) async throws -> Result {
        try await operationGate.acquire(timeout: operationTimeout)
        do {
            let result = try await operation(self)
            await operationGate.release()
            return result
        } catch {
            await operationGate.release()
            throw error
        }
    }

    // MARK: - Access Control Helpers

    func isListAllowed(id: String) -> Bool {
        listAccess.isAllowed(id)
    }

    private func allowedCalendars() -> [EKCalendar] {
        let all = reminderStore.reminderCalendars()
        guard listAccess.isRestricted else { return all }
        return all.filter { listAccess.isAllowed($0.calendarIdentifier) }
    }

    /// Resolve the calendars a query may touch, or `nil` when the allowlist matches none.
    ///
    /// EventKit reads an empty `calendars:` array as "every calendar", so a restricted
    /// policy that matches nothing must short-circuit instead of building a predicate.
    func queryableCalendars() -> [EKCalendar]? {
        let calendars = allowedCalendars()
        if listAccess.isEmptyMatch(matchedCount: calendars.count) {
            logger.warning("Allowed list restriction matched no calendars; denying query")
            return nil
        }
        return calendars
    }

    // MARK: - Access

    private func requestAccessImpl() async throws -> Bool {
        logger.info("Requesting reminders access")

        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess:
            return true
        case .notDetermined:
            return try await eventStore.requestFullAccessToReminders()
        case .denied, .restricted, .writeOnly:
            throw ReminderServiceError.accessDenied
        @unknown default:
            throw ReminderServiceError.accessDenied
        }
    }

    // MARK: - Private Helpers

    func fetchReminderModels(predicate: NSPredicate) async throws -> [ReminderModel] {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pendingReminderFetch = .init(
                    id: id,
                    continuation: continuation,
                    request: nil,
                    timeoutTask: nil
                )

                let request = reminderStore.fetchReminders(matching: predicate) { [weak self] reminders in
                    let models = (reminders ?? []).map(EventKitMapping.mapReminderToModel)
                    guard let service = self else { return }
                    Task { await service.finishReminderFetch(id: id, result: .success(models)) }
                }
                pendingReminderFetch?.request = request
                pendingReminderFetch?.timeoutTask = Task { [weak self, operationTimeout] in
                    try? await Task.sleep(for: operationTimeout)
                    guard !Task.isCancelled else { return }
                    await self?.finishReminderFetch(
                        id: id,
                        result: .failure(ReminderServiceError.operationTimedOut),
                        cancelRequest: true
                    )
                }
            }
        } onCancel: {
            Task {
                await self.finishReminderFetch(
                    id: id,
                    result: .failure(CancellationError()),
                    cancelRequest: true
                )
            }
        }
    }

    private func finishReminderFetch(
        id: UUID,
        result: Result<[ReminderModel], any Error>,
        cancelRequest: Bool = false
    ) {
        guard let pending = pendingReminderFetch, pending.id == id else { return }
        pendingReminderFetch = nil
        pending.timeoutTask?.cancel()
        if cancelRequest, let request = pending.request {
            reminderStore.cancelFetchRequest(request)
        }
        pending.continuation.resume(with: result)
    }
}
