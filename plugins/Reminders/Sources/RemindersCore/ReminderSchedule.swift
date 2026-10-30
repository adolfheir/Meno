import Foundation
import MenoControlProtocol

public enum RepeatRule: String, Codable, CaseIterable, Identifiable, Sendable {
    case once, daily, weekdays, weekly, monthly, yearly, interval
    public var id: Self { self }
    public var label: String {
        switch self {
        case .once: "仅一次"
        case .daily: "按天"
        case .weekdays: "周一至周五"
        case .weekly: "自选星期"
        case .monthly: "按月"
        case .yearly: "按年"
        case .interval: "固定间隔"
        }
    }
}

/// Calendar rules use Gregorian dates, ISO weekdays (Monday = 1), and wall-clock
/// times. Intervals measure elapsed seconds. Old schedules decode with defaults.
public struct ReminderSchedule: Codable, Equatable, Sendable {
    public var rule: RepeatRule
    public var date: Date
    public var hour: Int
    public var minute: Int
    public var times: [String] = []
    public var every: Int = 1
    public var weekdays: [Int] = []
    public var monthDays: [Int] = []
    public var month: Int?
    public var ordinal: Int?
    public var weekday: Int?
    public var intervalSeconds: Double?
    public var timeZoneID: String?
    public var startAt: Date?
    public var endAt: Date?
    public var excludedDates: [String] = []

    public init(rule: RepeatRule, date: Date, calendar: Calendar = .current) {
        self.rule = rule; self.date = date
        hour = calendar.component(.hour, from: date)
        minute = calendar.component(.minute, from: date)
    }

    private enum CodingKeys: String, CodingKey {
        case rule, date, hour, minute, times, every, weekdays, monthDays, month, ordinal, weekday
        case intervalSeconds, timeZoneID, startAt, endAt, excludedDates
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rule = try c.decode(RepeatRule.self, forKey: .rule)
        date = try c.decode(Date.self, forKey: .date)
        hour = try c.decode(Int.self, forKey: .hour); minute = try c.decode(Int.self, forKey: .minute)
        times = try c.decodeIfPresent([String].self, forKey: .times) ?? []
        every = try c.decodeIfPresent(Int.self, forKey: .every) ?? 1
        weekdays = try c.decodeIfPresent([Int].self, forKey: .weekdays) ?? []
        monthDays = try c.decodeIfPresent([Int].self, forKey: .monthDays) ?? []
        month = try c.decodeIfPresent(Int.self, forKey: .month)
        ordinal = try c.decodeIfPresent(Int.self, forKey: .ordinal)
        weekday = try c.decodeIfPresent(Int.self, forKey: .weekday)
        intervalSeconds = try c.decodeIfPresent(Double.self, forKey: .intervalSeconds)
        timeZoneID = try c.decodeIfPresent(String.self, forKey: .timeZoneID)
        startAt = try c.decodeIfPresent(Date.self, forKey: .startAt)
        endAt = try c.decodeIfPresent(Date.self, forKey: .endAt)
        excludedDates = try c.decodeIfPresent([String].self, forKey: .excludedDates) ?? []
    }

    public var timeStrings: [String] { times.isEmpty ? [String(format: "%02d:%02d", hour, minute)] : times.sorted() }
    public static func validTime(_ text: String) -> Bool {
        guard let match = text.range(of: "^([01][0-9]|2[0-3]):[0-5][0-9]$", options: .regularExpression) else { return false }
        return match == text.startIndex..<text.endIndex
    }
    public static func dayText(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
    public static func validDay(_ text: String) -> Bool {
        guard text.count == 10, text.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil else { return false }
        let parts = text.split(separator: "-").compactMap { Int($0) }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard parts[0] >= 1, let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return false }
        return dayText(date, calendar: calendar) == text
    }
    public var isValid: Bool {
        guard date.timeIntervalSince1970.isFinite, (0...23).contains(hour), (0...59).contains(minute),
              (1...100).contains(every), timeStrings.count <= 24, timeStrings.allSatisfy(Self.validTime),
              Set(timeStrings).count == timeStrings.count,
              timeZoneID == nil || TimeZone(identifier: timeZoneID!) != nil,
              excludedDates.count <= 366, excludedDates.allSatisfy(Self.validDay),
              Set(excludedDates).count == excludedDates.count else { return false }
        if let startAt, let endAt, endAt < startAt { return false }
        switch rule {
        case .once, .daily: return true
        case .weekdays: return every == 1
        case .weekly: return !weekdays.isEmpty && weekdays.count <= 7 && Set(weekdays).count == weekdays.count && weekdays.allSatisfy { (1...7).contains($0) }
        case .monthly, .yearly:
            if rule == .yearly && !(1...12).contains(month ?? 0) { return false }
            if let ordinal, let weekday {
                return monthDays.isEmpty && (ordinal == -1 || (1...5).contains(ordinal)) && (1...7).contains(weekday)
            }
            return ordinal == nil && weekday == nil && !monthDays.isEmpty && monthDays.count <= 32
                && Set(monthDays).count == monthDays.count && monthDays.allSatisfy { $0 == -1 || (1...31).contains($0) }
        case .interval:
            guard let seconds = intervalSeconds else { return false }
            return seconds.isFinite && (60...315_360_000).contains(seconds)
        }
    }

