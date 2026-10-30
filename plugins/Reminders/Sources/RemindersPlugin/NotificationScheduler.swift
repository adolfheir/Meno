import Foundation
import MenoControlProtocol
import RemindersCore
import UserNotifications

@MainActor
protocol NotificationClient {
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization() async throws -> Bool
    func pendingRequests() async -> [UNNotificationRequest]
    func deliveredIDs() async -> Set<String>
    func add(_ request: UNNotificationRequest) async throws
    func remove(_ identifiers: [String])
    func removeDelivered(_ identifiers: [String])
}
@MainActor
struct SystemNotificationClient: NotificationClient {
    private var center: UNUserNotificationCenter { .current() }
    func authorizationStatus() async -> UNAuthorizationStatus { await center.notificationSettings().authorizationStatus }
    func requestAuthorization() async throws -> Bool { try await center.requestAuthorization(options: [.alert, .sound]) }
    func pendingRequests() async -> [UNNotificationRequest] { await center.pendingNotificationRequests() }
    func deliveredIDs() async -> Set<String> { Set(await center.deliveredNotifications().map(\.request.identifier)) }
    func add(_ request: UNNotificationRequest) async throws { try await center.add(request) }
    func remove(_ identifiers: [String]) { center.removePendingNotificationRequests(withIdentifiers: identifiers) }
    func removeDelivered(_ identifiers: [String]) { center.removeDeliveredNotifications(withIdentifiers: identifiers) }
}

@MainActor
final class NotificationScheduler: ObservableObject {
    static let prefix = "meno.reminders."
    static let capacity = 60
    @Published private(set) var authorization: UNAuthorizationStatus = .notDetermined
    private(set) var armedIDs: Set<String> = []
    private(set) var delivered: Set<String> = []
    private(set) var failures: [String: String] = [:]
    private(set) var pendingCount = 0
    var beforeSubmit: ((String) throws -> Void)?
    var submissionFailed: ((String, String) -> Void)?
    private let client: any NotificationClient
    private let now: () -> Date
    private var desired: [Occurrence] = []
    private var active = false
    private var revision = 0
    private var worker: Task<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(client: (any NotificationClient)? = nil, now: @escaping () -> Date = { .now }) {
        self.client = client ?? SystemNotificationClient(); self.now = now
    }
    var authorized: Bool { authorization == .authorized || authorization == .provisional }
    var authorizationLabel: String {
        switch authorization { case .authorized, .provisional: "已授权"; case .denied: "未授权"; default: "尚未请求" }
    }
    func requestPermission() async throws {
        await refreshPermission()
        guard authorization != .denied else { throw permissionDeniedError() }
        guard !authorized else { return }
        do { _ = try await client.requestAuthorization() }
        catch {
            await refreshPermission()
            let systemError = error as NSError
            if authorization == .denied || (systemError.domain == UNErrorDomain && systemError.code == UNError.Code.notificationsNotAllowed.rawValue) {
                throw permissionDeniedError()
            }
            throw error
        }
        await refreshPermission()
        if authorization == .denied { throw permissionDeniedError() }
    }
    private func permissionDeniedError() -> ControlError {
        ControlError("notifications_disabled", "系统通知未获允许，请前往「系统设置 → 通知 → Meno」打开「允许通知」。")
    }
    func refreshPermission() async { authorization = await client.authorizationStatus() }
    func dismissDelivered(_ id: String) { client.removeDelivered([Self.prefix + id]) }
    func sync(_ occurrences: [Occurrence], active: Bool) async {
        desired = occurrences; self.active = active; revision += 1
        if worker == nil { worker = Task { await drain() } }
        await withCheckedContinuation { waiters.append($0) }
    }
    private func drain() async {
        while true {
            let snapshot = revision; let items = desired; let running = active
            await apply(items, active: running, revision: snapshot)
            if snapshot == revision { worker = nil; let done = waiters; waiters = []; done.forEach { $0.resume() }; return }
        }
    }
    private func apply(_ items: [Occurrence], active running: Bool, revision snapshot: Int) async {
        authorization = await client.authorizationStatus()
        let existing = await client.pendingRequests().filter { $0.identifier.hasPrefix(Self.prefix) }
        delivered = await client.deliveredIDs()
        armedIDs = []; failures = [:]
        guard running, active, snapshot == revision, authorized else { client.remove(existing.map(\.identifier)); pendingCount = 0; return }
        let now = now()
        let eligible = items.filter { $0.reminderType == .system && [.planned, .submitted, .failed].contains($0.state)
            && ($0.scheduledAt > now || ($0.state != .submitted && now.timeIntervalSince($0.scheduledAt) <= 1800)) }
            .sorted { $0.scheduledAt < $1.scheduledAt }
        let selected = Array(eligible.prefix(Self.capacity))
        let wanted = Set(selected.map { Self.prefix + $0.id })
        client.remove(existing.map(\.identifier).filter { !wanted.contains($0) })
        let existingIDs = Set(existing.map(\.identifier))
        for item in eligible.dropFirst(Self.capacity) { failures[item.id] = "系统通知滚动队列已满（60 条），较近计划触发后自动补入" }
        for item in selected {
            guard active, snapshot == revision else { return }
            let id = Self.prefix + item.id
            if delivered.contains(id) { continue }
            do {
                // Submission intent is durable before crossing the OS boundary.
                if item.state != .submitted { try beforeSubmit?(item.id) }
                if !existingIDs.contains(id) {
                    let content = UNMutableNotificationContent(); content.title = item.title
                    content.body = item.note.isEmpty ? "到提醒时间了。" : item.note
                    content.sound = .default; content.categoryIdentifier = "MENO_REMINDER"
                    content.userInfo = ["meno.pluginID": RemindersPlugin.descriptor.id, "meno.occurrenceID": item.id]
                    let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, item.scheduledAt.timeIntervalSince(self.now())), repeats: false)
                    try await client.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
                }
                armedIDs.insert(item.id)
            } catch { failures[item.id] = "系统通知提交失败：\(error.localizedDescription)"; submissionFailed?(item.id, error.localizedDescription) }
        }
        pendingCount = armedIDs.count
    }
}
