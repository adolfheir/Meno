import SwiftUI
import MenoControlProtocol
import RemindersCore

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
