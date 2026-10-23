import AppKit
import Combine
import MenoControlProtocol
import MenoPluginKit
import RemindersCore
import RemindersPlugin
import ServiceManagement
import SwiftUI

struct HostPreferences: Codable {
    var schemaVersion = 1
    var enabledPlugins: Set<String> = []
    var hotkeyEnabled: Bool? = true
    var hotkeyKey: String? = "M"
    var hotkeyModifiers: String? = "control-option-shift"
    var appearance: String? = "dark"
}

@MainActor
final class CommandGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func enter() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func leave() { if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() } }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var error: String?
    @Published var ready = false
    @Published private(set) var loginEnabled = SMAppService.mainApp.status == .enabled
    @Published var hotkeyStatus = ""
    @Published var preferences: HostPreferences
    let host: PluginHost
    let dataDirectory = MenoIdentity.dataDirectory
    let reminders: RemindersPlugin?
    let storageError: Error?
    var onOpenApp: ((String) -> Void)?
    var onHotkeyChange: (() -> Void)?
    private let preferenceStore: JSONStore<HostPreferences>
    private let preferenceError: Error?
    private let gate = CommandGate()
    private var subscriptions: Set<AnyCancellable> = []

    init() {
        let store = JSONStore<HostPreferences>(url: MenoIdentity.dataDirectory.appendingPathComponent("preferences.json"))
        preferenceStore = store
        var p = HostPreferences(); var pError: Error?
        do { p = try store.load(default: p); if p.schemaVersion != 1 { throw ControlError("unsupported_schema", "宿主设置版本不受支持，原文件已保留。") } }
        catch { pError = error }
        preferenceError = pError; preferences = p
        let module: RemindersPlugin?; let moduleError: Error?
        do {
            let loaded = try RemindersPlugin(context: PluginContext(dataDirectory: MenoIdentity.dataDirectory.appendingPathComponent("Plugins/" + MenoIdentity.remindersID)))
            if try loaded.model.service.store.metadata("host_preferences_migrated") == nil {
                try loaded.model.service.store.transaction {
                    if pError == nil && p.enabledPlugins.contains(MenoIdentity.remindersID) { try loaded.model.service.store.setMetadata("app_enabled", "true") }
                    try loaded.model.service.store.setMetadata("host_preferences_migrated", "true")
                }
            }
            module = loaded; moduleError = nil
        } catch { module = nil; moduleError = error }
        reminders = module; storageError = moduleError
        let enabled = (try? module?.model.service.enabledPreference()) == true
        host = PluginHost(definitions: [PluginDefinition(descriptor: RemindersPlugin.descriptor, makePlugin: { _ in
            guard let module else { throw moduleError ?? ControlError("storage_error", "提醒数据不可用。") }; return module
        })], enabledIDs: enabled ? [MenoIdentity.remindersID] : [], dataDirectory: MenoIdentity.dataDirectory.appendingPathComponent("Plugins")) { ids in
            guard let module else { throw moduleError ?? ControlError("storage_error", "提醒数据不可用。") }
            try module.model.service.store.setMetadata("app_enabled", ids.contains(MenoIdentity.remindersID) ? "true" : "false")
        }
        error = (moduleError ?? pError).map { "读取失败，原数据已保留：" + $0.localizedDescription }
        module?.model.command = { [weak self] name, args in
            guard let self else { throw ControlError("host_closed", "宿主已关闭。") }
            return try await self.execute(ControlRequest(command: name, arguments: args, source: "ui"))
        }
        host.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        module?.model.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
    }
    func response(_ request: ControlRequest) async -> ControlResponse {
        do { return ControlResponse(id: request.id, result: try await execute(request)) }
        catch { return ControlResponse(id: request.id, error: (error as? ControlError) ?? ControlError("operation_failed", error.localizedDescription)) }
    }
    func execute(_ request: ControlRequest) async throws -> JSONValue {
        // A user may leave the OS authorization dialog open indefinitely. It must
        // not hold the business write gate or prevent a later stop/status request.
        if request.command == "notification_request" {
            try ReminderService.checkKeys(request.arguments, allowed: [])
            guard ready, let model = reminders?.model else { throw storageError ?? ControlError("not_ready", "Meno 尚未就绪。") }
            try await model.requestPermission(); return model.currentStatus()
        }
        await gate.enter(); defer { gate.leave() }
        guard ready else { throw ControlError("not_ready", "Meno 正在恢复，请稍后使用相同 requestId 重试。") }
        if request.command == "app_open" {
            let id = request.arguments["appId"]?.string ?? MenoIdentity.remindersID
            if id == "current-reminder" {
                var screenID: UInt32?
                if let value = request.arguments["screenId"] {
                    guard let n = value.number, n.rounded() == n, n >= 0, n <= Double(UInt32.max) else { throw ControlError("invalid_argument", "screenId 必须是有效的屏幕整数 ID。") }
                    screenID = UInt32(n)
                }
                guard reminders?.model.focusCurrentReminder(screenID: screenID) == true else { throw ControlError("no_active_fullscreen", "当前没有可处理的全屏提醒；锁屏或休眠期间会暂缓展示。") }
                return .object(["opened": .bool(true)])
            }
            guard id == "settings" || MenoIdentity.pluginID(id) == MenoIdentity.remindersID else { throw ControlError("app_not_found", "未安装此子应用。") }
            onOpenApp?(MenoIdentity.pluginID(id)); return .object(["opened": .bool(true)])
        }
        if request.command == "app_quit" {
            // Termination must begin outside a Swift actor job: AppKit's nested
            // termination loop must be free to execute our async stop task.
            NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0.3)
            return .object(["quitting": .bool(true)])
        }
        guard let model = reminders?.model else { throw storageError ?? ControlError("storage_error", "提醒数据不可用。") }
        let args = request.arguments
        switch request.command {
        case "apps_get_status", "diagnostics":
            try ReminderService.checkKeys(args, allowed: ["appId"])
            if let appID = try ReminderService.optionalString(args, "appId"), MenoIdentity.pluginID(appID) != MenoIdentity.remindersID { throw ControlError("app_not_found", "未安装此子应用。") }
            await model.refreshPermission(); await model.reconcile()
            var status = model.currentStatus().object!
            status["runtimeFailure"] = host.failures[MenoIdentity.remindersID].map(JSONValue.string) ?? .null
            if request.command == "diagnostics" {
                status["windows"] = .array(NSApp.windows.filter { $0.isVisible }.map { .object(["title": .string($0.title), "number": .number(Double($0.windowNumber)), "frame": .string(NSStringFromRect($0.frame))]) })
                status["version"] = .string("0.1.0"); status["socketPath"] = .string(MenoIdentity.socketPath)
                status["appIsActive"] = .bool(NSApp.isActive)
                status["appearance"] = .string(NSApp.effectiveAppearance.name.rawValue)
                status["reduceTransparency"] = .bool(NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency)
                status["reduceMotion"] = .bool(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
                if #available(macOS 26.0, *) { status["liquidGlassAvailable"] = .bool(true) }
                else { status["liquidGlassAvailable"] = .bool(false) }
                status["keyWindowTitle"] = NSApp.keyWindow.map { .string($0.title) } ?? .null
                status["screens"] = .array(NSScreen.screens.map { .object(["id": .number(Double(($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0)), "frame": .string(NSStringFromRect($0.frame))]) })
            }
            return .object(status)
        case "apps_set_enabled":
            let outcome = try model.service.write(request.command, arguments: args, source: request.source)
            if !outcome.replayed { await host.setEnabled(args["enabled"]!.bool!, for: MenoIdentity.remindersID) }
            var result = model.currentStatus().object!
            result["saved"] = .bool(true); result["replayed"] = .bool(outcome.replayed)
            result["requestedEnabled"] = outcome.original["requestedEnabled"]
            result["runtimeFailure"] = host.failures[MenoIdentity.remindersID].map(JSONValue.string) ?? .null
            return .object(result)
        case "reminders_create", "reminders_update", "reminders_cancel":
            let outcome = try model.service.write(request.command, arguments: args, source: request.source)
            if outcome.enableRequested { await host.setEnabled(true, for: MenoIdentity.remindersID) }
            await model.reconcile()
            let originalID = outcome.original["id"].string!
            guard let current = try model.service.reminders().first(where: { $0.id.uuidString == originalID }) else { throw ControlError("storage_error", "写入后未能重新读取事项。") }
            let state = try model.receipt(current)
            var result = outcome.original.object!
            result["current"] = state; result["replayed"] = .bool(outcome.replayed)
            for key in ["armed", "blockedReason", "nextTriggerAt", "reminderType"] { result[key] = state[key] }
            return .object(result)
        case "reminders_list":
            await model.reconcile()
            return try model.list(args)
        case "settings_update":
            try ReminderService.checkKeys(args, allowed: ["defaultReminderType"])
            guard let name = args["defaultReminderType"]?.string, let type = ReminderType(rawValue: name) else { throw ControlError("invalid_type", "请选择 system 或 fullscreen。") }
            try model.service.setDefaultType(type); return model.currentStatus()
        case "occurrence_action":
            try ReminderService.checkKeys(args, allowed: ["id", "snooze"])
            let id = try ReminderService.requiredString(args, "id", max: 250)
            guard let snooze = args["snooze"]?.bool else { throw ControlError("invalid_argument", "snooze 为必填布尔值。") }
            try await model.handleOccurrence(id, snooze: snooze); return .object(["saved": .bool(true)])
        default: throw ControlError("unknown_command", "未知命令：" + request.command)
        }
    }
    func setEnabled(_ enabled: Bool, id: String) {
        Task {
            do { _ = try await execute(ControlRequest(command: "apps_set_enabled", arguments: ["appId": .string(id), "enabled": .bool(enabled), "requestId": .string(UUID().uuidString)], source: "ui")) }
            catch { self.error = error.localizedDescription }
        }
    }
    func savePreferences() {
        do { if let preferenceError { throw preferenceError }; try preferenceStore.save(preferences); onHotkeyChange?() }
        catch { self.error = "设置未保存，原文件已保留：" + error.localizedDescription }
    }
    func setLoginEnabled(_ enabled: Bool) async {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try await SMAppService.mainApp.unregister() }
            loginEnabled = SMAppService.mainApp.status == .enabled
            if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        } catch { self.error = "登录启动设置失败：" + error.localizedDescription }
    }
    func openDataDirectory() { NSWorkspace.shared.open(dataDirectory) }
}
