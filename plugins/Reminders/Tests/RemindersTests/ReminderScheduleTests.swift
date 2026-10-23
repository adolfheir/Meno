import RemindersCore
import XCTest

final class ReminderScheduleTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    func testOnceInPastHasNoNextDateOrSystemRequest() {
        let schedule = ReminderSchedule(rule: .once, date: date("2026-10-23T09:00:00+08:00"), calendar: calendar)
        let now = date("2026-10-23T10:00:00+08:00")
        XCTAssertNil(schedule.nextFireDate(after: now, calendar: calendar))
        XCTAssertTrue(schedule.notificationDates(after: now, calendar: calendar).isEmpty)
    }

    func testDailyRollsForwardAfterTimeHasPassed() {
        let schedule = ReminderSchedule(rule: .daily, date: date("2026-10-23T09:00:00+08:00"), calendar: calendar)
        XCTAssertEqual(schedule.nextFireDate(after: date("2026-10-23T10:00:00+08:00"), calendar: calendar), date("2026-10-24T09:00:00+08:00"))
    }

    func testWeekdaysSkipWeekendAndCreateFiveRequests() {
        let schedule = ReminderSchedule(rule: .weekdays, date: date("2026-10-23T09:00:00+08:00"), calendar: calendar)
        let now = date("2026-10-23T10:00:00+08:00") // Friday
        XCTAssertEqual(schedule.nextFireDate(after: now, calendar: calendar), date("2026-10-26T09:00:00+08:00"))
        XCTAssertEqual(schedule.notificationDates(after: now, calendar: calendar).compactMap(\.weekday), [2, 3, 4, 5, 6])
    }

    func testRecurringWallClockTimeSurvivesTimeZoneChange() {
        let schedule = ReminderSchedule(rule: .daily, date: date("2026-10-23T09:00:00+08:00"), calendar: calendar)
        var london = calendar
        london.timeZone = TimeZone(identifier: "Europe/London")!
        let next = schedule.nextFireDate(after: date("2026-10-23T08:00:00Z"), calendar: london)!
        XCTAssertEqual(london.component(.hour, from: next), 9)
        XCTAssertNil(schedule.notificationDates(after: date("2026-10-23T08:00:00Z"), calendar: london).first?.timeZone)
    }

    func testDSTGapAdvancesToNextValidTime() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let schedule = ReminderSchedule(rule: .daily, date: date("2026-03-07T02:30:00-08:00"), calendar: calendar)
        XCTAssertEqual(schedule.nextFireDate(after: date("2026-03-07T03:00:00-08:00"), calendar: calendar), date("2026-03-08T03:00:00-07:00"))
    }

    func testDSTFoldOnlyUsesFirstOccurrenceOfWallClockTime() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let schedule = ReminderSchedule(rule: .daily, date: date("2026-10-31T01:30:00-07:00"), calendar: calendar)
        XCTAssertEqual(schedule.nextFireDate(after: date("2026-11-01T00:00:00-07:00"), calendar: calendar), date("2026-11-01T01:30:00-07:00"))
        XCTAssertEqual(schedule.nextFireDate(after: date("2026-11-01T01:45:00-07:00"), calendar: calendar), date("2026-11-02T01:30:00-08:00"))
    }

    func testBookRejectsDuplicateIDsAndUnknownSchema() {
        let reminder = Reminder(title: "Test", schedule: ReminderSchedule(rule: .daily, date: .now))
        XCTAssertThrowsError(try ReminderBook(reminders: [reminder, reminder]).validate())
        var book = ReminderBook()
        book.schemaVersion = 2
        XCTAssertThrowsError(try book.validate())
    }
}
