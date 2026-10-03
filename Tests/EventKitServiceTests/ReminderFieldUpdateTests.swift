import Testing

@testable import EventKitService

@Suite("Reminder field update tests")
struct ReminderFieldUpdateTests {
    private struct Refused: Error {}

    @Test("Apply assigns a set value, assigns nil to clear, and skips unchanged")
    func apply() throws {
        let cases: [(ReminderFieldUpdate<String>, [String?])] = [
            (.set("new"), ["new"]), (.clear, [nil]), (.unchanged, [])
        ]
        for (update, expected) in cases {
            var assigned: [String?] = []
            update.apply { assigned.append($0) }
            #expect(assigned == expected, "\(update)")
        }
    }

    @Test("Apply rethrows what the assignment throws")
    func applyRethrows() {
        #expect(throws: Refused.self) { try ReminderFieldUpdate<Int>.set(1).apply { _ in throw Refused() } }
        #expect(throws: Refused.self) { try ReminderFieldUpdate<Int>.clear.apply { _ in throw Refused() } }
    }
}