    public func resolvedCalendar(_ source: Calendar = .current) -> Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = timeZoneID.flatMap(TimeZone.init(identifier:)) ?? source.timeZone
        result.firstWeekday = 2; result.minimumDaysInFirstWeek = 4
        return result
    }

    /// Returns the first occurrence strictly after `now`; start/end are inclusive.
    /// Invalid calendar dates are skipped. DST gaps advance, folds use only first.
    public func nextFireDate(after now: Date, calendar source: Calendar = .current) -> Date? {
        guard isValid else { return nil }
        if rule == .once { return date > now ? date : nil }
        let calendar = resolvedCalendar(source)
        let lower = max(now, (startAt ?? now).addingTimeInterval(-0.001))
        if let endAt, endAt <= now { return nil }
        if rule == .interval {
            let seconds = intervalSeconds!
            let anchor = startAt ?? date
            var step = max(0, floor(lower.timeIntervalSince(anchor) / seconds) + 1)
            for _ in 0...(excludedDates.count + 1) {
                let candidate = anchor.addingTimeInterval(step * seconds)
                if let endAt, candidate > endAt { return nil }
                if !excludedDates.contains(Self.dayText(candidate, calendar: calendar)) { return candidate }
                guard let nextDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: candidate)) else { return nil }
                step = max(step + 1, ceil(nextDay.timeIntervalSince(anchor) / seconds))
            }
            return nil
        }
        let component: Calendar.Component
        switch rule {
        case .weekly: component = .weekOfYear
        case .monthly: component = .month
        case .yearly: component = .year
        default: component = .day
        }
        guard let anchor = calendar.dateInterval(of: component, for: startAt ?? date)?.start,
              let currentPeriod = calendar.dateInterval(of: component, for: lower)?.start else { return nil }
        let delta = calendar.dateComponents([component], from: anchor, to: currentPeriod).value(for: component) ?? 0
        let firstPeriod = max(0, delta / every)
        // The Gregorian leap pattern repeats within 400 periods; at most 366
        // explicitly excluded dates can add another 366 empty periods.
        for index in firstPeriod...(firstPeriod + 800) {
            guard let period = calendar.date(byAdding: component, value: index * every, to: anchor) else { return nil }
            if let endAt, period > endAt { return nil }
            let days: [Date]
            switch rule {
            case .weekly:
                days = weekdays.sorted().compactMap { calendar.date(byAdding: .day, value: $0 - 1, to: period) }
            case .monthly: days = daysInMonth(period, calendar: calendar)
            case .yearly:
                if let target = calendar.date(byAdding: .month, value: month! - 1, to: period) { days = daysInMonth(target, calendar: calendar) }
                else { days = [] }
            default: days = [period]
            }
            var candidates: Set<Date> = []
            for day in days {
                if rule == .weekdays && !(2...6).contains(calendar.component(.weekday, from: day)) { continue }
                if excludedDates.contains(Self.dayText(day, calendar: calendar)) { continue }
                for time in timeStrings {
                    let parts = time.split(separator: ":").map { Int($0)! }
                    if let candidate = calendar.nextDate(after: day.addingTimeInterval(-0.001), matching: DateComponents(hour: parts[0], minute: parts[1], second: 0), matchingPolicy: .nextTime, repeatedTimePolicy: .first),
                       calendar.isDate(candidate, inSameDayAs: day), candidate > now,
                       startAt == nil || candidate >= startAt!, endAt == nil || candidate <= endAt! { candidates.insert(candidate) }
                }
            }
            if let first = candidates.min() { return first }
        }
        return nil
    }

    /// Skip whole scheduled periods, beginning with the next upcoming occurrence.
    /// Resume an hour before the first occurrence after those periods where possible.
    public func pauseUntilAfterSkipping(cycles: Int, now: Date, calendar source: Calendar = .current) -> Date? {
        guard (1...365).contains(cycles), rule != .once, var first = nextFireDate(after: now, calendar: source) else { return nil }
        let calendar = resolvedCalendar(source)
        var boundary = first
        for _ in 0..<cycles {
            if rule == .interval {
                boundary = first.addingTimeInterval(0.001)
            } else {
                let component: Calendar.Component
                switch rule {
                case .weekly, .weekdays: component = .weekOfYear
                case .monthly: component = .month
                case .yearly: component = .year
                default: component = .day
                }
                guard let period = calendar.dateInterval(of: component, for: first) else { return nil }
                boundary = period.end
            }
            guard let next = nextFireDate(after: boundary.addingTimeInterval(-0.001), calendar: source) else { return nil }
            first = next
        }
        return max(boundary, first.addingTimeInterval(-3600))
    }

    private func daysInMonth(_ first: Date, calendar: Calendar) -> [Date] {
        guard let range = calendar.range(of: .day, in: .month, for: first) else { return [] }
        let numbers: [Int]
        if let ordinal, let weekday {
            let firstWeekday = (calendar.component(.weekday, from: first) + 5) % 7 + 1
            let firstMatch = 1 + (weekday - firstWeekday + 7) % 7
            let number = ordinal == -1 ? firstMatch + ((range.count - firstMatch) / 7) * 7 : firstMatch + (ordinal - 1) * 7
            numbers = range.contains(number) ? [number] : []
        } else { numbers = Array(Set(monthDays.map { $0 == -1 ? range.count : $0 }.filter { range.contains($0) })).sorted() }
        return numbers.compactMap { calendar.date(byAdding: .day, value: $0 - 1, to: first) }
    }

    /// Compatibility helper for simple calendar triggers. Advanced rules always
    /// use a concrete next date; the runtime schedules durable one-shot instances.
    public func notificationDates(after now: Date, calendar source: Calendar = .current) -> [DateComponents] {
        guard let next = nextFireDate(after: now, calendar: source) else { return [] }
        let calendar = resolvedCalendar(source)
        if rule == .once || every != 1 || startAt != nil || endAt != nil || !excludedDates.isEmpty || ![.daily, .weekdays, .weekly].contains(rule) {
            var match = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: next)
            match.timeZone = calendar.timeZone; return [match]
        }
        return timeStrings.flatMap { time -> [DateComponents] in
            let parts = time.split(separator: ":").map { Int($0)! }
            var match = DateComponents(hour: parts[0], minute: parts[1], second: 0)
            if timeZoneID != nil { match.timeZone = calendar.timeZone }
            if rule == .daily { return [match] }
            return (rule == .weekdays ? [1, 2, 3, 4, 5] : weekdays.sorted()).map { iso in
                var value = match; value.weekday = iso % 7 + 1; return value
            }
        }
    }

    public var summary: String {
        let weekdayNames = ["一", "二", "三", "四", "五", "六", "日"]
        let unit: String
        switch rule {
        case .once: return "仅一次"
        case .daily: unit = every == 1 ? "每天" : "每 \(every) 天"
        case .weekdays: unit = "周一至周五"
        case .weekly: unit = (every == 1 ? "每周" : "每 \(every) 周的周") + weekdays.sorted().filter { (1...7).contains($0) }.map { weekdayNames[$0 - 1] }.joined(separator: "、")
        case .monthly, .yearly:
            let prefix = rule == .monthly ? (every == 1 ? "每月" : "每 \(every) 个月") : (every == 1 ? "每年" : "每 \(every) 年") + " \(month ?? 1) 月"
            if let ordinal, let weekday, (1...7).contains(weekday) { unit = prefix + (ordinal == -1 ? "最后一个" : "第 \(ordinal) 个") + "周" + weekdayNames[weekday - 1] }
            else { unit = prefix + monthDays.sorted().map { $0 == -1 ? "最后一天" : "\($0) 日" }.joined(separator: "、") }
        case .interval:
            let seconds = intervalSeconds ?? 60
            if seconds.truncatingRemainder(dividingBy: 86400) == 0 { return "每 \(Int(seconds / 86400)) 天（固定时长）" }
            if seconds.truncatingRemainder(dividingBy: 3600) == 0 { return "每 \(Int(seconds / 3600)) 小时" }
            return "每 " + String(format: "%g", seconds / 60) + " 分钟"
        }
        return unit + " " + timeStrings.joined(separator: "、") + (timeZoneID.map { " · " + $0 } ?? "")
    }

    /// Lossless editor representation; preserves anchor and advanced constraints.
    public var input: JSONValue {
        if rule == .once { return .object(["kind": .string("once"), "at": .string(TimeText.format(date))]) }
        var args: [String: JSONValue] = ["kind": .string(rule.rawValue)]
        if rule == .interval { args["everySeconds"] = .number(intervalSeconds!) }
        else {
            args["times"] = .array(timeStrings.map(JSONValue.string))
            if rule != .weekdays { args["every"] = .number(Double(every)) }
        }
        if rule == .weekly { args["weekdays"] = .array(weekdays.map { .number(Double($0)) }) }
        if [.monthly, .yearly].contains(rule) {
            if let ordinal, let weekday { args["ordinal"] = .number(Double(ordinal)); args["weekday"] = .number(Double(weekday)) }
            else { args["monthDays"] = .array(monthDays.map { .number(Double($0)) }) }
        }
        if rule == .yearly, let month { args["month"] = .number(Double(month)) }
        if let timeZoneID { args["timeZone"] = .string(timeZoneID) }
        if let startAt { args["startAt"] = .string(TimeText.format(startAt)) }
        if let endAt { args["endAt"] = .string(TimeText.format(endAt)) }
        if !excludedDates.isEmpty { args["excludedDates"] = .array(excludedDates.map(JSONValue.string)) }
        return .object(args)
    }
}
