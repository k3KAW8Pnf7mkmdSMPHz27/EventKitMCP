import Foundation
import Testing

@testable import EventKitService

@Suite("Reminder priority tests")
struct ReminderPriorityTests {
    @Test("Priority display names")
    func testReminderPriorityDisplayName() {
        #expect(ReminderPriority.none.displayName == "None")
        #expect(ReminderPriority.low.displayName == "Low")
        #expect(ReminderPriority.medium.displayName == "Medium")
        #expect(ReminderPriority.high.displayName == "High")
    }

    @Test("Priority from EventKit values")
    func testReminderPriorityFromEventKit() {
        #expect(ReminderPriority(eventKitPriority: 0) == .none)
        #expect(ReminderPriority(eventKitPriority: 1) == .high)
        #expect(ReminderPriority(eventKitPriority: 2) == .high)
        #expect(ReminderPriority(eventKitPriority: 4) == .high)
        #expect(ReminderPriority(eventKitPriority: 5) == .medium)
        #expect(ReminderPriority(eventKitPriority: 6) == .low)
        #expect(ReminderPriority(eventKitPriority: 9) == .low)
    }

    @Test("Priority raw values")
    func testReminderPriorityRawValues() {
        #expect(ReminderPriority.none.rawValue == 0)
        #expect(ReminderPriority.high.rawValue == 1)
        #expect(ReminderPriority.medium.rawValue == 5)
        #expect(ReminderPriority.low.rawValue == 9)
    }
}
