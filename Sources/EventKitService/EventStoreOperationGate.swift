import Foundation

actor EventStoreOperationGate {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
        let timeoutTask: Task<Void, Never>
    }

    private var isAcquired = false
    private var waiters: [Waiter] = []

    func acquire(timeout: Duration) async throws {
        try Task.checkCancellation()

        guard isAcquired else {
            isAcquired = true
            return
        }

        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timeoutTask = Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    await self?.failWaiter(id: id, error: ReminderServiceError.operationTimedOut)
                }
                waiters.append(.init(id: id, continuation: continuation, timeoutTask: timeoutTask))
            }
        } onCancel: {
            Task { await self.failWaiter(id: id, error: CancellationError()) }
        }

        // `onCancel` removes the waiter through an unstructured Task, so cancellation can
        // land after `release()` has already dequeued and resumed us. Re-check here and
        // hand the gate straight on, or the caller would proceed with a cancelled task
        // and the slot would leak.
        if Task.isCancelled {
            release()
            throw CancellationError()
        }
    }

    func release() {
        guard !waiters.isEmpty else {
            isAcquired = false
            return
        }
        let waiter = waiters.removeFirst()
        waiter.timeoutTask.cancel()
        waiter.continuation.resume()
    }

    private func failWaiter(id: UUID, error: any Error) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.timeoutTask.cancel()
        waiter.continuation.resume(throwing: error)
    }
}
