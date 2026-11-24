import Foundation
import MenoControlProtocol

public struct ScheduleDraft {
    public init() {}
    public var times = "09:00"
    public var every = 1
    public var weekdays: Set<Int> = [1, 2, 3, 4, 5]
    public var monthDays = "1"
    public var month = Calendar.current.component(.month, from: .now)
    public var useOrdinal = false
    public var ordinal = 1
    public var weekday = 1
    public var interval = "30"
    public var intervalUnit = 60
    public var timeZone = ""
    public var hasStart = false
    public var start = Date.now
    public var hasEnd = false
    public var end = Date.now.addingTimeInterval(86400 * 30)
    public var excludedDates = ""

    public var zone: TimeZone { TimeZone(identifier: timeZone) ?? .current }
    private func list(_ value: String) -> [String] {
        value.replacingOccurrences(of: "，", with: ",").split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
    public func input(rule: RepeatRule, date: Date) throws -> JSONValue {
        if rule == .once { return .object(["kind": .string("once"), "at": .string(TimeText.format(date))]) }
        var args: [String: JSONValue] = ["kind": .string(rule.rawValue)]
        if rule == .interval {
            guard let n = Double(interval), n.isFinite else { throw ControlError("invalid_schedule", "请填写有效的间隔时长。") }
            args["everySeconds"] = .number(n * Double(intervalUnit))
        } else {
            args["times"] = .array(list(times).map(JSONValue.string))
            if rule != .weekdays { args["every"] = .number(Double(every)) }
        }
        if rule == .weekly { args["weekdays"] = .array(weekdays.sorted().map { .number(Double($0)) }) }
        if [.monthly, .yearly].contains(rule) {
            if useOrdinal { args["ordinal"] = .number(Double(ordinal)); args["weekday"] = .number(Double(weekday)) }
            else {
                let days = list(monthDays).map { $0 == "月末" ? "-1" : $0 }
                guard days.allSatisfy({ Int($0) != nil }) else { throw ControlError("invalid_schedule", "日期填写如 1,15,月末。") }
                args["monthDays"] = .array(days.map { .number(Double(Int($0)!)) })
            }
        }
        if rule == .yearly { args["month"] = .number(Double(month)) }
        if !timeZone.isEmpty { args["timeZone"] = .string(timeZone.trimmingCharacters(in: .whitespaces)) }
        if hasStart { args["startAt"] = .string(TimeText.format(start)) }
        if hasEnd { args["endAt"] = .string(TimeText.format(end)) }
        if !excludedDates.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { args["excludedDates"] = .array(list(excludedDates).map(JSONValue.string)) }
        return .object(args)
    }
    public mutating func load(_ schedule: ReminderSchedule) {
        times = schedule.timeStrings.joined(separator: ",")
        every = schedule.every; weekdays = Set(schedule.weekdays.isEmpty ? [1, 2, 3, 4, 5] : schedule.weekdays)
        monthDays = (schedule.monthDays.isEmpty ? [1] : schedule.monthDays).map { $0 == -1 ? "月末" : String($0) }.joined(separator: ",")
        month = schedule.month ?? Calendar.current.component(.month, from: .now)
        useOrdinal = schedule.ordinal != nil; ordinal = schedule.ordinal ?? 1; weekday = schedule.weekday ?? 1
        if let seconds = schedule.intervalSeconds {
            intervalUnit = seconds.truncatingRemainder(dividingBy: 86400) == 0 ? 86400 : seconds.truncatingRemainder(dividingBy: 3600) == 0 ? 3600 : seconds.truncatingRemainder(dividingBy: 60) == 0 ? 60 : 1
            interval = String(seconds / Double(intervalUnit))
        }
        timeZone = schedule.timeZoneID ?? ""
        hasStart = schedule.startAt != nil; start = schedule.startAt ?? .now
        hasEnd = schedule.endAt != nil; end = schedule.endAt ?? .now.addingTimeInterval(86400 * 30)
        excludedDates = schedule.excludedDates.joined(separator: ",")
    }
    public func preview(rule: RepeatRule, date: Date, now: Date) -> String {
        do {
            let schedule = try ScheduleParser.parse(input(rule: rule, date: date), at: now)
            guard let next = schedule.nextFireDate(after: now) else { return "没有未来触发时间" }
            let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.timeZone = rule == .once ? .current : zone; f.dateFormat = "M月d日 E HH:mm"
            return "下次 " + f.string(from: next) + (rule == .once || timeZone.isEmpty ? "" : " · " + timeZone)
        } catch { return error.localizedDescription }
    }
}
