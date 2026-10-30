import Foundation
import MenoControlProtocol

public enum ScheduleParser {
    public static func parse(_ value: JSONValue?, at current: Date, calendar source: Calendar = .current) throws -> ReminderSchedule {
        guard let object = value?.object, let kind = object["kind"]?.string else { throw invalid("schedule 必须包含 kind。") }
        func keys(_ allowed: Set<String>) throws {
            if let key = object.keys.sorted().first(where: { !allowed.contains($0) }) { throw invalid("时间配置不支持参数：\(key)") }
        }
        func absolute(_ key: String) throws -> Date? {
            guard let raw = object[key] else { return nil }
            guard let text = raw.string, let date = TimeText.parse(text) else { throw invalid("\(key) 必须是带时区的 ISO 8601 时间。") }
            return date
        }
        func integer(_ key: String, default fallback: Int? = nil) throws -> Int? {
            guard let raw = object[key] else { return fallback }
            guard let n = raw.number, n.isFinite, n.rounded() == n, abs(n) <= 10000 else { throw invalid("\(key) 必须为整数。") }
            return Int(n)
        }
        func integers(_ key: String) throws -> [Int] {
            guard let raw = object[key] else { return [] }
            guard let array = raw.array, !array.isEmpty, array.count <= 32 else { throw invalid("\(key) 必须为非空整数数组。") }
            return try array.map {
                guard let n = $0.number, n.isFinite, n.rounded() == n, abs(n) <= 10000 else { throw invalid("\(key) 必须为整数数组。") }
                return Int(n)
            }
        }
        if kind == "once" {
            try keys(["kind", "at"])
            guard let date = try absolute("at") else { throw invalid("单次提醒需要 at。") }
            guard date > current else { throw ControlError("past_date", "单次提醒必须指定未来时间。") }
            return ReminderSchedule(rule: .once, date: date, calendar: source)
        }
        if kind == "delay" {
            try keys(["kind", "afterSeconds"])
            guard let n = object["afterSeconds"]?.number, n.isFinite, n > 0, n <= 315_360_000 else { throw invalid("afterSeconds 必须大于零且不超过十年。") }
            return ReminderSchedule(rule: .once, date: current.addingTimeInterval(n), calendar: source)
        }
        guard let rule = RepeatRule(rawValue: kind), rule != .once else { throw invalid("时间类型支持 once、delay、daily、weekdays、weekly、monthly、yearly、interval。") }
        var allowed: Set<String> = ["kind", "timeZone", "startAt", "endAt", "excludedDates"]
        if rule == .interval { allowed.insert("everySeconds") }
        else { allowed.formUnion(["time", "times"]); if rule != .weekdays { allowed.insert("every") } }
        if rule == .weekly { allowed.insert("weekdays") }
        if [.monthly, .yearly].contains(rule) { allowed.formUnion(["monthDays", "ordinal", "weekday"]) }
        if rule == .yearly { allowed.insert("month") }
        try keys(allowed)
        let start = try absolute("startAt"), end = try absolute("endAt")
        var schedule = ReminderSchedule(rule: rule, date: start ?? current, calendar: source)
        if let raw = object["timeZone"] {
            guard let zone = raw.string, TimeZone(identifier: zone) != nil else { throw invalid("timeZone 必须是有效时区，例如 Asia/Shanghai。") }
            schedule.timeZoneID = zone
        }
        schedule.startAt = start ?? (rule == .interval ? nil : current)
        schedule.endAt = end
        if let raw = object["excludedDates"] {
            guard let items = raw.array, items.count <= 366, items.allSatisfy({ $0.string != nil }) else { throw invalid("excludedDates 最多包含 366 个 YYYY-MM-DD 日期。") }
            schedule.excludedDates = items.compactMap(\.string).sorted()
        }
        if rule == .interval {
            guard let n = object["everySeconds"]?.number, n.isFinite, (60...315_360_000).contains(n) else { throw invalid("固定间隔 everySeconds 最少 60 秒、最多十年。") }
            schedule.intervalSeconds = n
            schedule.startAt = start ?? current.addingTimeInterval(n)
            schedule.date = schedule.startAt!
            schedule.hour = 0; schedule.minute = 0 // Clock fields are unused for elapsed intervals.
        } else {
            guard (object["time"] != nil) != (object["times"] != nil) else { throw invalid("time 与 times 必须且只能提供一个。") }
            if let raw = object["time"] {
                guard let text = raw.string else { throw invalid("time 必须为 HH:mm。") }
                schedule.times = [text]
            } else {
                guard let items = object["times"]?.array, !items.isEmpty, items.count <= 24, items.allSatisfy({ $0.string != nil }) else { throw invalid("times 必须包含 1 至 24 个 HH:mm 时点。") }
                schedule.times = items.compactMap(\.string).sorted()
            }
            guard schedule.times.allSatisfy(ReminderSchedule.validTime) else { throw invalid("时点必须为 24 小时制 HH:mm，例如 10:55。") }
            let first = schedule.times[0].split(separator: ":").map { Int($0)! }
            schedule.hour = first[0]; schedule.minute = first[1]
            schedule.every = try integer("every", default: 1)!
            schedule.weekdays = try integers("weekdays").sorted()
            schedule.monthDays = try integers("monthDays").sorted()
            schedule.ordinal = try integer("ordinal"); schedule.weekday = try integer("weekday")
            schedule.month = try integer("month")
            if [.monthly, .yearly].contains(rule), object["monthDays"] != nil, object["ordinal"] != nil || object["weekday"] != nil {
                throw invalid("monthDays 与 ordinal/weekday 不能同时使用。")
            }
        }
        guard schedule.isValid else { throw invalid("请检查重复规则：every 为 1–100；星期为 1–7（周一至周日）；日期为 1–31 或 -1（月末）；第几个为 1–5 或 -1（最后）；数组不得重复，结束时间不得早于开始时间。") }
        guard schedule.nextFireDate(after: current, calendar: source) != nil else { throw invalid("这条规则没有未来的有效触发时间，请检查日期、起止范围及排除日期。") }
        return schedule
    }
    private static func invalid(_ message: String) -> ControlError { ControlError("invalid_schedule", message) }
}
