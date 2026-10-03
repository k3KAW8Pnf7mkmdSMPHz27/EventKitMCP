import Foundation
import Testing

@testable import EventKitMCP
@testable import EventKitService
import MCP

@MainActor
@Suite("Query Reminders Handler Tests")
struct QueryRemindersTests {
    @Test("Default limit bounds output and offset retrieves the next page")
    func paginatesResults() async throws {
        let service = MockReminderService()
        service.mockReminders = (0..<30).map {
            TestFixtures.reminder(id: "r\($0)", title: "Task \($0)", listId: "default", listName: "Default")
        }

        let firstPage = await queryReminders(service: service)
        guard case .object(let first)? = firstPage.structuredContent,
              case .array(let firstReminders)? = first["reminders"] else {
            Issue.record("Expected a structured first page")
            return
        }
        #expect(firstReminders.count == 25)
        #expect(first["totalCount"]?.intValue == 30)
        #expect(first["hasMore"]?.boolValue == true)

        let secondPage = await queryReminders(limit: 10, offset: 25, service: service)
        guard case .object(let second)? = secondPage.structuredContent,
              case .array(let secondReminders)? = second["reminders"] else {
            Issue.record("Expected a structured second page")
            return
        }
        #expect(secondReminders.count == 5)
        #expect(second["hasMore"]?.boolValue == false)
    }

    @Test("Upcoming includes the entire final calendar day")
    func upcomingIncludesFinalDay() async throws {
        let service = MockReminderService()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let finalDay = try #require(calendar.date(byAdding: .day, value: 7, to: today))
        let finalAfternoon = try #require(calendar.date(byAdding: .hour, value: 18, to: finalDay))
        service.mockReminders = [
            TestFixtures.reminder(
                id: "last-day",
                title: "Last-day afternoon",
                dueDate: finalAfternoon,
                listId: "default",
                listName: "Default"
            )
        ]

        let result = await queryReminders(filter: "upcoming", days: 7, service: service)
        result.expectText(containing: "Last-day afternoon")
    }

