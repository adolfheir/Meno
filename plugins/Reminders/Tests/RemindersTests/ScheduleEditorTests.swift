import Foundation
import MenoControlProtocol
import RemindersCore
import XCTest
@testable import RemindersPlugin

final class ScheduleEditorTests: XCTestCase {
    func testEditingPreservesAllAdvancedConstraints() throws {
        let now = TimeText.parse("2026-10-23T00:00:00+08:00")!
        for text in [
            #"{"kind":"weekly","weekdays":[5,6,7],"times":["10:55","17:55"],"every":2,"timeZone":"Asia/Shanghai","endAt":"2027-01-01T00:00:00+08:00","excludedDates":["2026-12-25"]}"#,
            #"{"kind":"yearly","month":11,"ordinal":-1,"weekday":5,"time":"10:00","timeZone":"Asia/Shanghai"}"#,
            #"{"kind":"monthly","monthDays":[1,15,-1],"times":["10:00","18:00"]}"#,
            #"{"kind":"interval","everySeconds":90,"timeZone":"Asia/Shanghai"}"#,
        ] {
            let schedule = try ScheduleParser.parse(JSONDecoder.meno.decode(JSONValue.self, from: Data(text.utf8)), at: now)
            var draft = ScheduleDraft(); draft.load(schedule)
            let edited = try ScheduleParser.parse(draft.input(rule: schedule.rule, date: schedule.date), at: now)
            XCTAssertEqual(edited, schedule)
        }
    }
    func testChineseCommaAndMonthEndAreAcceptedWithoutLosingTimes() throws {
        var draft = ScheduleDraft(); draft.monthDays = "1，15，月末"; draft.times = "10:55，17:55"
        let value = try draft.input(rule: .monthly, date: .now)
        XCTAssertEqual(value["monthDays"], .array([.number(1), .number(15), .number(-1)]))
        XCTAssertEqual(value["times"], .array([.string("10:55"), .string("17:55")]))
    }
}
