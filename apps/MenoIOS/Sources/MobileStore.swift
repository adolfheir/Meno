import BackgroundTasks
import Combine
import MenoControlProtocol
import RemindersCore
import SwiftUI
import UserNotifications

@MainActor
final class MobileStore: ObservableObject {
    static let shared = MobileStore()
    let service: ReminderService?
    let sync: ReminderSync?
    @Published private(set) var reminders: [Reminder] = []
    @Published private(set) var history: [Occurrence] = []
    @Published private(set) var permission: UNAuthorizationStatus = .notDetermined
    @Published var error: String?
    private var revision: AnyCancellable?
    private var notificationWorker: Task<Void, Never>?
    private var needsNotificationRefresh = false
    private var refreshTimer: Task<Void, Never>?

    private init() {
        do {
            let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                         appropriateFor: nil, create: true)
                .appendingPathComponent("Meno", isDirectory: true)
            let service = try ReminderService(directory: directory)
            let sync = ReminderSync(service: service)
            self.service = service
            self.sync = sync
            reload()
            revision = service.$revision.dropFirst().sink { [weak self] _ in
                self?.reload()
                self?.refreshNotifications()
            }
        } catch {
            service = nil
            sync = nil
            self.error = error.localizedDescription
        }
    }

    func setActive(_ active: Bool) {
        refreshTimer?.cancel()
        refreshTimer = nil
        if !active {
            sync?.stop()
            scheduleBackgroundRefresh()
            return
        }
        sync?.start()
        refreshTimer = Task { [weak self] in
            while !Task.isCancelled {
                self?.refreshNotifications()
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }
    }

    static let refreshIdentifier = "com.meno.ios.sync-refresh"

    func scheduleBackgroundRefresh() {
        guard sync?.isEnabled == true else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshIdentifier)
        request.earliestBeginDate = Date.now.addingTimeInterval(15 * 60)
        // The system chooses whether and when to grant background refresh.
        try? BGTaskScheduler.shared.submit(request)
    }

    func refreshInBackground(_ task: BGAppRefreshTask) {
        scheduleBackgroundRefresh()
        let work = Task {
            await sync?.syncNow()
            if !Task.isCancelled {
                refreshNotifications()
                await notificationWorker?.value
            }
            task.setTaskCompleted(success: !Task.isCancelled && sync?.hasError != true)
        }
        task.expirationHandler = { work.cancel() }
    }

    func write(_ command: String, arguments: [String: JSONValue]) throws {
        guard let service else { throw ControlError("storage_error", "提醒数据库无法打开。") }
        var args = arguments
        args["requestId"] = .string(UUID().uuidString)
        _ = try service.write(command, arguments: args, source: "ios")
    }

    func requestNotifications() async {
        do { _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
        catch { self.error = error.localizedDescription }
        refreshNotifications()
    }

    func handle(_ response: UNNotificationResponse) async {
        guard let service, ["MENO_ACK", "MENO_SNOOZE"].contains(response.actionIdentifier),
              let info = NotificationInfo(response.notification.request) else { return }
        do {
            try service.handleNotification(reminderID: info.reminderID, revision: info.revision, occurrenceID: info.id,
                                           at: info.at, snooze: response.actionIdentifier == "MENO_SNOOZE")
            await notificationWorker?.value
            await sync?.syncNow()
        } catch let error as ControlError where error.code == "occurrence_inactive" { }
        catch { self.error = error.localizedDescription }
    }

    func canPresent(_ request: UNNotificationRequest) -> Bool {
        guard let info = NotificationInfo(request),
              let reminder = reminders.first(where: { $0.id == info.reminderID }),
              reminder.isEnabled, !reminder.isCancelled, reminder.revision == info.revision else { return false }
        return !history.contains { $0.id == info.id && [.acknowledged, .snoozed, .cancelled].contains($0.state) }
    }

    func refreshNotifications() {
        needsNotificationRefresh = true
        guard notificationWorker == nil else { return }
        notificationWorker = Task { [weak self] in
            guard let self else { return }
            while needsNotificationRefresh {
                needsNotificationRefresh = false
                do { try await reconcileNotifications() }
                catch { self.error = "通知安排失败：\(error.localizedDescription)" }
            }
            notificationWorker = nil
        }
    }

    private func reload() {
        guard let service else { return }
        do {
            reminders = try service.reminders().sorted { $0.updatedAt > $1.updatedAt }
            history = try service.history()
        } catch { self.error = error.localizedDescription }
    }

    private func reconcileNotifications() async throws {
        let center = UNUserNotificationCenter.current()
        permission = await center.notificationSettings().authorizationStatus
        let pending = await center.pendingNotificationRequests().filter { $0.identifier.hasPrefix(NotificationInfo.prefix) }
        let delivered = await center.deliveredNotifications().map(\.request).filter { $0.identifier.hasPrefix(NotificationInfo.prefix) }
        center.removeDeliveredNotifications(withIdentifiers: delivered.filter { !canPresent($0) }.map(\.identifier))
        guard service != nil, [.authorized, .provisional, .ephemeral].contains(permission) else {
            center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier))
            return
        }
        let now = Date.now
        let wanted = NotificationPlan.next(reminders: reminders, history: history, now: now)
        let identifiers = Set(wanted.map { NotificationInfo.prefix + $0.id })
        center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { !identifiers.contains($0) })
        let existing = Dictionary(uniqueKeysWithValues: pending.map { ($0.identifier, $0.content) })
        for occurrence in wanted {
            if needsNotificationRefresh { return }
            let key = NotificationInfo.prefix + occurrence.id
            let body = occurrence.note.isEmpty ? "到提醒时间了。" : occurrence.note
            if existing[key]?.title == occurrence.title, existing[key]?.body == body { continue }

            let content = UNMutableNotificationContent()
            content.title = occurrence.title
            content.body = body
            content.sound = .default
            content.categoryIdentifier = "MENO_REMINDER"
            content.userInfo = NotificationInfo(occurrence).userInfo
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, occurrence.scheduledAt.timeIntervalSinceNow), repeats: false)
            try await center.add(UNNotificationRequest(identifier: key, content: content, trigger: trigger))
        }
    }
}

