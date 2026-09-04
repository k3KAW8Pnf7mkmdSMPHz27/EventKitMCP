import Foundation
import Testing

@testable import EventKitService

@Suite("EventKit Service Tests")
struct EventKitServiceTests {

    // MARK: - Reminder Model Tests

    @Test("Reminder model creation")
    func testReminderModelCreation() {
        let reminder = ReminderModel(
            id: "test-id",
            title: "Test Reminder",
            notes: "Some notes",
            done: false,
            priority: .high,
            dueDate: Date(),
            listId: "list-id",
            listName: "My List"
        )

        #expect(reminder.id == "test-id")
        #expect(reminder.title == "Test Reminder")
        #expect(reminder.notes == "Some notes")
        #expect(reminder.done == false)
        #expect(reminder.priority == .high)
        #expect(reminder.listId == "list-id")
        #expect(reminder.listName == "My List")
    }

    @Test("Reminder model codable")
    func testReminderModelCodable() throws {
        let reminder = ReminderModel(
            id: "test-id",
            title: "Test Reminder",
            notes: "Notes here",
            done: true,
            priority: .medium,
            dueDate: Date(timeIntervalSince1970: 1700000000),
            doneDate: Date(timeIntervalSince1970: 1700001000),
            listId: "list-123",
            listName: "Work"
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(reminder)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ReminderModel.self, from: data)

        #expect(decoded.id == reminder.id)
        #expect(decoded.title == reminder.title)
        #expect(decoded.notes == reminder.notes)
        #expect(decoded.done == reminder.done)
        #expect(decoded.priority == reminder.priority)
        #expect(decoded.listId == reminder.listId)
        #expect(decoded.listName == reminder.listName)
    }

    // MARK: - Reminder Priority Tests

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

    // MARK: - Reminder List Model Tests

    @Test("List model creation")
    func testReminderListModelCreation() {
        let list = ReminderListModel(
            id: "list-id",
            title: "My List",
            color: "#FF5733",
            isSubscribed: false,
            isImmutable: false,
            sourceTitle: "iCloud"
        )

        #expect(list.id == "list-id")
        #expect(list.title == "My List")
        #expect(list.color == "#FF5733")
        #expect(list.isSubscribed == false)
        #expect(list.isImmutable == false)
        #expect(list.sourceTitle == "iCloud")
    }

    @Test("List model codable")
    func testReminderListModelCodable() throws {
        let list = ReminderListModel(
            id: "list-123",
            title: "Work Tasks",
            color: "#0000FF",
            isSubscribed: true,
            isImmutable: false,
            sourceTitle: "Local"
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(list)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ReminderListModel.self, from: data)

        #expect(decoded.id == list.id)
        #expect(decoded.title == list.title)
        #expect(decoded.color == list.color)
        #expect(decoded.isSubscribed == list.isSubscribed)
        #expect(decoded.isImmutable == list.isImmutable)
        #expect(decoded.sourceTitle == list.sourceTitle)
    }

    // MARK: - Create Reminder Request Tests

    @Test("Create reminder request")
    func testCreateReminderRequest() {
        let request = CreateReminderRequest(
            title: "New Reminder",
            notes: "Important notes",
            listId: "list-id",
            dueDate: Date(),
            priority: .high
        )

        #expect(request.title == "New Reminder")
        #expect(request.notes == "Important notes")
        #expect(request.listId == "list-id")
        #expect(request.dueDate != nil)
        #expect(request.priority == .high)
    }

    @Test("Create reminder request minimal")
    func testCreateReminderRequestMinimal() {
        let request = CreateReminderRequest(title: "Simple Reminder")

        #expect(request.title == "Simple Reminder")
        #expect(request.notes == nil)
        #expect(request.listId == nil)
        #expect(request.dueDate == nil)
        #expect(request.priority == nil)
    }

    // MARK: - Update Reminder Request Tests

    @Test("Update reminder request")
    func testUpdateReminderRequest() {
        let dueDate = Date()
        let request = UpdateReminderRequest(
            id: "reminder-id",
            title: "Updated Title",
            notes: .set("Updated notes"),
            done: true,
            dueDate: .set(.init(date: dueDate, isAllDay: false)),
            priority: .low
        )

        #expect(request.id == "reminder-id")
        #expect(request.title == "Updated Title")
        #expect(request.notes == .set("Updated notes"))
        #expect(request.done == true)
        #expect(request.dueDate == .set(.init(date: dueDate, isAllDay: false)))
        #expect(request.priority == .low)
    }

    @Test("Update reminder request partial")
    func testUpdateReminderRequestPartial() {
        let request = UpdateReminderRequest(
            id: "reminder-id",
            done: true
        )

        #expect(request.id == "reminder-id")
        #expect(request.title == nil)
        #expect(request.notes == .unchanged)
        #expect(request.done == true)
        #expect(request.dueDate == .unchanged)
        #expect(request.priority == nil)
    }

    @Test("Alarm models round-trip without invalid payload combinations")
    func alarmModelRoundTrips() throws {
        let alarms: [ReminderAlarmModel] = [
            .relative(minutesBefore: 15),
            .absolute(Date(timeIntervalSince1970: 1_800_000_000)),
            .location(
                .init(title: "Office", latitude: 41.8781, longitude: -87.6298, radius: 100),
                proximity: .enter
            )
        ]

        let data = try JSONEncoder().encode(alarms)
        #expect(try JSONDecoder().decode([ReminderAlarmModel].self, from: data) == alarms)
    }

    @Test("Alarm decoding rejects negative relative offsets")
    func alarmDecodingRejectsNegativeOffsets() {
        let data = Data(#"{"kind":"relative","minutesBefore":-1}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ReminderAlarmModel.self, from: data)
        }
    }

    // MARK: - Create List Request Tests

    @Test("Create list request")
    func testCreateListRequest() {
        let request = CreateListRequest(
            title: "New List",
            color: "#00FF00"
        )

        #expect(request.title == "New List")
        #expect(request.color == "#00FF00")
    }

    // MARK: - Error Tests

    @Test("Reminder service error descriptions")
    func testReminderServiceErrorDescriptions() {
        #expect(ReminderServiceError.accessDenied.errorDescription == "Access to reminders was denied")
        #expect(ReminderServiceError.listNotFound("list-123").errorDescription == "Reminder list not found: list-123")
        #expect(ReminderServiceError.reminderNotFound("rem-456").errorDescription == "Reminder not found: rem-456")
        #expect(ReminderServiceError.noValidSource.errorDescription == "No valid source found for creating reminder lists")
        #expect(ReminderServiceError.saveFailed("Database error").errorDescription == "Failed to save: Database error")
    }
}
