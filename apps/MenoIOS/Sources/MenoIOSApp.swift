import MenoControlProtocol
import RemindersCore
import RemindersSyncUI
import SwiftUI

@main
struct MenoIOSApp: App {
    @UIApplicationDelegateAdaptor(MobileNotificationDelegate.self) private var notifications
    @StateObject private var model = MobileStore.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RemindersScreen(model: model)
                .tint(Color(red: 0.26, green: 0.37, blue: 0.27))
                .onChange(of: scenePhase, initial: true) { _, phase in
                    if phase == .active { model.setActive(true) }
                    if phase == .background { model.setActive(false) }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
                    model.refreshNotifications()
                }
        }
    }
}

private struct RemindersScreen: View {
    @ObservedObject var model: MobileStore
    @State private var editor: EditorSelection?
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            List {
                if model.reminders.allSatisfy(\.isCancelled) {
                    ContentUnavailableView("还没有提醒", systemImage: "bell",
                                           description: Text("点右上角添加提醒。"))
                }
                let active = model.reminders.filter { $0.isEnabled && !$0.isCancelled }
                let dated = active.compactMap { item in item.nextFireDate().map { (item, $0) } }
                if !dated.isEmpty {
                    Section("接下来") {
                        ForEach(dated.sorted { $0.1 < $1.1 }, id: \.0.id) { item, date in
                            reminderRow(item, subtitle: date.formatted(date: .abbreviated, time: .shortened) + " · " + item.schedule.rule.label)
                        }
                    }
                }
                let paused = model.reminders.filter { !$0.isEnabled && !$0.isCancelled }
                if !paused.isEmpty {
                    Section("已暂停") {
                        ForEach(paused) { item in reminderRow(item, subtitle: item.schedule.rule.label) }
                    }
                }
                let expired = active.filter { $0.nextFireDate() == nil }
                if !expired.isEmpty {
                    Section("已到期") {
                        ForEach(expired) { item in reminderRow(item, subtitle: item.schedule.date.formatted(date: .abbreviated, time: .shortened)) }
                    }
                }
                let history = model.history.filter { [.acknowledged, .snoozed].contains($0.state) }
                if !history.isEmpty {
                    Section("处理记录") {
                        ForEach(history.sorted { $0.updatedAt > $1.updatedAt }) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.title)
                                Text(item.state.label + " · " + item.updatedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Meno")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("设置", systemImage: "gearshape") { showSettings = true }
                        .accessibilityIdentifier("reminders.settings")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("新增", systemImage: "plus") { editor = EditorSelection(item: nil) }
                        .disabled(model.service == nil)
                        .accessibilityIdentifier("reminders.add")
                }
            }
            .refreshable { await model.sync?.syncNow(); model.refreshNotifications() }
            .sheet(item: $editor) { selection in ReminderEditor(model: model, item: selection.item) }
            .sheet(isPresented: $showSettings) {
                NavigationStack {
                    Form {
                        Section("跨设备同步") {
                            if let sync = model.sync { SyncSettings(sync: sync) }
                        }
                        Section("iPhone 通知") {
                            switch model.permission {
                            case .notDetermined:
                                Button("允许提醒通知") { Task { await model.requestNotifications() } }
                            case .denied:
                                Link("在系统设置中允许通知", destination: URL(string: UIApplication.openSettingsURLString)!)
                            default: Label("通知已开启", systemImage: "bell.badge")
                            }
                            Text("iPhone 通过系统通知提示。Mac 的全屏提醒设置仍随事项同步。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .navigationTitle("设置")
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showSettings = false } } }
                }
            }
            .alert("Meno", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
                Button("好", role: .cancel) { model.error = nil }
            } message: { Text(model.error ?? "") }
        }
    }

    private func reminderRow(_ item: Reminder, subtitle: String) -> some View {
        Button { editor = EditorSelection(item: item) } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).foregroundStyle(.primary)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .swipeActions(allowsFullSwipe: false) {
            Button("取消", role: .destructive) { change("reminders_cancel", item: item) }
            Button(item.isEnabled ? "暂停" : "恢复") {
                change("reminders_update", item: item, fields: ["isEnabled": .bool(!item.isEnabled)])
            }.tint(.orange)
        }
    }

    private func change(_ command: String, item: Reminder, fields: [String: JSONValue] = [:]) {
        var args = fields
        args["id"] = .string(item.id.uuidString)
        do { try model.write(command, arguments: args) }
        catch { model.error = error.localizedDescription }
    }
}

private struct EditorSelection: Identifiable {
    let id = UUID()
    let item: Reminder?
}

