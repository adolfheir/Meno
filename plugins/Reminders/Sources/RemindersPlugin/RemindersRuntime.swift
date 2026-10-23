import AppKit
import MenoControlProtocol
import MenoPluginKit
import RemindersCore

@MainActor
final class RemindersRuntime: PluginRuntime {
    unowned let model: RemindersModel
    let presenter: any ReminderPresenting
    private let isScreenLocked: () -> Bool
    private(set) var active = false
    private var suspended = false
    private var locked = false
    var presentationSuspended: Bool { locked || suspended }
    private var timer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var revision = 0
    private var worker: Task<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(model: RemindersModel, presenter: (any ReminderPresenting)? = nil, isScreenLocked: (() -> Bool)? = nil) {
        self.model = model
        self.presenter = presenter ?? FullscreenPresenter()
        self.isScreenLocked = isScreenLocked ?? { Self.screenLocked }
    }
    func start() async throws {
        let crashRecovery = try model.service.store.metadata("runtime_active") == "true"
        try model.service.preparePlans(catchUp: crashRecovery)
        try model.service.store.setMetadata("runtime_active", "true")
        active = true; model.runtime = self; model.setRunning(true)
        locked = isScreenLocked()
        presenter.onAction = { [weak self] id, snooze in
            Task { @MainActor [weak self] in
                guard let self, self.active else { return }
                do { try await self.model.handleOccurrence(id, snooze: snooze) }
                catch { self.model.error = error.localizedDescription }
            }
        }
        for name in [NSApplication.didBecomeActiveNotification, .NSSystemTimeZoneDidChange, .NSSystemClockDidChange, NSApplication.didChangeScreenParametersNotification] {
            observe(.default, name) { [weak self] in await self?.reconcile() }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.willSleepNotification) { [weak self] in self?.suspended = true; self?.presenter.close(); self?.timer?.invalidate() }
        observe(workspace, NSWorkspace.didWakeNotification) { [weak self] in self?.suspended = false; self?.locked = self?.isScreenLocked() ?? true; await self?.reconcile() }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { [weak self] in self?.locked = true; self?.presenter.close() }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { [weak self] in self?.locked = self?.isScreenLocked() ?? true; await self?.reconcile() }
        let distributed = DistributedNotificationCenter.default()
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { [weak self] in self?.locked = true; self?.presenter.close() }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { [weak self] in self?.locked = false; await self?.reconcile() }
        await reconcile()
    }
    private static var screenLocked: Bool { (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false }
    private func observe(_ center: NotificationCenter, _ name: Notification.Name, action: @escaping @MainActor () async -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in guard self?.active == true else { return }; await action() }
        }
        observers.append((center, token))
    }
    func stop() async {
        active = false; timer?.invalidate(); timer = nil
        for (center, token) in observers { center.removeObserver(token) }; observers = []
        presenter.close(); await reconcile()
        do { try model.service.runtimeStopped() } catch { model.error = error.localizedDescription }
        model.setRunning(false); model.runtime = nil
    }
    func reconcile() async {
        revision += 1
        if worker == nil { worker = Task { await drain() } }
        await withCheckedContinuation { waiters.append($0) }
    }
    private func drain() async {
        while true {
            let snapshot = revision
            do { try await apply(snapshot); model.runtimeError = nil }
            catch { model.runtimeError = error.localizedDescription; model.error = error.localizedDescription; presenter.close() }
            if snapshot == revision { worker = nil; let done = waiters; waiters = []; done.forEach { $0.resume() }; return }
        }
    }
    private func apply(_ snapshot: Int) async throws {
        timer?.invalidate(); timer = nil
        guard active else { presenter.close(); await model.scheduler.sync([], active: false); return }
        try model.service.preparePlans(catchUp: true)
        let items = try model.service.history()
        await model.scheduler.sync(items, active: true)
        guard active, snapshot == revision else { return }
        for item in try model.service.history() where item.reminderType == .system && model.scheduler.delivered.contains(NotificationScheduler.prefix + item.id) && [.submitted, .planned, .failed].contains(item.state) {
            try model.service.setState(item.id, .delivered)
        }
        let now = model.service.now()
        if !locked && !suspended {
            for item in try model.service.history() where item.reminderType == .fullscreen && [.planned, .presenting].contains(item.state) && item.scheduledAt <= now {
                if now.timeIntervalSince(item.scheduledAt) > 1800 { try model.service.setState(item.id, .missed, detail: "超出 30 分钟遗漏补偿窗口") }
                else if item.state != .presenting { try model.service.setState(item.id, .presenting) }
            }
            presenter.show(try model.service.history().filter { $0.state == .presenting && $0.reminderType == .fullscreen })
        } else { presenter.close() }
        let future = try model.service.history().filter { [.planned, .submitted, .failed].contains($0.state) && $0.scheduledAt > now }
        if let next = future.map(\.scheduledAt).min(), !suspended {
            let timer = Timer(timeInterval: max(0.05, next.timeIntervalSince(model.service.now()) + 0.1), repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in guard self?.active == true else { return }; await self?.reconcile() }
            }
            self.timer = timer; RunLoop.main.add(timer, forMode: .common)
        }
        model.revisionForRuntime()
    }
}
