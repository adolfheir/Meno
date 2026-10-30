import Foundation
import MenoControlProtocol
import RemindersCore
import XCTest

final class AdvancedScheduleTests: XCTestCase {
    private func date(_ text: String) -> Date { TimeText.parse(text)! }
    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Shanghai")!; return c }
    private func parse(_ text: String, at: String = "2026-10-23T00:00:00+08:00") throws -> ReminderSchedule {
        try ScheduleParser.parse(JSONDecoder.meno.decode(JSONValue.self, from: Data(text.utf8)), at: date(at), calendar: calendar)
    }
    private func next(_ schedule: ReminderSchedule, _ after: String) -> Date? { schedule.nextFireDate(after: date(after), calendar: calendar) }

    func testFridaySaturdaySundayMultipleTimesRollAcrossWeek() throws {
        let s = try parse(#"{"kind":"weekly","weekdays":[5,6,7],"times":["17:55","10:55"],"timeZone":"Asia/Shanghai"}"#)
        let expected = ["2026-10-23T10:55:00+08:00", "2026-10-23T17:55:00+08:00", "2026-10-24T10:55:00+08:00", "2026-10-24T17:55:00+08:00", "2026-10-25T10:55:00+08:00", "2026-10-25T17:55:00+08:00", "2026-10-30T10:55:00+08:00"]
        var cursor = date("2026-10-23T00:00:00+08:00")
        for value in expected { cursor = try XCTUnwrap(s.nextFireDate(after: cursor, calendar: calendar)); XCTAssertEqual(cursor, date(value)) }
    }
    func testEveryOtherWeekAnchorsMondayAcrossYearBoundary() throws {
        let s = try parse(#"{"kind":"weekly","weekdays":[1,5,7],"time":"10:55","every":2,"startAt":"2026-12-25T00:00:00+08:00"}"#)
        XCTAssertEqual(next(s, "2026-12-25T11:00:00+08:00"), date("2026-12-27T10:55:00+08:00"))
        XCTAssertEqual(next(s, "2026-12-27T11:00:00+08:00"), date("2027-01-04T10:55:00+08:00"))
    }
    func testEveryThreeDaysUsesCalendarDaysRatherThanElapsedHours() throws {
        let s = try parse(#"{"kind":"daily","time":"09:00","every":3,"startAt":"2026-10-23T00:00:00+08:00"}"#)
        XCTAssertEqual(next(s, "2026-10-23T10:00:00+08:00"), date("2026-10-26T09:00:00+08:00"))
    }
    func testMonthEndAndAbsentDaysNeverNormalizeIntoNextMonth() throws {
        let last = try parse(#"{"kind":"monthly","monthDays":[-1],"time":"09:00"}"#)
        XCTAssertEqual(next(last, "2027-02-01T00:00:00+08:00"), date("2027-02-28T09:00:00+08:00"))
        XCTAssertEqual(next(last, "2028-02-01T00:00:00+08:00"), date("2028-02-29T09:00:00+08:00"))
        let day31 = try parse(#"{"kind":"monthly","monthDays":[31],"time":"09:00"}"#)
        XCTAssertEqual(next(day31, "2026-10-31T09:00:00+08:00"), date("2026-12-31T09:00:00+08:00"))
        let overlapping = try parse(#"{"kind":"monthly","monthDays":[31,-1],"time":"09:00"}"#)
        XCTAssertEqual(next(overlapping, "2026-10-31T09:00:00+08:00"), date("2026-11-30T09:00:00+08:00"))
    }
    func testNthAndLastWeekdaysAndMissingFifthWeek() throws {
        let last = try parse(#"{"kind":"monthly","ordinal":-1,"weekday":5,"time":"09:00"}"#)
        XCTAssertEqual(next(last, "2026-10-23T10:00:00+08:00"), date("2026-10-30T09:00:00+08:00"))
        let fifth = try parse(#"{"kind":"monthly","ordinal":5,"weekday":1,"time":"09:00"}"#)
        XCTAssertEqual(next(fifth, "2026-10-23T00:00:00+08:00"), date("2026-11-30T09:00:00+08:00"))
        let annual = try parse(#"{"kind":"yearly","month":11,"ordinal":4,"weekday":4,"time":"09:00"}"#)
        XCTAssertEqual(next(annual, "2026-10-23T00:00:00+08:00"), date("2026-11-26T09:00:00+08:00"))
    }
    func testLeapDayIncludesGregorianCenturyException() throws {
        let s = try parse(#"{"kind":"yearly","month":2,"monthDays":[29],"time":"09:00"}"#)
        XCTAssertEqual(next(s, "2026-10-23T00:00:00+08:00"), date("2028-02-29T09:00:00+08:00"))
        XCTAssertEqual(next(s, "2096-03-01T00:00:00+08:00"), date("2104-02-29T09:00:00+08:00"))
        XCTAssertThrowsError(try parse(#"{"kind":"yearly","month":2,"monthDays":[29],"every":4,"time":"09:00"}"#, at: "2025-01-01T00:00:00+08:00"))
    }
    func testEveryThirdMonthRetainsAnchorWhenMonthIsSkipped() throws {
        let s = try parse(#"{"kind":"monthly","monthDays":[31],"every":3,"time":"09:00"}"#, at: "2026-01-01T00:00:00+08:00")
        XCTAssertEqual(next(s, "2026-02-01T00:00:00+08:00"), date("2026-07-31T09:00:00+08:00"))
    }
    func testBoundsAreInclusiveAndExclusionsUseSelectedTimeZone() throws {
        let s = try parse(#"{"kind":"weekly","weekdays":[5,6,7],"times":["10:55","17:55"],"startAt":"2026-10-24T10:55:00+08:00","endAt":"2026-10-25T17:55:00+08:00","excludedDates":["2026-10-24"],"timeZone":"Asia/Shanghai"}"#)
        XCTAssertEqual(next(s, "2026-10-23T00:00:00+08:00"), date("2026-10-25T10:55:00+08:00"))
        XCTAssertEqual(next(s, "2026-10-25T10:55:00+08:00"), date("2026-10-25T17:55:00+08:00"))
        XCTAssertNil(next(s, "2026-10-25T17:55:00+08:00"))
        let start = try parse(#"{"kind":"daily","time":"10:55","startAt":"2026-10-24T10:55:00+08:00"}"#)
        XCTAssertEqual(next(start, "2026-10-23T00:00:00+08:00"), date("2026-10-24T10:55:00+08:00"))
    }
    func testFixedTimeZoneIgnoresSystemTimeZoneChange() throws {
        let s = try parse(#"{"kind":"weekly","weekdays":[5,6,7],"time":"10:55","timeZone":"Asia/Shanghai"}"#)
        var c = calendar; c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        XCTAssertEqual(s.nextFireDate(after: date("2026-10-23T03:00:00Z"), calendar: c), date("2026-10-24T10:55:00+08:00"))
    }
    func testMultiTimeDSTGapCoalescesAndFoldDoesNotRepeat() throws {
        let gap = try parse(#"{"kind":"daily","times":["02:30","03:00"],"timeZone":"America/Los_Angeles"}"#, at: "2026-03-07T00:00:00-08:00")
        XCTAssertEqual(next(gap, "2026-03-08T00:00:00-08:00"), date("2026-03-08T03:00:00-07:00"))
        XCTAssertEqual(next(gap, "2026-03-08T03:00:00-07:00"), date("2026-03-09T02:30:00-07:00"))
        let fold = try parse(#"{"kind":"weekly","weekdays":[7],"times":["01:30","02:00"],"timeZone":"America/Los_Angeles"}"#, at: "2026-10-23T00:00:00+08:00")
        XCTAssertEqual(next(fold, "2026-11-01T01:45:00-07:00"), date("2026-11-01T02:00:00-08:00"))
    }
    func testFixedIntervalsSurviveDSTAndSkipExcludedDaysWithoutDrift() throws {
        let s = try parse(#"{"kind":"interval","everySeconds":7200,"startAt":"2026-03-08T01:30:00-08:00","timeZone":"America/Los_Angeles"}"#, at: "2026-03-07T00:00:00-08:00")
        XCTAssertEqual(next(s, "2026-03-08T01:30:00-08:00"), date("2026-03-08T04:30:00-07:00"))
        let excluded = try parse(#"{"kind":"interval","everySeconds":7200,"startAt":"2026-10-23T23:30:00+08:00","excludedDates":["2026-10-24"],"timeZone":"Asia/Shanghai"}"#)
        XCTAssertEqual(next(excluded, "2026-10-23T23:30:00+08:00"), date("2026-10-25T01:30:00+08:00"))
    }
    func testLegacyDecodeAndNewRoundTripPreserveRules() throws {
        let old = #"{"rule":"daily","date":"2026-10-23T09:00:00+08:00","hour":9,"minute":0}"#
        let legacy = try JSONDecoder.meno.decode(ReminderSchedule.self, from: Data(old.utf8))
        XCTAssertEqual(next(legacy, "2026-10-23T10:00:00+08:00"), date("2026-10-24T09:00:00+08:00"))
        let s = try parse(#"{"kind":"weekly","weekdays":[5,6,7],"times":["10:55","17:55"],"every":2,"timeZone":"Asia/Shanghai","endAt":"2027-10-23T00:00:00+08:00","excludedDates":["2026-12-25"]}"#)
        XCTAssertEqual(try JSONDecoder.meno.decode(ReminderSchedule.self, from: JSONEncoder.meno.encode(s)), s)
        XCTAssertEqual(try ScheduleParser.parse(s.input, at: date("2026-10-24T00:00:00+08:00"), calendar: calendar), s)
    }
    func testInvalidSchedulesAreRejectedInsteadOfSilentlyChanged() throws {
        let bad = [
            #"{"kind":"weekly","weekdays":[],"time":"09:00"}"#,
            #"{"kind":"weekly","weekdays":[0,8],"time":"09:00"}"#,
            #"{"kind":"weekly","weekdays":[5,5],"time":"09:00"}"#,
            #"{"kind":"weekly","weekdays":[true],"time":"09:00"}"#,
            #"{"kind":"daily","time":"09:00","times":["10:00"]}"#,
            #"{"kind":"daily","times":["09:00","09:00"]}"#,
            #"{"kind":"daily","times":[]}"#,
            #"{"kind":"daily","time":"09:00\n"}"#,
            #"{"kind":"daily","time":"09:00","timeZone":"invalid/zone"}"#,
            #"{"kind":"daily","time":"09:00","every":1.5}"#,
            #"{"kind":"daily","time":"09:00","every":0}"#,
            #"{"kind":"daily","time":"09:00","startAt":"2026-10-23T09:00:00"}"#,
            #"{"kind":"daily","time":"09:00","endAt":"2026-10-22T09:00:00Z"}"#,
            #"{"kind":"daily","time":"09:00","excludedDates":["2027-02-29"]}"#,
            #"{"kind":"monthly","monthDays":[0,32],"time":"09:00"}"#,
            #"{"kind":"monthly","monthDays":[1],"ordinal":1,"weekday":1,"time":"09:00"}"#,
            #"{"kind":"monthly","ordinal":6,"weekday":1,"time":"09:00"}"#,
            #"{"kind":"yearly","month":2,"monthDays":[30],"time":"09:00"}"#,
            #"{"kind":"interval","everySeconds":30}"#,
            #"{"kind":"interval","everySeconds":true}"#,
            #"{"kind":"interval","everySeconds":60,"time":"09:00"}"#,
        ]
        for text in bad { XCTAssertThrowsError(try parse(text), text) }
    }
    func testSkipCyclesUsesNextScheduledWeekAndFirstTime() throws {
        let s = try parse(#"{"kind":"weekly","weekdays":[5,6],"times":["10:58","17:58"],"timeZone":"Asia/Shanghai"}"#)
        let now = date("2026-10-23T11:00:00+08:00")
        XCTAssertEqual(s.pauseUntilAfterSkipping(cycles: 1, now: now, calendar: calendar), date("2026-10-30T09:58:00+08:00"))
        XCTAssertEqual(s.pauseUntilAfterSkipping(cycles: 2, now: now, calendar: calendar), date("2026-11-06T09:58:00+08:00"))
    }
    func testSkipCyclesRespectsIntervalsAndExclusions() throws {
        let s = try parse(#"{"kind":"weekly","weekdays":[5,6],"time":"10:00","every":2,"excludedDates":["2026-11-06"]}"#)
        XCTAssertEqual(s.pauseUntilAfterSkipping(cycles: 1, now: date("2026-10-23T09:00:00+08:00"), calendar: calendar), date("2026-11-07T09:00:00+08:00"))
        let interval = try parse(#"{"kind":"interval","everySeconds":60}"#)
        let now = date("2026-10-23T00:00:00+08:00")
        let until = try XCTUnwrap(interval.pauseUntilAfterSkipping(cycles: 1, now: now, calendar: calendar))
        XCTAssertGreaterThan(until, now.addingTimeInterval(60))
        XCTAssertEqual(interval.nextFireDate(after: until, calendar: calendar), now.addingTimeInterval(120))
    }

}