private struct NotificationInfo {
    static let prefix = "meno.reminders."
    let id: String
    let reminderID: UUID
    let revision: Int
    let at: Date

    init(_ occurrence: Occurrence) {
        id = occurrence.id
        reminderID = occurrence.reminderID
        revision = occurrence.reminderRevision
        at = occurrence.scheduledAt
    }

    init?(_ request: UNNotificationRequest) {
        let info = request.content.userInfo
        guard let id = info["id"] as? String, let item = info["reminderID"] as? String,
              let reminderID = UUID(uuidString: item), let revision = info["revision"] as? Int,
              let date = info["at"] as? String, let at = TimeText.parse(date) else { return nil }
        self.id = id
        self.reminderID = reminderID
        self.revision = revision
        self.at = at
    }

    var userInfo: [String: Any] {
        ["id": id, "reminderID": reminderID.uuidString, "revision": revision, "at": TimeText.format(at)]
    }
}

private enum NotificationPlan {
    private struct Candidate {
        let occurrence: Occurrence
        let repeats: Reminder?
    }

    static func next(reminders: [Reminder], history: [Occurrence], now: Date) -> [Occurrence] {
        let active = Dictionary(uniqueKeysWithValues: reminders.filter { $0.isEnabled && !$0.isCancelled }.map { ($0.id, $0) })
        let handled = Set(history.filter { [.acknowledged, .snoozed].contains($0.state) }.map(\.id))
        var candidates = active.values.compactMap { item -> Candidate? in
            guard let date = item.nextFireDate(after: now) else { return nil }
            return Candidate(occurrence: Occurrence(reminder: item, at: date, now: now), repeats: item)
        }
        for item in history where item.isSnooze && item.state.isPending && item.scheduledAt > now {
            if active[item.reminderID]?.revision == item.reminderRevision {
                candidates.append(Candidate(occurrence: item, repeats: nil))
            }
        }
        let horizon = now.addingTimeInterval(30 * 86_400)
        var result: [Occurrence] = []
        while result.count < 60, let index = candidates.indices.min(by: {
            let a = candidates[$0].occurrence, b = candidates[$1].occurrence
            return a.scheduledAt == b.scheduledAt ? a.id < b.id : a.scheduledAt < b.scheduledAt
        }) {
            let candidate = candidates.remove(at: index)
            let item = candidate.occurrence
            if !handled.contains(item.id) { result.append(item) }
            if let reminder = candidate.repeats, let next = reminder.nextFireDate(after: item.scheduledAt), next <= horizon {
                candidates.append(Candidate(occurrence: Occurrence(reminder: reminder, at: next, now: now), repeats: reminder))
            }
        }
        return result
    }
}

final class MobileNotificationDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([UNNotificationCategory(identifier: "MENO_REMINDER", actions: [
            UNNotificationAction(identifier: "MENO_ACK", title: "知道了"),
            UNNotificationAction(identifier: "MENO_SNOOZE", title: "5 分钟后提醒"),
        ], intentIdentifiers: [])])
        BGTaskScheduler.shared.register(forTaskWithIdentifier: MobileStore.refreshIdentifier, using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else { task.setTaskCompleted(success: false); return }
            Task { @MainActor in MobileStore.shared.refreshInBackground(refresh) }
        }
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await MobileStore.shared.handle(response)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        MobileStore.shared.canPresent(notification.request) ? [.banner, .sound, .list] : []
    }
}