private struct ReminderEditor: View {
    @ObservedObject var model: MobileStore
    let item: Reminder?
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var note: String
    @State private var rule: RepeatRule
    @State private var date: Date
    @State private var reminderType: ReminderType
    @State private var draft: ScheduleDraft
    @State private var error: String?
    private let initialSchedule: JSONValue?
    private let weekdays = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]

    init(model: MobileStore, item: Reminder?) {
        self.model = model
        self.item = item
        let date = item?.schedule.date ?? .now.addingTimeInterval(900)
        let rule = item?.schedule.rule ?? .once
        var draft = ScheduleDraft()
        if let schedule = item?.schedule { draft.load(schedule) }
        else { draft.times = ReminderSchedule(rule: .daily, date: date).timeStrings[0] }
        initialSchedule = item == nil ? nil : try? draft.input(rule: rule, date: date)
        _title = State(initialValue: item?.title ?? "")
        _note = State(initialValue: item?.note ?? "")
        _rule = State(initialValue: rule)
        _date = State(initialValue: date)
        _draft = State(initialValue: draft)
        _reminderType = State(initialValue: item?.reminderType ?? .system)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("内容") {
                    TextField("标题", text: $title).accessibilityIdentifier("editor.title")
                    TextField("备注", text: $note, axis: .vertical)
                }
                Section("时间") {
                    Picker("重复", selection: $rule) { ForEach(RepeatRule.allCases) { Text($0.label).tag($0) } }
                    if rule == .once {
                        DatePicker("提醒时间", selection: $date, displayedComponents: [.date, .hourAndMinute])
                    } else {
                        recurringFields
                    }
                }
                Section {
                    Picker("Mac 提醒方式", selection: $reminderType) { ForEach(ReminderType.allCases) { Text($0.label).tag($0) } }
                } footer: {
                    Text("iPhone 始终通过系统通知提示。")
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle(item == nil ? "新建提醒" : "编辑提醒")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save).disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("editor.save")
                }
            }
        }
    }

    @ViewBuilder private var recurringFields: some View {
        if rule == .interval {
            TextField("间隔时长", text: $draft.interval).keyboardType(.decimalPad)
            Picker("单位", selection: $draft.intervalUnit) {
                Text("秒").tag(1); Text("分钟").tag(60); Text("小时").tag(3600); Text("天（24 小时）").tag(86400)
            }
        } else {
            if rule != .weekdays { Stepper("间隔周期 \(draft.every)", value: $draft.every, in: 1...100) }
            TextField("时点（如 09:00,18:00）", text: $draft.times).autocorrectionDisabled()
            if rule == .weekly {
                ForEach(1...7, id: \.self) { day in
                    Toggle(weekdays[day - 1], isOn: Binding(get: { draft.weekdays.contains(day) }, set: { selected in
                        if selected { draft.weekdays.insert(day) } else { draft.weekdays.remove(day) }
                    }))
                }
            }
            if rule == .yearly {
                Picker("月份", selection: $draft.month) { ForEach(1...12, id: \.self) { Text("\($0) 月").tag($0) } }
            }
            if rule == .monthly || rule == .yearly {
                Toggle("按第几个星期几", isOn: $draft.useOrdinal)
                if draft.useOrdinal {
                    Picker("第几个", selection: $draft.ordinal) {
                        ForEach(1...5, id: \.self) { Text("第 \($0) 个").tag($0) }
                        Text("最后一个").tag(-1)
                    }
                    Picker("星期", selection: $draft.weekday) { ForEach(1...7, id: \.self) { Text(weekdays[$0 - 1]).tag($0) } }
                } else {
                    TextField("日期（如 1,15,月末）", text: $draft.monthDays)
                }
            }
        }
        DisclosureGroup("时区、起止与排除日期") {
            TextField("时区（留空跟随本机）", text: $draft.timeZone).textInputAutocapitalization(.never).autocorrectionDisabled()
            Toggle("指定开始日期", isOn: $draft.hasStart)
            if draft.hasStart { DatePicker("开始", selection: $draft.start).environment(\.timeZone, draft.zone) }
            Toggle("指定结束日期", isOn: $draft.hasEnd)
            if draft.hasEnd { DatePicker("结束", selection: $draft.end).environment(\.timeZone, draft.zone) }
            TextField("排除日期（YYYY-MM-DD）", text: $draft.excludedDates)
        }
    }

    private func save() {
        do {
            let schedule = try draft.input(rule: rule, date: date)
            var args: [String: JSONValue] = [:]
            if title != item?.title { args["title"] = .string(title) }
            if note != item?.note { args["note"] = .string(note) }
            if reminderType != item?.reminderType { args["reminderType"] = .string(reminderType.rawValue) }
            if schedule != initialSchedule { args["schedule"] = schedule }
            if args.isEmpty { dismiss(); return }
            if let item { args["id"] = .string(item.id.uuidString) }
            try model.write(item == nil ? "reminders_create" : "reminders_update", arguments: args)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
