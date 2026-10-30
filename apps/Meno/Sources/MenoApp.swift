import AppKit
import Combine
import Darwin
import MenoControlProtocol
import MenoPluginKit
import RemindersPlugin
import SwiftUI
import UserNotifications

@main
enum MenoApp {
    @MainActor static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate(); application.delegate = delegate
        application.setActivationPolicy(.accessory); application.run()
        withExtendedLifetime(delegate) {}
    }
}

private final class MenoHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var model: AppModel!
    private var windows: [String: NSWindow] = [:]
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var terminating = false
    private var instanceLock: InstanceLock?
    private var control: LocalControlServer?
    private var hotkey: GlobalHotkey?
    private var signalSources: [DispatchSourceSignal] = []
    func applicationDidFinishLaunching(_ notification: Notification) {
        do { instanceLock = try InstanceLock(directory: MenoIdentity.dataDirectory) }
        catch {
            if let existing = NSRunningApplication.runningApplications(withBundleIdentifier: MenoIdentity.bundleID).first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) { existing.activate(options: []) }
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); NSApp.terminate(nil); return
        }
        installMenus()
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0) }; source.resume(); signalSources.append(source)
        }
        model = AppModel(); model.onOpenApp = { [weak self] in self?.showWindow($0) }
        model.onHotkeyChange = { [weak self] in self?.configureHotkey() }
        UNUserNotificationCenter.current().delegate = self
        let category = UNNotificationCategory(identifier: "MENO_REMINDER", actions: [
            UNNotificationAction(identifier: "MENO_ACK", title: "知道了", options: []),
            UNNotificationAction(identifier: "MENO_SNOOZE", title: "5 分钟后提醒", options: []),
        ], intentIdentifiers: [], options: [.customDismissAction])
        UNUserNotificationCenter.current().setNotificationCategories([category])
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = MenuBarIcon.makeImage()
            button.target = self; button.action = #selector(togglePopover); button.toolTip = "Meno · 到点提醒"
        }
        popover = NSPopover(); popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: MenuPopoverView(model: model, onOpen: { [weak self] in self?.showWindow($0) }, onQuit: { NSApp.terminate(nil) }))
        configureHotkey()
        Task { [self] in
            await model.host.restore(); model.ready = true
            do {
                let server = LocalControlServer(path: MenoIdentity.socketPath) { [weak self] request in
                    guard let self else { return ControlResponse(id: request.id, error: ControlError("host_closed", "宿主已关闭。")) }
                    return await self.model.response(request)
                }
                try server.start(); control = server
            } catch { model.error = error.localizedDescription }
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(MenoIdentity.remindersID); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model != nil else { return .terminateNow }
        if terminating { return .terminateLater }
        terminating = true; model.ready = false; control?.stop(); hotkey = nil; popover?.close()
        Task { await model.host.shutdown(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
    }
    @objc private func focusReminder() { model?.reminders?.model.focusCurrentReminder() }
    private func showWindow(_ id: String) {
        guard model != nil else { return }; popover?.close()
        if windows[id] == nil {
            do {
                let view: AnyView
                if id == "settings" { view = AnyView(SettingsView(model: model)) }
                else { view = try model.host.module(for: id).makeView() }
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: id == "settings" ? 650 : 850, height: id == "settings" ? 780 : 790),
                    styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
                window.title = id == "settings" ? "Meno 设置" : "到点提醒 · Meno"
                window.isReleasedWhenClosed = false; window.titlebarAppearsTransparent = true
                window.styleMask.insert(.fullSizeContentView)
                window.isOpaque = true; window.backgroundColor = NSColor(MenoPalette.canvasTop)
                window.minSize = NSSize(width: id == "settings" ? 590 : 720, height: 650)
                let content = MenoHostingView(rootView: view)
                window.contentView = content
                window.center(); window.setFrameAutosaveName("Meno." + id)
                windows[id] = window
            } catch {
                model.error = error.localizedDescription
                if id != "settings" { showWindow("settings") }; return
            }
        }
        windows[id]?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: Notification.Name("MenoFocusComposer"), object: nil)
    }
    private func configureHotkey() {
        switch model.preferences.appearance ?? "dark" {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
        hotkey = nil
        guard model.preferences.hotkeyEnabled ?? true else { model.hotkeyStatus = "快捷键已关闭，可从菜单栏打开到点提醒。"; return }
        do {
            hotkey = try GlobalHotkey(key: model.preferences.hotkeyKey ?? "M", modifiers: model.preferences.hotkeyModifiers ?? "control-option-shift") { [weak self] in self?.showWindow(MenoIdentity.remindersID) }
            model.hotkeyStatus = "快捷键已注册；冲突时可更换组合键或字母。"
        } catch { model.hotkeyStatus = error.localizedDescription + "；可从菜单栏打开。" }
    }
    private func installMenus() {
        let menu = NSMenu(); let appItem = NSMenuItem(); menu.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        let focus = NSMenuItem(title: "处理当前全屏提醒", action: #selector(focusReminder), keyEquivalent: "r")
        focus.target = self; focus.keyEquivalentModifierMask = [.command, .shift]; appMenu.addItem(focus)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 Meno", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let editItem = NSMenuItem(); editItem.title = "编辑"; menu.addItem(editItem)
        let edit = NSMenu(title: "编辑"); editItem.submenu = edit
        for (title, action, key) in [("撤销", "undo:", "z"), ("剪切", "cut:", "x"), ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] { edit.addItem(withTitle: title, action: Selector(action), keyEquivalent: key) }
        let windowItem = NSMenuItem(); windowItem.title = "窗口"; menu.addItem(windowItem)
        let windowMenu = NSMenu(title: "窗口"); windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        NSApp.mainMenu = menu
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let id = notification.request.content.userInfo["meno.occurrenceID"] as? String
        Task { @MainActor [weak self] in
            if let id { try? self?.model?.reminders?.model.service.setState(id, .delivered) }
        }
        completionHandler([.banner, .sound, .list])
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["meno.occurrenceID"] as? String
        let action = response.actionIdentifier
        Task { @MainActor [weak self] in
            guard let self else { completionHandler(); return }
            if let id, action == "MENO_ACK" || action == "MENO_SNOOZE" {
                do { try await self.model.reminders?.model.handleOccurrence(id, snooze: action == "MENO_SNOOZE") } catch { self.model.error = error.localizedDescription }
            } else if action == UNNotificationDefaultActionIdentifier { self.showWindow(MenoIdentity.remindersID) }
            completionHandler()
        }
    }
}
