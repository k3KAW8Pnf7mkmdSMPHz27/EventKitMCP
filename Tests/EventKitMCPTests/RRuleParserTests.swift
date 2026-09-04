import EventKit
import Foundation
import Testing

@testable import EventKitService

// MARK: - RRuleParser Tests

@Suite("RRuleParser Tests")
struct RRuleParserTests {

    // MARK: - Parsing Tests

    @Suite("Parsing RRULE Strings")
    struct ParsingTests {

        @Test("Parse simple daily frequency")
        func parseDailyFrequency() throws {
            let rule = try RRuleParser.parse("FREQ=DAILY")
            #expect(rule.frequency == .daily)
            #expect(rule.interval == 1)
            #expect(rule.recurrenceEnd == nil)
        }

        @Test("Parse daily with interval")
        func parseDailyWithInterval() throws {
            let rule = try RRuleParser.parse("FREQ=DAILY;INTERVAL=3")
            #expect(rule.frequency == .daily)
            #expect(rule.interval == 3)
        }

        @Test("Parse weekly frequency")
        func parseWeeklyFrequency() throws {
            let rule = try RRuleParser.parse("FREQ=WEEKLY")
            #expect(rule.frequency == .weekly)
            #expect(rule.interval == 1)
        }

        @Test("Parse monthly frequency")
        func parseMonthlyFrequency() throws {
            let rule = try RRuleParser.parse("FREQ=MONTHLY")
            #expect(rule.frequency == .monthly)
        }

        @Test("Parse yearly frequency")
        func parseYearlyFrequency() throws {
            let rule = try RRuleParser.parse("FREQ=YEARLY")
            #expect(rule.frequency == .yearly)
        }

        @Test("Parse with RRULE: prefix")
        func parseWithPrefix() throws {
            let rule = try RRuleParser.parse("RRULE:FREQ=DAILY")
            #expect(rule.frequency == .daily)
        }

        @Test("Parse case insensitive")
        func parseCaseInsensitive() throws {
            let rule = try RRuleParser.parse("freq=weekly;interval=2")
            #expect(rule.frequency == .weekly)
            #expect(rule.interval == 2)
        }

        @Test("Parse COUNT end condition")
        func parseCountEnd() throws {
            let rule = try RRuleParser.parse("FREQ=WEEKLY;COUNT=10")
            #expect(rule.frequency == .weekly)
            #expect(rule.recurrenceEnd?.occurrenceCount == 10)
        }

        @Test("Parse UNTIL date end condition")
        func parseUntilEnd() throws {
            let rule = try RRuleParser.parse("FREQ=DAILY;UNTIL=20261231T235959Z")
            #expect(rule.frequency == .daily)
            #expect(rule.recurrenceEnd?.endDate != nil)
        }

        @Test("Parse UNTIL date-only format")
        func parseUntilDateOnly() throws {
            let rule = try RRuleParser.parse("FREQ=DAILY;UNTIL=20261231")
            let endDate = try #require(rule.recurrenceEnd?.endDate)
            let components = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: endDate)
            #expect(components.year == 2026)
            #expect(components.month == 12)
            #expect(components.day == 31)
        }

        @Test("Parse BYDAY simple")
        func parseByDaySimple() throws {
            let rule = try RRuleParser.parse("FREQ=WEEKLY;BYDAY=MO,WE,FR")
            #expect(rule.daysOfTheWeek?.count == 3)

            let days = rule.daysOfTheWeek?.map { $0.dayOfTheWeek }
            #expect(days?.contains(.monday) == true)
            #expect(days?.contains(.wednesday) == true)
            #expect(days?.contains(.friday) == true)
        }

        @Test("Parse BYDAY with week number")
        func parseByDayWithWeekNumber() throws {
            let rule = try RRuleParser.parse("FREQ=MONTHLY;BYDAY=2TU")
            #expect(rule.daysOfTheWeek?.count == 1)
            #expect(rule.daysOfTheWeek?.first?.dayOfTheWeek == .tuesday)
            #expect(rule.daysOfTheWeek?.first?.weekNumber == 2)
        }

        @Test("Parse BYDAY with negative week number")
        func parseByDayNegativeWeek() throws {
            let rule = try RRuleParser.parse("FREQ=MONTHLY;BYDAY=-1FR")
            #expect(rule.daysOfTheWeek?.first?.dayOfTheWeek == .friday)
            #expect(rule.daysOfTheWeek?.first?.weekNumber == -1)
        }

        @Test("Parse BYMONTHDAY")
        func parseByMonthDay() throws {
            let rule = try RRuleParser.parse("FREQ=MONTHLY;BYMONTHDAY=1,15")
            #expect(rule.daysOfTheMonth?.count == 2)
            #expect(rule.daysOfTheMonth?[0].intValue == 1)
            #expect(rule.daysOfTheMonth?[1].intValue == 15)
        }

