import SwiftUI
import MenoControlProtocol
import RemindersCore

struct ScheduleDraft {
    var times = "09:00"
    var every = 1
    var weekdays: Set<Int> = [1, 2, 3, 4, 5]
    var monthDays = "1"
    var month = Calendar.current.component(.month, from: .now)
    var useOrdinal = false
    var ordinal = 1
    var weekday = 1
    var interval = "30"
    var intervalUnit = 60
    var timeZone = ""
    var hasStart = false
    var start = Date.now
    var hasEnd = false
    var end = Date.now.addingTimeInterval(86400 * 30)
    var excludedDates = ""

    var zone: TimeZone { TimeZone(identifier: timeZone) ?? .current }
    private func list(_ value: String) -> [String] {
        value.replacingOccurrences(of: "，", with: ",").split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
    func input(rule: RepeatRule, date: Date) throws -> JSONValue {
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
    mutating func load(_ schedule: ReminderSchedule) {
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
    func preview(rule: RepeatRule, date: Date, now: Date) -> String {
        do {
            let schedule = try ScheduleParser.parse(input(rule: rule, date: date), at: now)
            guard let next = schedule.nextFireDate(after: now) else { return "没有未来触发时间" }
            let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.timeZone = rule == .once ? .current : zone; f.dateFormat = "M月d日 E HH:mm"
            return "下次 " + f.string(from: next) + (rule == .once || timeZone.isEmpty ? "" : " · " + timeZone)
        } catch { return error.localizedDescription }
    }
}

struct ScheduleEditor: View {
    @Binding var rule: RepeatRule
    @Binding var date: Date
    @Binding var draft: ScheduleDraft
    @State private var advanced = false
    private let weekdays = ["一", "二", "三", "四", "五", "六", "日"]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("重复", selection: $rule) { ForEach(RepeatRule.allCases) { Text($0.label).tag($0) } }
                .accessibilityIdentifier("schedule.rule")
            if rule == .once {
                DatePicker("精确时间", selection: $date, displayedComponents: [.date, .hourAndMinute])
            } else {
                if rule == .interval {
                    HStack {
                        Text("每隔")
                        TextField("时长", text: $draft.interval).textFieldStyle(.roundedBorder).frame(width: 90)
                        Picker("单位", selection: $draft.intervalUnit) { Text("秒").tag(1); Text("分钟").tag(60); Text("小时").tag(3600); Text("天（24小时）").tag(86400) }.labelsHidden()
                    }
                    Text("按固定时长循环，最短 1 分钟；默认从一段间隔后开始。").font(.caption2)
                } else {
                    if rule != .weekdays {
                        Stepper("每 \(draft.every) \(rule == .weekly ? "周" : rule == .monthly ? "个月" : rule == .yearly ? "年" : "天")", value: $draft.every, in: 1...100)
                    }
                    if rule == .weekly { weekdayPicker }
                    if rule == .yearly { Picker("月份", selection: $draft.month) { ForEach(1...12, id: \.self) { Text("\($0) 月").tag($0) } } }
                    if [.monthly, .yearly].contains(rule) { monthPicker }
                    HStack { Text("提醒时点"); TextField("09:00,18:00", text: $draft.times).textFieldStyle(.roundedBorder).accessibilityIdentifier("schedule.times") }
                    Text("24 小时制，多个时点用逗号分隔，最多 24 个。").font(.caption2)
                    if rule == .weekdays { Text("周一至周五，不计算节假日或调休。").font(.caption2) }
                }
                DisclosureGroup("时区、起止与排除日期", isExpanded: $advanced) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("时区")
                            TextField("留空跟随本机，如 Asia/Shanghai", text: $draft.timeZone).textFieldStyle(.roundedBorder)
                            Menu("常用") { Button("跟随本机") { draft.timeZone = "" }; Button("北京时间") { draft.timeZone = "Asia/Shanghai" }; Button("UTC") { draft.timeZone = "UTC" } }.fixedSize()
                        }
                        Toggle("指定开始时间", isOn: $draft.hasStart)
                        if draft.hasStart { DatePicker("开始（含）", selection: $draft.start).environment(\.timeZone, draft.zone) }
                        Toggle("指定结束时间", isOn: $draft.hasEnd)
                        if draft.hasEnd { DatePicker("结束（含）", selection: $draft.end).environment(\.timeZone, draft.zone) }
                        TextField("排除日期，如 2026-12-25,2027-01-01", text: $draft.excludedDates).textFieldStyle(.roundedBorder)
                        Text("日期按所选时区计算；不存在的日期跳过。夏令时缺失钟点顺延，重复钟点只提醒一次。").font(.caption2)
                    }.padding(.top, 8)
                }
            }
        }.onAppear { advanced = draft.hasEnd || !draft.timeZone.isEmpty || !draft.excludedDates.isEmpty }
    }
    private var weekdayPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                ForEach(1...7, id: \.self) { value in
                    Button("周" + weekdays[value - 1]) {
                        if draft.weekdays.contains(value) { draft.weekdays.remove(value) } else { draft.weekdays.insert(value) }
                    }.buttonStyle(MenoTimeButtonStyle(selected: draft.weekdays.contains(value)))
                        .accessibilityValue(draft.weekdays.contains(value) ? "已选择" : "未选择")
                }
            }
            HStack { Button("工作日") { draft.weekdays = [1, 2, 3, 4, 5] }; Button("周末") { draft.weekdays = [6, 7] }; Button("每天") { draft.weekdays = Set(1...7) } }.buttonStyle(.plain)
        }
    }
    private var monthPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("日期方式", selection: $draft.useOrdinal) { Text("指定日期").tag(false); Text("第几个星期几").tag(true) }.pickerStyle(.segmented)
            if draft.useOrdinal {
                HStack {
                    Picker("第几个", selection: $draft.ordinal) { ForEach(1...5, id: \.self) { Text("第 \($0) 个").tag($0) }; Text("最后一个").tag(-1) }.labelsHidden()
                    Picker("星期", selection: $draft.weekday) { ForEach(1...7, id: \.self) { Text("周" + weekdays[$0 - 1]).tag($0) } }.labelsHidden()
                }
            } else { TextField("日期，如 1,15,月末", text: $draft.monthDays).textFieldStyle(.roundedBorder) }
            Text("没有该日期或第 5 个星期几的月份会跳过；2 月 29 日仅在闰年提醒。").font(.caption2)
        }
    }
}
