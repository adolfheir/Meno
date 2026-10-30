import AppKit
import Combine
import MenoControlProtocol
import MenoPluginKit
import RemindersCore
import SwiftUI

@MainActor
public final class RemindersPlugin: MenoPlugin {
    public static let descriptor = PluginDescriptor(id: MenoIdentity.remindersID, name: "到点提醒",
        summary: "记下小事，把时间留给眼前。", symbol: "bell.badge", version: "0.1.0")
    public let model: RemindersModel
    public init(context: PluginContext) throws { model = try RemindersModel(context: context) }
    public func makeRuntime() throws -> any PluginRuntime { RemindersRuntime(model: model) }
    public func makeView() -> AnyView { AnyView(RemindersView(model: model)) }
}

@MainActor
public final class RemindersModel: ObservableObject {
    public let service: ReminderService
    let scheduler: NotificationScheduler
    @Published public var error: String?
    @Published public var runtimeError: String?
    @Published public private(set) var isRunning = false
    @Published public private(set) var revision = 0
    @Published public private(set) var reminders: [Reminder] = []
    @Published public private(set) var history: [Occurrence] = []
    @Published public var lastReceipt: String?
    public var command: ((String, [String: JSONValue]) async throws -> JSONValue)?
    var runtime: RemindersRuntime?
    private var subscriptions: Set<AnyCancellable> = []
    public convenience init(context: PluginContext) throws {
        try self.init(context: context, notificationClient: nil)
    }
    init(context: PluginContext, notificationClient: (any NotificationClient)?) throws {
        service = try ReminderService(directory: context.dataDirectory)
        let service = self.service
        scheduler = NotificationScheduler(client: notificationClient, now: { service.now() })
        reminders = try service.reminders(); history = try service.history()
        service.$revision.dropFirst().sink { [weak self] _ in self?.reload() }.store(in: &subscriptions)
        scheduler.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        scheduler.beforeSubmit = { [weak service] id in try service?.setState(id, .submitted) }
        scheduler.submissionFailed = { [weak self] id, detail in
            do { try self?.service.setState(id, .failed, detail: detail) } catch { self?.error = error.localizedDescription }
        }
    }
    public func setRunning(_ running: Bool) { isRunning = running }
    func revisionForRuntime() { revision += 1 }
    private func reload() {
        do {
            let items = try service.reminders(); let events = try service.history()
            reminders = items; history = events; revision += 1
        } catch { self.error = "数据读取失败，保留上次载入的事项：" + error.localizedDescription }
    }
    public var permissionLabel: String { scheduler.authorizationLabel }
    public var notificationsAuthorized: Bool { scheduler.authorized }
    public var notificationPermissionDenied: Bool { scheduler.authorization == .denied }
    public func refreshPermission() async { await scheduler.refreshPermission() }
    @discardableResult public func focusCurrentReminder(screenID: UInt32? = nil) -> Bool { runtime?.presenter.focus(screenID: screenID) ?? false }
    public func nextTriggerDate(_ reminder: Reminder) -> Date? {
        guard reminder.isEnabled && !reminder.isCancelled else { return nil }
        let upcoming = history.filter { $0.reminderID == reminder.id && $0.reminderRevision == reminder.revision && $0.state.isPending && $0.scheduledAt > service.now() }.map(\.scheduledAt).min()
        return upcoming ?? reminder.nextFireDate(after: service.now())
    }
    public func requestPermission() async throws { try await scheduler.requestPermission(); await reconcile() }
    public func reconcile() async { await runtime?.reconcile() }
    public func handleOccurrence(_ id: String, snooze: Bool) async throws {
        try service.handleOccurrence(id, snooze: snooze); scheduler.dismissDelivered(id); await reconcile()
    }
    public func receipt(_ reminder: Reminder) throws -> JSONValue {
        let candidates = history.filter { $0.reminderID == reminder.id && $0.reminderRevision == reminder.revision && $0.state.isPending }
        let upcoming = candidates.filter { $0.scheduledAt > service.now() }.min { $0.scheduledAt < $1.scheduledAt }
        let next = upcoming?.scheduledAt ?? reminder.nextFireDate(after: service.now())
        let reason: String?
        if reminder.isCancelled { reason = "事项已取消" }
        else if !reminder.isEnabled { reason = "这条提醒已暂停" }
        else if !isRunning { reason = "后台提醒已暂停，事项已保存但未进入调度" }
        else if next == nil { reason = "没有未来触发时间；到期不表示已完成" }
        else if reminder.reminderType == .system && !scheduler.authorized { reason = "系统通知" + scheduler.authorizationLabel + "，请在设置中授权" }
        else if let item = upcoming, let failure = scheduler.failures[item.id] { reason = failure }
        else if let runtimeError { reason = "后台调度受阻：" + runtimeError }
        else if reminder.reminderType == .system && (upcoming == nil || !scheduler.armedIDs.contains(upcoming!.id)) { reason = "尚未提交系统通知队列" }
        else { reason = nil }
        var value = try JSONValue.encode(reminder).object!
        value["saved"] = .bool(true); value["armed"] = .bool(reason == nil)
        value["blockedReason"] = reason.map(JSONValue.string) ?? .null
        value["nextTriggerAt"] = next.map { .string(TimeText.format($0)) } ?? .null
        return .object(value)
    }
    public func currentStatus() -> JSONValue {
        .object(["appId": .string(MenoIdentity.remindersID), "name": .string("到点提醒"),
            "running": .bool(isRunning), "enabled": .bool((try? service.enabledPreference()) ?? false),
            "notificationPermission": .string(scheduler.authorizationLabel),
            "blockedReason": (!isRunning ? "后台提醒已暂停" : runtimeError).map(JSONValue.string) ?? .null,
            "systemBlockedReason": (scheduler.authorized ? nil : "系统通知" + scheduler.authorizationLabel).map(JSONValue.string) ?? .null,
            "pendingSystemCount": .number(Double(scheduler.pendingCount)), "overlayScreenCount": .number(Double(runtime?.presenter.count ?? 0)),
            "connectedScreenCount": .number(Double(NSScreen.screens.count)),
            "presentationSuspended": .bool(runtime?.presentationSuspended ?? false),
            "overlayContentScreenID": runtime?.presenter.contentScreenID.map { .number(Double($0)) } ?? .null,
            "defaultReminderType": .string(service.defaultType.rawValue)])
    }
    public func list(_ args: [String: JSONValue]) throws -> JSONValue {
        try ReminderService.checkKeys(args, allowed: ["status", "reminderType", "from", "to", "offset", "limit"])
        let status = try ReminderService.optionalString(args, "status") ?? "all"
        guard ["all", "active", "paused", "history", "cancelled"].contains(status) else { throw ControlError("invalid_argument", "status 仅支持 all、active、paused、history、cancelled。") }
        let typeText = try ReminderService.optionalString(args, "reminderType")
        if let typeText, ReminderType(rawValue: typeText) == nil { throw ControlError("invalid_type", "无效的提醒类型。") }
        func integer(_ key: String, fallback: Int, min: Int, max: Int) throws -> Int {
            guard let value = args[key] else { return fallback }
            guard let n = value.number, n.rounded() == n, n >= Double(min), n <= Double(max) else { throw ControlError("invalid_argument", key + " 超出范围或不是整数。") }; return Int(n)
        }
        let offset = try integer("offset", fallback: 0, min: 0, max: 1_000_000)
        let limit = try integer("limit", fallback: 50, min: 1, max: 200)
        func date(_ key: String) throws -> Date? {
            guard let text = try ReminderService.optionalString(args, key) else { return nil }
            guard let value = TimeText.parse(text) else { throw ControlError("invalid_date", key + " 必须是带时区的 ISO 8601 时间。") }; return value
        }
        let from = try date("from"), to = try date("to")
        if let from, let to, from >= to { throw ControlError("invalid_argument", "from 必须早于 to，日期区间为左闭右开。") }
        func matches(_ date: Date) -> Bool { (from == nil || date >= from!) && (to == nil || date < to!) }
        let values: [JSONValue]
        if status == "history" {
            values = try service.history().filter { ($0.scheduledAt <= service.now() || !$0.state.isPending) && (typeText == nil || $0.reminderType.rawValue == typeText) && matches($0.scheduledAt) }.reversed().map { try .encode($0) }
        } else {
            values = try service.reminders().filter { item in
                let stateMatches: Bool
                switch status {
                case "active": stateMatches = item.isEnabled && !item.isCancelled && nextTriggerDate(item) != nil
                case "paused": stateMatches = !item.isEnabled && !item.isCancelled
                case "cancelled": stateMatches = item.isCancelled
                default: stateMatches = true
                }
                return stateMatches && (typeText == nil || item.reminderType.rawValue == typeText) && matches(nextTriggerDate(item) ?? item.schedule.date)
            }.sorted { (nextTriggerDate($0) ?? $0.schedule.date) < (nextTriggerDate($1) ?? $1.schedule.date) }.map { try receipt($0) }
        }
        let page = Array(values.dropFirst(offset).prefix(limit))
        return .object(["items": .array(page), "total": .number(Double(values.count)), "offset": .number(Double(offset)), "nextOffset": offset + page.count < values.count ? .number(Double(offset + page.count)) : .null])
    }
    @discardableResult
    func perform(_ name: String, _ args: [String: JSONValue]) async -> Bool {
        do {
            guard let command else { throw ControlError("not_ready", "宿主尚未就绪。") }
            let result = try await command(name, args)
            error = nil
            if result["saved"].bool == true {
                lastReceipt = result["armed"].bool == true ? "已保存，已进入提醒调度" : (result["blockedReason"].string ?? "已保存")
            }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
}
