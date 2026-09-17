import Foundation
import Testing
@testable import EventKitService

@Suite("EventStore operation gate tests")
struct EventStoreOperationGateTests {
    @Test("Concurrent callers enter one at a time")
    func serializesCallers() async {
        let gate = EventStoreOperationGate()
        let tracker = ConcurrencyTracker()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    do {
                        try await gate.acquire(timeout: .seconds(1))
                    } catch {
                        Issue.record("Unexpected gate acquisition failure: \(error)")
                        return
                    }
                    await tracker.enter()
                    await Task.yield()
                    await tracker.leave()
                    await gate.release()
                }
            }
        }

        #expect(await tracker.maximumConcurrentCallers == 1)
    }

    @Test("Waiting callers time out without entering the critical section")
    func timesOutWaiters() async throws {
        let gate = EventStoreOperationGate()
        try await gate.acquire(timeout: .seconds(1))

        do {
            try await gate.acquire(timeout: .milliseconds(10))
            Issue.record("Expected the second acquisition to time out")
        } catch let error as ReminderServiceError {
            #expect(error == .operationTimedOut)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        await gate.release()
    }

    @Test("Cancelling a waiter removes it from the queue")
    func cancellationRemovesWaiter() async throws {
        let gate = EventStoreOperationGate()
        try await gate.acquire(timeout: .seconds(1))
        let waiter = Task { try await gate.acquire(timeout: .seconds(1)) }
        waiter.cancel()

        do {
            try await waiter.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        await gate.release()
        try await gate.acquire(timeout: .milliseconds(100))
        await gate.release()
    }

    @Test("A waiter cancelled during handoff does not keep the gate")
    func cancellationDuringHandoffReleasesGate() async throws {
        let gate = EventStoreOperationGate()
        try await gate.acquire(timeout: .seconds(1))

        let waiter = Task { try await gate.acquire(timeout: .seconds(1)) }
        // Race cancellation against the handoff: `onCancel` removes the waiter through an
        // unstructured Task, so `release()` can dequeue and resume it first. The woken
        // caller must then notice it is cancelled and pass the gate on rather than hold it.
        waiter.cancel()
        await gate.release()

        do {
            try await waiter.value
            // The handoff won the race and the waiter legitimately took the gate.
            await gate.release()
        } catch is CancellationError {
            // Cancellation won; the gate must not have been left acquired.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        // Either way the gate is free. If a cancelled waiter had kept it, this times out.
        try await gate.acquire(timeout: .milliseconds(100))
        await gate.release()
    }

    @Test("An already-cancelled caller does not acquire the gate")
    func cancelledCallerDoesNotAcquire() async throws {
        let gate = EventStoreOperationGate()
        let caller = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await gate.acquire(timeout: .seconds(1))
        }

        do {
            try await caller.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        try await gate.acquire(timeout: .milliseconds(100))
        await gate.release()
    }
}

private actor ConcurrencyTracker {
    private var currentCallers = 0
    private(set) var maximumConcurrentCallers = 0

    func enter() {
        currentCallers += 1
        maximumConcurrentCallers = max(maximumConcurrentCallers, currentCallers)
    }

    func leave() {
        currentCallers -= 1
    }
}
