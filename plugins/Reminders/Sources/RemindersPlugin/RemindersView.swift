import AppKit
import MenoControlProtocol
import RemindersCore
import SwiftUI

@MainActor
struct RemindersView: View {
    @ObservedObject var model: RemindersModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var tab = 0
    @State private var editing: Reminder?
    @State private var search = ""
    private var visible: [Reminder] {
        model.reminders.filter { reminder in
            !reminder.isCancelled && (tab == 1 ? !reminder.isEnabled : model.nextTriggerDate(reminder) != nil)
                && (search.isEmpty || reminder.title.localizedCaseInsensitiveContains(search) || reminder.note.localizedCaseInsensitiveContains(search))
        }.sorted { displayDate($0) < displayDate($1) }
    }
    private func displayDate(_ item: Reminder) -> Date { model.nextTriggerDate(item) ?? item.schedule.nextFireDate(after: .now) ?? item.schedule.date }
    var body: some View {
        MenoGlassGroup {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("MENO  /  REMINDERS").font(.system(size: 10, weight: .semibold)).tracking(2).foregroundStyle(MenoPalette.secondary)
                    Text("到点提醒").font(.system(size: 29, weight: .semibold, design: .rounded))
                }
                Spacer()
                Button {
                    Task { await model.perform("apps_set_enabled", ["appId": .string(MenoIdentity.remindersID), "enabled": .bool(!model.isRunning), "requestId": .string(UUID().uuidString)]) }
                } label: {
                    HStack(spacing: 7) { Circle().fill(model.isRunning ? MenoPalette.positive : MenoPalette.secondary).frame(width: 6, height: 6); Text(model.isRunning ? "后台运行中" : "后台已暂停").font(.callout) }
                        .padding(.horizontal, 15).padding(.vertical, 11).menoGlassPill(interactive: true)
                }.buttonStyle(.plain).help(model.isRunning ? "暂停后台提醒，窗口仍可编辑" : "启用后台提醒")
                    .accessibilityIdentifier("reminders.runtime")
            }.padding(.bottom, 22)
            if !model.isRunning {
                HStack(spacing: 10) {
                    Image(systemName: "pause.circle").foregroundStyle(MenoPalette.accent)
                    Text("后台提醒已暂停，新增和编辑会保存，但不会到点弹出。").font(.callout)
                    Spacer(minLength: 2)
                    Button("启用") { Task { await model.perform("apps_set_enabled", ["enabled": .bool(true), "requestId": .string(UUID().uuidString)]) } }.buttonStyle(.plain).foregroundStyle(MenoPalette.accent)
                }.padding(13).menoCard()
                    .padding(.bottom, 16).transition(MenoMotion.arrival(reduceMotion: reduceMotion))
            }
            ReminderComposer(model: model, existing: nil) {}
                .padding(22).menoCard(cornerRadius: 26)
            if let text = model.lastReceipt {
                Label(text, systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(MenoPalette.positive)
                    .padding(.horizontal, 11).padding(.vertical, 7).background(MenoPalette.positive.opacity(0.07), in: Capsule())
                    .padding(.top, 9).id(text).transition(MenoMotion.arrival(reduceMotion: reduceMotion)).accessibilityIdentifier("reminders.receipt")
            }
            if let text = model.error { HStack(alignment: .top) { Image(systemName: "exclamationmark.circle"); Text(text).textSelection(.enabled); Spacer(); Button("收起") { model.error = nil }.buttonStyle(.plain) }.font(.caption).foregroundStyle(.red).padding(.top, 9) }
            HStack(spacing: 18) {
                ReminderTabs(selection: $tab)
                Spacer()
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索事项", text: $search).textFieldStyle(.plain).accessibilityIdentifier("reminders.search")
                }.padding(.horizontal, 13).padding(.vertical, 10).frame(width: 180).menoGlassPill(interactive: true)
            }.padding(.top, 25).padding(.bottom, 14)
            if tab == 2 { historyList.transition(.opacity) }
            else if visible.isEmpty { emptyState.id(tab).transition(.opacity) }
            else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(Dictionary(grouping: visible, by: { Calendar.current.startOfDay(for: displayDate($0)) }).keys.sorted()), id: \.self) { day in
                            Text(dayLabel(day)).font(.system(size: 12, weight: .medium)).foregroundStyle(MenoPalette.secondary).padding(.top, 12).padding(.bottom, 4)
                            ForEach(visible.filter { Calendar.current.isDate(displayDate($0), inSameDayAs: day) }) { item in
                                reminderRow(item).transition(MenoMotion.arrival(reduceMotion: reduceMotion))
                            }
                        }
                    }.padding(.bottom, 16).animation(MenoMotion.layout(reduceMotion: reduceMotion), value: visible.map(\.id))
                }
            }
            HStack {
                Text("关闭窗口后，已启用的提醒仍会继续。").font(.caption).foregroundStyle(MenoPalette.muted)
                Spacer()
                Label("通知：" + model.permissionLabel, systemImage: "bell").font(.caption).foregroundStyle(MenoPalette.secondary)
            }.padding(.top, 12)
        }.padding(.horizontal, 30).padding(.top, 24).padding(.bottom, 20)
        }
            .foregroundStyle(MenoPalette.ink).menoWindowSurface().tint(MenoPalette.controlTint)
            .animation(MenoMotion.layout(reduceMotion: reduceMotion), value: tab)
            .animation(MenoMotion.layout(reduceMotion: reduceMotion), value: model.isRunning)
            .animation(MenoMotion.layout(reduceMotion: reduceMotion), value: model.lastReceipt)
            .frame(minWidth: 690, minHeight: 620)
            .sheet(item: $editing) { item in
                VStack(alignment: .leading, spacing: 20) {
                    HStack { Text("编辑提醒").font(.title2.weight(.semibold)); Spacer(); Button("关闭") { editing = nil } }
                    ReminderComposer(model: model, existing: item) { editing = nil }
                }.padding(30).frame(width: 620).foregroundStyle(MenoPalette.ink).tint(MenoPalette.controlTint)
            }
            .task { await model.refreshPermission() }
    }
    private func reminderRow(_ item: Reminder) -> some View {
        let receipt = try? model.receipt(item)
        return HStack(spacing: 18) {
            Text(displayDate(item).formatted(date: .omitted, time: .shortened)).font(.system(size: 23, weight: .light, design: .rounded)).monospacedDigit().frame(width: 88, alignment: .leading)
            VStack(alignment: .leading, spacing: 7) {
                Text(item.title).font(.system(size: 15, weight: .medium)).lineLimit(2)
                HStack(spacing: 7) { Label(item.reminderType.label, systemImage: item.reminderType.symbol); Text("·"); Text(item.schedule.rule.label) }.font(.caption).foregroundStyle(MenoPalette.secondary)
                if let reason = receipt?["blockedReason"].string { Text(reason).font(.caption2).foregroundStyle(MenoPalette.secondary).lineLimit(2) }
            }
            Spacer(minLength: 4)
            Button { editing = item } label: { Image(systemName: "pencil").padding(5) }.buttonStyle(.plain).foregroundStyle(MenoPalette.secondary).help("编辑提醒").accessibilityLabel("编辑 " + item.title)
            Menu {
                Button("编辑…") { editing = item }
                Button("取消提醒", role: .destructive) { Task { await model.perform("reminders_cancel", ["id": .string(item.id.uuidString), "requestId": .string(UUID().uuidString)]) } }
            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 23)
            Toggle("启用 " + item.title, isOn: Binding(get: { item.isEnabled }, set: { enabled in
                Task { await model.perform("reminders_update", ["id": .string(item.id.uuidString), "isEnabled": .bool(enabled), "requestId": .string(UUID().uuidString)]) }
            })).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }.padding(.horizontal, 18).padding(.vertical, 16).menoCard(cornerRadius: 20)
    }
    private var historyList: some View {
        let items = model.history.filter { $0.scheduledAt <= .now || ![.planned, .submitted, .failed].contains($0.state) }
            .filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }.reversed()
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if items.isEmpty { Text("还没有触发记录。到期和通知送达都不会自动记为已完成。").font(.callout).foregroundStyle(MenoPalette.secondary).padding(.vertical, 40) }
                ForEach(Array(items)) { item in
                    HStack(alignment: .top, spacing: 15) {
                        Image(systemName: item.reminderType.symbol).foregroundStyle(MenoPalette.secondary).frame(width: 22).padding(.top, 3)
                        VStack(alignment: .leading, spacing: 7) {
                            Text(item.title).font(.headline)
                            Text(item.scheduledAt.formatted(date: .abbreviated, time: .standard)).font(.caption).foregroundStyle(MenoPalette.secondary)
                            Text(item.state.label + (item.isSnooze ? " · 延期实例" : "")).font(.caption).foregroundStyle(MenoPalette.secondary)
                            if let detail = item.detail { Text(detail).font(.caption2).foregroundStyle(MenoPalette.muted) }
                        }
                        Spacer()
                        if [.submitted, .delivered, .presenting].contains(item.state) {
                            Button("确认") { Task { do { try await model.handleOccurrence(item.id, snooze: false) } catch { model.error = error.localizedDescription } } }
                        }
                    }.padding(17).menoCard(cornerRadius: 20)
                }
                ForEach(model.reminders.filter { reminder in (reminder.isCancelled || (reminder.schedule.rule == .once && reminder.schedule.date <= .now)) && !model.history.contains(where: { $0.reminderID == reminder.id }) }) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.title + (item.isCancelled ? " · 已取消" : " · 已到期，未确认")).font(.callout)
                        Text((item.schedule.rule == .once ? item.schedule.date.formatted(date: .abbreviated, time: .standard) : item.schedule.rule.label + String(format: " %02d:%02d", item.schedule.hour, item.schedule.minute)) + " · " + item.reminderType.label).font(.caption)
                    }.foregroundStyle(MenoPalette.secondary).padding(.vertical, 6)
                }
            }
        }
    }
    private var emptyState: some View {
        VStack(spacing: 15) {
            if tab == 1 {
                Image(systemName: "pause.circle").font(.system(size: 32, weight: .ultraLight))
                    .foregroundStyle(MenoPalette.secondary).frame(width: 88, height: 88)
            } else { MenoSunrise() }
            Text(tab == 1 ? "没有暂停的事项" : "把下一件小事交给 Meno").font(.headline).foregroundStyle(MenoPalette.ink)
            Text("上方写下内容，选好时间，回车即可保存。").font(.callout)
        }.foregroundStyle(MenoPalette.secondary).frame(maxWidth: .infinity, maxHeight: .infinity).padding(30)
    }
    private func dayLabel(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "今天" }
        if Calendar.current.isDateInTomorrow(date) { return "明天" }
        return date.formatted(.dateTime.month().day().weekday(.wide))
    }
}