    @Test("Structured query preserves time zones and every alarm kind")
    func structuredTimeZonesAndAlarms() async throws {
        let service = MockReminderService()
        service.mockReminders = [ReminderModel(
            id: "zoned",
            title: "Zoned reminder",
            dueDate: TestFixtures.todayNoon,
            dueTimeZone: "America/Chicago",
            listId: "default",
            listName: "Default",
            startDate: TestFixtures.todayNoon,
            startTimeZone: "Europe/Paris",
            alarms: [
                .relative(minutesBefore: 15),
                .absolute(TestFixtures.todayNoon),
                .location(
                    .init(title: "Office", latitude: 41.8781, longitude: -87.6298, radius: 100),
                    proximity: .enter
                )
            ]
        )]

        let result = await queryReminders(service: service)
        result.expectSuccess()
        guard let content = result.structuredContent,
              case .object(let structured) = content,
              case .array(let reminders)? = structured["reminders"],
              case .object(let reminder)? = reminders.first else {
            Issue.record("Expected structured reminder output")
            return
        }
        #expect(reminder["dueTimeZone"]?.stringValue == "America/Chicago")
        #expect(reminder["startTimeZone"]?.stringValue == "Europe/Paris")
        guard case .array(let alarms)? = reminder["alarms"] else {
            Issue.record("Expected structured alarms")
            return
        }
        #expect(Set(alarms.compactMap { $0.objectValue?["kind"]?.stringValue }) == [
            "relative", "absolute", "location"
        ])
    }

    // MARK: - ID-based search queries

    @Test("Search by IDs returns specific reminders")
    func testSearchByIds() async throws {
        let service = MockReminderService()
        service.mockReminders = [
            TestFixtures.reminder(title: "Task 1"),
            TestFixtures.reminder(id: "r2", title: "Task 2"),
            TestFixtures.reminder(id: "r3", title: "Task 3")
        ]

        // Use regex alternation to search for multiple IDs
        let result = await queryReminders(search: "^(r1|r3)$", service: service)

        result.expectText(containing: "Found 2 reminder(s)", "Task 1", "Task 3")
        result.expectTextNot(containing: "Task 2")
    }

    @Test("Search by ID returns single reminder")
    func testSearchBySingleId() async throws {
        let service = MockReminderService()
        service.mockReminders = [
            TestFixtures.reminder(title: "Task 1"),
            TestFixtures.reminder(id: "r2", title: "Task 2")
        ]

        let result = await queryReminders(search: "^r1$", service: service)

        result.expectText(containing: "Found 1 reminder(s)", "Task 1")
        result.expectTextNot(containing: "Task 2")
    }

    @Test("Search by nonexistent ID returns no results")
    func testSearchByNonexistentId() async throws {
        let service = MockReminderService()
        service.mockReminders = [TestFixtures.reminder(title: "Task 1")]

        let result = await queryReminders(search: "^nonexistent$", service: service)

        result.expectText(containing: "No reminders found")
    }

    // MARK: - Search queries

    @Test("Query by search returns matching reminders")
    func testQueryBySearch() async throws {
        let service = MockReminderService()
        service.mockReminders = [
            TestFixtures.reminder(title: "Buy groceries", listName: "Personal"),
            TestFixtures.reminder(id: "r2", title: "Call mom", listName: "Personal"),
            TestFixtures.reminder(id: "r3", title: "Buy milk", listName: "Personal")
        ]

        let result = await queryReminders(search: "Buy", service: service)

        result.expectText(containing: "Found 2 reminder(s)", "Buy groceries", "Buy milk")
        result.expectTextNot(containing: "Call mom")
    }

    @Test("Query by search with no matches includes hint")
    func testQueryBySearchNoMatches() async throws {
        let service = MockReminderService()
        service.mockReminders = [TestFixtures.reminder(title: "Task 1")]

        let result = await queryReminders(search: "nonexistent", service: service)

        result.expectText(containing: "No reminders found matching 'nonexistent'", "includeDone=true")
    }

    @Test("Query by search with no matches and includeDone omits hint")
    func testQueryBySearchNoMatchesWithIncludeCompleted() async throws {
        let result = await queryReminders(search: "nonexistent", includeDone: true)

        result.expectText(containing: "No reminders found matching 'nonexistent'", "broader search term")
        result.expectTextNot(containing: "includeDone")
    }

    // MARK: - Filter queries

    @Test("Query with filter=all returns all reminders")
    func testQueryFilterAll() async throws {
        let service = MockReminderService()
        service.mockReminders = [
            TestFixtures.reminder(title: "Task 1"),
            TestFixtures.reminder(id: "r2", title: "Task 2")
        ]

        let result = await queryReminders(filter: "all", service: service)

        result.expectText(containing: "Task 1", "Task 2")
    }

    @Test("Query with filter=overdue returns only overdue reminders")
    func testQueryFilterOverdue() async throws {
        let service = MockReminderService()
        service.mockReminders = [
            TestFixtures.reminder(title: "Overdue Task", dueDate: TestFixtures.yesterday),
            TestFixtures.reminder(id: "r2", title: "Future Task", dueDate: TestFixtures.tomorrow)
        ]

        let result = await queryReminders(filter: "overdue", service: service)

        result.expectText(containing: "Overdue Task")
        result.expectTextNot(containing: "Future Task")
    }

    @Test("Query with filter=today returns today's reminders")
    func testQueryFilterToday() async throws {
        let service = MockReminderService()
        service.mockReminders = [
            TestFixtures.reminder(title: "Today Task", dueDate: TestFixtures.todayNoon),
            TestFixtures.reminder(id: "r2", title: "Tomorrow Task", dueDate: TestFixtures.tomorrow)
        ]

        let result = await queryReminders(filter: "today", service: service)

        result.expectText(containing: "Today Task")
        result.expectTextNot(containing: "Tomorrow Task")
    }

    @Test("Query with filter=upcoming uses days parameter")
    func testQueryFilterUpcoming() async throws {
        let service = MockReminderService()
        service.mockReminders = [
            TestFixtures.reminder(title: "Soon Task", dueDate: TestFixtures.in3Days),
            TestFixtures.reminder(id: "r2", title: "Later Task", dueDate: TestFixtures.in10Days)
        ]

        let result = await queryReminders(filter: "upcoming", days: 5, service: service)

        result.expectText(containing: "Soon Task")
        result.expectTextNot(containing: "Later Task")
    }

    // MARK: - Empty filter result hints

    @Test("Empty results explain how to broaden the query")
    func emptyResultsExplainHowToBroaden() async throws {
        let cases: [(filter: String, days: Int?, listId: String?, expected: [String])] = [
            ("overdue", nil, nil, ["No overdue reminders found", "filter='today'", "filter='upcoming'"]),
            ("today", nil, nil, ["No reminders due today", "filter='overdue'", "filter='upcoming'"]),
            ("upcoming", 5, nil, ["No upcoming reminders in the next 5 days", "'days' parameter", "filter='all'"]),
            ("all", nil, nil, ["No reminders found", "includeDone=true"]),
            ("all", nil, "some-list", ["No reminders found", "removing listId"])
        ]

        for (filter, days, listId, expected) in cases {
            let result = await queryReminders(filter: filter, days: days, listId: listId)
            result.expectSuccess()
            for substring in expected {
                #expect(
                    result.textContent?.contains(substring) == true,
                    "filter=\(filter) listId=\(listId ?? "nil"): expected '\(substring)', got: \(result.textContent ?? "nil")"
                )
            }
        }
    }

    // MARK: - Composed query tests

    @Test("Search is applied within the selected time filter")
    func testSearchComposesWithFilter() async throws {
        let service = MockReminderService()
        service.mockReminders = [
            TestFixtures.reminder(title: "Find overdue", dueDate: TestFixtures.yesterday),
            TestFixtures.reminder(id: "r2", title: "Other overdue", dueDate: TestFixtures.yesterday),
            TestFixtures.reminder(id: "r3", title: "Find unscheduled"),
            TestFixtures.reminder(
                id: "r4",
                title: "Find personal overdue",
                dueDate: TestFixtures.yesterday,
                listId: "list-2",
                listName: "Personal"
            )
        ]

        let result = await queryReminders(filter: "overdue", search: "Find", listId: "list-1", service: service)

        result.expectText(containing: "Found 1 reminder(s)", "Find overdue")
        result.expectTextNot(containing: "Other overdue", "Find unscheduled", "Find personal overdue")
    }

    // MARK: - Default behavior

    @Test("No parameters defaults to filter=all")
    func testDefaultBehavior() async throws {
        let service = MockReminderService()
        service.mockReminders = [TestFixtures.reminder(title: "Task 1")]

        let result = await queryReminders(service: service)

        result.expectText(containing: "Task 1")
    }
}
