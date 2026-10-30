import MenoControlProtocol
import MenoPluginKit
import RemindersCore
import RemindersPlugin
import SwiftUI

@MainActor
struct MenuPopoverView: View {
    @ObservedObject var model: AppModel
    let onOpen: (String) -> Void
    let onQuit: () -> Void
    var body: some View {
        MenoGlassGroup {
        VStack(alignment: .leading, spacing: 17) {
            HStack { Text("Meno").font(.system(size: 21, weight: .semibold, design: .rounded)); Spacer(); Text("留一点从容").font(.caption).foregroundStyle(MenoPalette.secondary) }
            Divider()
            ForEach(model.host.definitions, id: \.descriptor.id) { definition in
                HStack(spacing: 12) {
                    Button { onOpen(definition.descriptor.id) } label: {
                        HStack(spacing: 13) {
                            Image(systemName: definition.descriptor.symbol).font(.system(size: 21, weight: .light)).frame(width: 37, height: 40).background(MenoPalette.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                            VStack(alignment: .leading, spacing: 6) {
                                Text(definition.descriptor.name).font(.system(size: 14, weight: .medium))
                                Text(subtitle(definition.descriptor.id)).font(.caption).foregroundStyle(MenoPalette.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("tray.open." + definition.descriptor.id)
                    Toggle("后台运行", isOn: Binding(get: { model.host.isRunning(definition.descriptor.id) }, set: { model.setEnabled($0, id: definition.descriptor.id) }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small).disabled(!model.ready || model.host.busyIDs.contains(definition.descriptor.id)).accessibilityIdentifier("tray.toggle." + definition.descriptor.id)
                }
                if let error = model.host.failures[definition.descriptor.id] { Text(error).font(.caption).foregroundStyle(.red) }
            }
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.red).lineLimit(4) }
            Divider()
            HStack { Button("设置…") { onOpen("settings") }; Spacer(); Button("退出 Meno", action: onQuit) }.buttonStyle(.plain).font(.callout).foregroundStyle(MenoPalette.secondary)
        }.padding(22).frame(width: 325).foregroundStyle(MenoPalette.ink).tint(MenoPalette.controlTint)
        }
    }
    private func subtitle(_ id: String) -> String {
        guard model.host.isRunning(id) else { return "已暂停后台提醒" }
        guard let next = model.reminders?.model.reminders.filter({ $0.nextFireDate() != nil }).min(by: { $0.nextFireDate()! < $1.nextFireDate()! }), let time = next.nextFireDate() else { return "运行中，等待下一件小事" }
        return time.formatted(date: .omitted, time: .shortened) + "  " + next.title
    }
}

@MainActor
struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var permissionError: String?
    @State private var preferenceError: String?
    @State private var requestingPermission = false
    var body: some View {
        MenoGlassGroup {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) { Text("Meno 设置").font(.system(size: 28, weight: .semibold, design: .rounded)); Text("按需运行，所有事项保存在这台 Mac。").foregroundStyle(MenoPalette.secondary) }
                VStack(alignment: .leading, spacing: 18) {
                    Picker("外观", selection: Binding(get: { model.preferences.appearance ?? "dark" }, set: { model.preferences.appearance = $0; model.savePreferences() })) {
                        Text("雾灰").tag("dark"); Text("明亮").tag("light"); Text("跟随系统").tag("system")
                    }
                    Text("柔和烟灰与玻璃光影；动效和透明度遵循系统辅助功能设置。").font(.caption).foregroundStyle(MenoPalette.secondary)
                    Divider()
                    Toggle("登录时启动 Meno", isOn: Binding(get: { model.loginEnabled }, set: { value in Task { await model.setLoginEnabled(value) } })).toggleStyle(.switch)
                    Text("恢复上次启用的子应用，只显示菜单栏入口。").font(.caption).foregroundStyle(MenoPalette.secondary)
                    Divider()
                    Toggle("全局快速创建快捷键", isOn: Binding(get: { model.preferences.hotkeyEnabled ?? true }, set: { model.preferences.hotkeyEnabled = $0; model.savePreferences() })).toggleStyle(.switch)
                    HStack {
                        Picker("组合键", selection: Binding(get: { model.preferences.hotkeyModifiers ?? "control-option-shift" }, set: { model.preferences.hotkeyModifiers = $0; model.savePreferences() })) {
                            Text("⌃⌥⇧").tag("control-option-shift"); Text("⌃⌥").tag("control-option"); Text("⌘⌥⇧").tag("command-option-shift")
                        }
                        Picker("字母", selection: Binding(get: { model.preferences.hotkeyKey ?? "M" }, set: { model.preferences.hotkeyKey = $0; model.savePreferences() })) { Text("M").tag("M"); Text("R").tag("R"); Text("N").tag("N") }.frame(width: 100)
                    }
                    Text(model.hotkeyStatus).font(.caption).foregroundStyle(MenoPalette.secondary)
                }.padding(22).menoCard()
                if let reminders = model.reminders?.model {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("到点提醒").font(.headline)
                        Picker("新事项默认类型", selection: Binding(get: { reminders.service.defaultType }, set: { type in
                            Task {
                                preferenceError = nil
                                do { _ = try await model.execute(ControlRequest(command: "settings_update", arguments: ["defaultReminderType": .string(type.rawValue)], source: "ui")) }
                                catch { preferenceError = error.localizedDescription }
                            }
                        })) { ForEach(ReminderType.allCases) { Text($0.label).tag($0) } }
                        HStack {
                            Text("系统通知：" + reminders.permissionLabel)
                            Spacer()
                            Button(reminders.notificationsAuthorized ? "已授权" : (reminders.notificationPermissionDenied ? "前往系统设置" : "请求通知授权")) {
                                if reminders.notificationPermissionDenied { openNotificationSettings() }
                                else { requestNotificationPermission() }
                            }.disabled(requestingPermission || reminders.notificationsAuthorized)
                        }
                        if reminders.notificationPermissionDenied {
                            Text("请在「系统设置 → 通知 → Meno」中打开「允许通知」，返回后会自动刷新。").font(.caption).foregroundStyle(MenoPalette.secondary)
                        }
                        Button("打开系统通知设置…", action: openNotificationSettings).buttonStyle(.link)
                        Text("未授权时，系统类型仍可保存；全屏提醒独立运行。系统通知的展示遵循专注模式和系统设置。").font(.caption).foregroundStyle(MenoPalette.secondary)
                        if let permissionError { Text(permissionError).font(.caption).foregroundStyle(.red) }
                        if let preferenceError { Text(preferenceError).font(.caption).foregroundStyle(.red) }
                    }.padding(22).menoCard()
                }
                VStack(alignment: .leading, spacing: 13) {
                    Text("连接外部 AI / MCP").font(.headline)
                    Text("复制连接提示词，贴给能使用本机工具或 MCP 的 AI，即可连接并管理提醒。").font(.callout).foregroundStyle(MenoPalette.secondary)
                    HStack {
                        AIConnectionButton()
                        Button("复制 MCP 配置") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(connection.mcpConfiguration, forType: .string) }
                    }
                    Text(connection.mcpPath).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).lineLimit(3)
                    Button("打开本地数据目录") { model.openDataDirectory() }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(22).menoCard()
                if let error = model.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                Text("Meno 0.1.0 · macOS 14+ · 本地运行").font(.caption).foregroundStyle(MenoPalette.muted)
            }.padding(30)
        }.frame(minWidth: 590, minHeight: 620).foregroundStyle(MenoPalette.ink).tint(MenoPalette.controlTint)
        }.menoWindowSurface()
            .task { await refreshNotificationPermission() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                Task { await refreshNotificationPermission() }
            }
    }
    private func openNotificationSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
    }
    private func requestNotificationPermission() {
        guard !requestingPermission else { return }
        requestingPermission = true; permissionError = nil
        Task {
            defer { requestingPermission = false }
            do { _ = try await model.execute(ControlRequest(command: "notification_request", source: "ui")) }
            catch { permissionError = error.localizedDescription }
        }
    }
    private func refreshNotificationPermission() async {
        guard let reminders = model.reminders?.model else { return }
        await reminders.refreshPermission()
        if reminders.notificationsAuthorized { permissionError = nil }
        await reminders.reconcile()
    }
    private var connection: AIConnectionInfo { AIConnectionInfo(bundleURL: Bundle.main.bundleURL) }
}
