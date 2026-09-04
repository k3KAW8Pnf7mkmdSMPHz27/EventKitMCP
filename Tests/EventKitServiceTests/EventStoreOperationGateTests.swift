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
                    await gate.acquire()
                    await tracker.enter()
                    await Task.yield()
                    await tracker.leave()
                    await gate.release()
                }
            }
        }

        #expect(await tracker.maximumConcurrentCallers == 1)
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