@MainActor
struct ReminderComposer: View {
    @ObservedObject var model: RemindersModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let existing: Reminder?
    let onSaved: () -> Void
    @State private var title = ""
    @State private var note = ""
    @State private var type: ReminderType = .system
    @State private var seconds: Int? = 600
    @State private var date = Date().addingTimeInterval(600)
    @State private var rule: RepeatRule = .once
    @State private var expanded = false
    @State private var saving = false
    @State private var lastFingerprint = ""
    @State private var requestID = UUID().uuidString
    @FocusState private var titleFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "plus.circle").foregroundStyle(.secondary).font(.title3)
                TextField("需要提醒什么？", text: $title).textFieldStyle(.plain).font(.system(size: 18)).focused($titleFocused).onSubmit { Task { await save() } }.accessibilityIdentifier("composer.title")
            }.padding(.bottom, 3)
            MenoGlassGroup {
            HStack(spacing: 9) {
                ForEach([300, 600, 1800, 3600], id: \.self) { value in
                    Button(value == 3600 ? "1 小时" : "\(value / 60) 分钟") { seconds = value; rule = .once; date = .now.addingTimeInterval(Double(value)) }
                        .buttonStyle(MenoTimeButtonStyle(selected: seconds == value && rule == .once))
                        .accessibilityValue(seconds == value && rule == .once ? "已选择" : "未选择")
                }
                Button { seconds = nil; expanded = true } label: { Label("自选时间", systemImage: "calendar") }
                    .buttonStyle(MenoTimeButtonStyle(selected: seconds == nil))
                    .accessibilityValue(seconds == nil ? "已选择" : "未选择")
            }
            }
            HStack(spacing: 14) {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Label((seconds != nil && rule == .once ? "约 " : "") + (seconds != nil && rule == .once ? context.date.addingTimeInterval(Double(seconds!)) : date).formatted(date: .abbreviated, time: .shortened), systemImage: "clock").font(.caption).monospacedDigit().foregroundStyle(MenoPalette.secondary)
                }
                Spacer(minLength: 0)
                Menu {
                    Picker("提醒类型", selection: $type) { ForEach(ReminderType.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) } }.pickerStyle(.inline)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: type.symbol).font(.system(size: 12))
                        Text(type.label).font(.system(size: 13))
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                    }.padding(.horizontal, 13).padding(.vertical, 9)
                }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().menoGlassPill(interactive: true)
                    .accessibilityLabel("提醒类型").accessibilityValue(type.label).accessibilityIdentifier("composer.type")
                Button { Task { await save() } } label: {
                    HStack(spacing: 8) {
                        Text(saving ? "保存中…" : (existing == nil ? "创建" : "保存修改"))
                        if !saving { Image(systemName: "return").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary) }
                    }.font(.system(size: 13, weight: .medium)).frame(minWidth: 62)
                }.buttonStyle(MenoPrimaryButtonStyle()).disabled(saving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return, modifiers: [.command]).help("⌘↵ 保存；输入内容后也可直接回车")
                    .accessibilityLabel(existing == nil ? "创建提醒" : "保存修改").accessibilityIdentifier("composer.save")
            }
            DisclosureGroup("备注与重复规则", isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("重复", selection: Binding(get: { rule }, set: { rule = $0; seconds = nil })) { ForEach(RepeatRule.allCases) { Text($0.label).tag($0) } }
                    DatePicker(rule == .once ? "精确时间" : "每天钟点", selection: Binding(get: { date }, set: { date = $0; seconds = nil }), displayedComponents: rule == .once ? [.date, .hourAndMinute] : [.hourAndMinute])
                    TextField("备注（可选）", text: $note, axis: .vertical).lineLimit(2...4).textFieldStyle(.roundedBorder)
                    if rule == .weekdays { Text("周一至周五，不计算节假日或调休。").font(.caption).foregroundStyle(MenoPalette.secondary) }
                }.padding(.top, 12)
            }.font(.caption).foregroundStyle(MenoPalette.secondary)
        }.animation(MenoMotion.layout(reduceMotion: reduceMotion), value: expanded)
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("MenoFocusComposer"))) { _ in titleFocused = true }
        .onAppear {
            if let item = existing { title = item.title; note = item.note; type = item.reminderType; date = item.schedule.date; rule = item.schedule.rule; seconds = nil; expanded = true
                if rule != .once { date = Calendar.current.date(bySettingHour: item.schedule.hour, minute: item.schedule.minute, second: 0, of: .now) ?? .now }
            } else { type = model.service.defaultType }
            titleFocused = true
        }
    }
    private func save() async {
        guard !saving else { return }; saving = true; defer { saving = false }
        let schedule: JSONValue
        if rule != .once { schedule = .object(["kind": .string(rule.rawValue), "time": .string(String(format: "%02d:%02d", Calendar.current.component(.hour, from: date), Calendar.current.component(.minute, from: date)))]) }
        else if let seconds { schedule = .object(["kind": .string("delay"), "afterSeconds": .number(Double(seconds))]) }
        else { schedule = .object(["kind": .string("once"), "at": .string(TimeText.format(date))]) }
        var args: [String: JSONValue] = ["title": .string(title), "note": .string(note), "reminderType": .string(type.rawValue), "schedule": schedule]
        if let existing { args["id"] = .string(existing.id.uuidString) }
        let fingerprint = JSONValue.object(args).text()
        if fingerprint != lastFingerprint { requestID = UUID().uuidString; lastFingerprint = fingerprint }
        args["requestId"] = .string(requestID)
        if await model.perform(existing == nil ? "reminders_create" : "reminders_update", args) {
            if existing == nil { title = ""; note = ""; lastFingerprint = ""; titleFocused = true }
            onSaved()
        }
    }
}