        @Test("Parse BYMONTHDAY negative")
        func parseByMonthDayNegative() throws {
            let rule = try RRuleParser.parse("FREQ=MONTHLY;BYMONTHDAY=-1")
            #expect(rule.daysOfTheMonth?[0].intValue == -1)
        }

        @Test("Parse BYMONTH")
        func parseByMonth() throws {
            let rule = try RRuleParser.parse("FREQ=YEARLY;BYMONTH=1,6,12")
            #expect(rule.monthsOfTheYear?.count == 3)
            #expect(rule.monthsOfTheYear?[0].intValue == 1)
            #expect(rule.monthsOfTheYear?[1].intValue == 6)
            #expect(rule.monthsOfTheYear?[2].intValue == 12)
        }

        @Test("Parse BYSETPOS")
        func parseBySetPos() throws {
            let rule = try RRuleParser.parse("FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=1,-1")
            #expect(rule.setPositions?.count == 2)
            #expect(rule.setPositions?[0].intValue == 1)
            #expect(rule.setPositions?[1].intValue == -1)
        }

        @Test("Parse complex rule")
        func parseComplexRule() throws {
            let rule = try RRuleParser.parse("FREQ=YEARLY;INTERVAL=2;BYMONTH=1;BYMONTHDAY=1;COUNT=5")
            #expect(rule.frequency == .yearly)
            #expect(rule.interval == 2)
            #expect(rule.monthsOfTheYear?[0].intValue == 1)
            #expect(rule.daysOfTheMonth?[0].intValue == 1)
            #expect(rule.recurrenceEnd?.occurrenceCount == 5)
        }
    }

    // MARK: - Parsing Error Tests

    @Suite("Parsing Errors")
    struct ParsingErrorTests {

        @Test("Error on missing FREQ")
        func errorMissingFreq() {
            #expect(throws: RRuleParserError.missingFrequency) {
                try RRuleParser.parse("INTERVAL=2")
            }
        }

        @Test("Error on invalid FREQ value")
        func errorInvalidFreq() {
            #expect(throws: RRuleParserError.self) {
                try RRuleParser.parse("FREQ=HOURLY")
            }
        }

        @Test("Error on invalid INTERVAL")
        func errorInvalidInterval() {
            #expect(throws: RRuleParserError.invalidInterval("abc")) {
                try RRuleParser.parse("FREQ=DAILY;INTERVAL=abc")
            }
        }

        @Test("Error on zero INTERVAL")
        func errorZeroInterval() {
            #expect(throws: RRuleParserError.self) {
                try RRuleParser.parse("FREQ=DAILY;INTERVAL=0")
            }
        }

        @Test("Error on invalid COUNT")
        func errorInvalidCount() {
            #expect(throws: RRuleParserError.self) {
                try RRuleParser.parse("FREQ=DAILY;COUNT=-5")
            }
        }

        @Test("Error on invalid BYDAY")
        func errorInvalidByDay() {
            #expect(throws: RRuleParserError.self) {
                try RRuleParser.parse("FREQ=WEEKLY;BYDAY=XX")
            }
        }

        @Test("Error on invalid BYMONTH")
        func errorInvalidByMonth() {
            #expect(throws: RRuleParserError.self) {
                try RRuleParser.parse("FREQ=YEARLY;BYMONTH=13")
            }
        }

        @Test("Error on invalid BYMONTHDAY")
        func errorInvalidByMonthDay() {
            #expect(throws: RRuleParserError.self) {
                try RRuleParser.parse("FREQ=MONTHLY;BYMONTHDAY=32")
            }
        }
    }

    // MARK: - Formatting Tests

    @Suite("Formatting EKRecurrenceRule to RRULE")
    struct FormattingTests {

        @Test("Format simple daily rule")
        func formatDailyRule() {
            let rule = EKRecurrenceRule(
                recurrenceWith: .daily,
                interval: 1,
                end: nil
            )
            let rrule = RRuleParser.format(rule)
            #expect(rrule == "FREQ=DAILY")
        }

        @Test("Format daily with interval")
        func formatDailyWithInterval() {
            let rule = EKRecurrenceRule(
                recurrenceWith: .daily,
                interval: 3,
                end: nil
            )
            let rrule = RRuleParser.format(rule)
            #expect(rrule == "FREQ=DAILY;INTERVAL=3")
        }

        @Test("Format weekly rule")
        func formatWeeklyRule() {
            let rule = EKRecurrenceRule(
                recurrenceWith: .weekly,
                interval: 1,
                end: nil
            )
            let rrule = RRuleParser.format(rule)
            #expect(rrule == "FREQ=WEEKLY")
        }

        @Test("Format with COUNT")
        func formatWithCount() {
            let rule = EKRecurrenceRule(
                recurrenceWith: .weekly,
                interval: 2,
                end: EKRecurrenceEnd(occurrenceCount: 10)
            )
            let rrule = RRuleParser.format(rule)
            #expect(rrule.contains("FREQ=WEEKLY"))
            #expect(rrule.contains("INTERVAL=2"))
            #expect(rrule.contains("COUNT=10"))
        }

        @Test("Format with BYDAY")
        func formatWithByDay() {
            let rule = EKRecurrenceRule(
                recurrenceWith: .weekly,
                interval: 1,
                daysOfTheWeek: [
                    EKRecurrenceDayOfWeek(.monday),
                    EKRecurrenceDayOfWeek(.wednesday),
                    EKRecurrenceDayOfWeek(.friday)
                ],
                daysOfTheMonth: nil,
                monthsOfTheYear: nil,
                weeksOfTheYear: nil,
                daysOfTheYear: nil,
                setPositions: nil,
                end: nil
            )
            let rrule = RRuleParser.format(rule)
            #expect(rrule.contains("FREQ=WEEKLY"))
            #expect(rrule.contains("BYDAY="))
            #expect(rrule.contains("MO"))
            #expect(rrule.contains("WE"))
            #expect(rrule.contains("FR"))
        }

        @Test("Format with BYDAY and week number")
        func formatWithByDayWeekNumber() {
            let rule = EKRecurrenceRule(
                recurrenceWith: .monthly,
                interval: 1,
                daysOfTheWeek: [EKRecurrenceDayOfWeek(.tuesday, weekNumber: 2)],
                daysOfTheMonth: nil,
                monthsOfTheYear: nil,
                weeksOfTheYear: nil,
                daysOfTheYear: nil,
                setPositions: nil,
                end: nil
            )
            let rrule = RRuleParser.format(rule)
            #expect(rrule.contains("BYDAY=2TU"))
        }

        @Test("Format with BYMONTHDAY")
        func formatWithByMonthDay() {
            let rule = EKRecurrenceRule(
                recurrenceWith: .monthly,
                interval: 1,
                daysOfTheWeek: nil,
                daysOfTheMonth: [1, 15],
                monthsOfTheYear: nil,
                weeksOfTheYear: nil,
                daysOfTheYear: nil,
                setPositions: nil,
                end: nil
            )
            let rrule = RRuleParser.format(rule)
            #expect(rrule.contains("BYMONTHDAY=1,15"))
        }

        @Test("Format with BYMONTH")
        func formatWithByMonth() {
            let rule = EKRecurrenceRule(
                recurrenceWith: .yearly,
                interval: 1,
                daysOfTheWeek: nil,
                daysOfTheMonth: [1],
                monthsOfTheYear: [1],
                weeksOfTheYear: nil,
                daysOfTheYear: nil,
                setPositions: nil,
                end: nil
            )
            let rrule = RRuleParser.format(rule)
            #expect(rrule.contains("BYMONTH=1"))
            #expect(rrule.contains("BYMONTHDAY=1"))
        }
    }

    // MARK: - Round-trip Tests

    @Suite("Round-trip: Parse then Format")
    struct RoundTripTests {

        @Test("Round-trip simple daily")
        func roundTripDaily() throws {
            let original = "FREQ=DAILY"
            let parsed = try RRuleParser.parse(original)
            let formatted = RRuleParser.format(parsed)
            #expect(formatted == original)
        }

        @Test("Round-trip with interval")
        func roundTripWithInterval() throws {
            let original = "FREQ=WEEKLY;INTERVAL=2"
            let parsed = try RRuleParser.parse(original)
            let formatted = RRuleParser.format(parsed)
            #expect(formatted == original)
        }

        @Test("Round-trip with COUNT")
        func roundTripWithCount() throws {
            let original = "FREQ=MONTHLY;COUNT=12"
            let parsed = try RRuleParser.parse(original)
            let formatted = RRuleParser.format(parsed)
            #expect(formatted == original)
        }

        @Test("Round-trip with BYDAY")
        func roundTripWithByDay() throws {
            let original = "FREQ=WEEKLY;BYDAY=MO,WE,FR"
            let parsed = try RRuleParser.parse(original)
            let formatted = RRuleParser.format(parsed)
            #expect(formatted.contains("FREQ=WEEKLY"))
            #expect(formatted.contains("BYDAY="))
            // Order might differ, so check components
            #expect(formatted.contains("MO"))
            #expect(formatted.contains("WE"))
            #expect(formatted.contains("FR"))
        }
    }
}
