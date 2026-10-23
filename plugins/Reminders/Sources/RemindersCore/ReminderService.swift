import Combine
import Foundation
import MenoControlProtocol

public struct WriteOutcome {
    public let original: JSONValue
    public let replayed: Bool
    public let enableRequested: Bool
}
@MainActor
public final class ReminderService: ObservableObject {
    public let store: ReminderStore
    @Published public private(set) var revision = 0
    public var now: () -> Date
    public var calendar: () -> Calendar = { .autoupdatingCurrent }
    public init(directory: URL, now: @escaping () -> Date = { .now }) throws {
        store = try ReminderStore(directory: directory); self.now = now
        try ReminderBook(reminders: store.reminders()).validate()
        _ = try store.occurrences()
        _ = try configuredDefaultType()
    }
    public func changed() { revision += 1 }
    public var defaultType: ReminderType { (try? configuredDefaultType()) ?? .system }
    private func configuredDefaultType() throws -> ReminderType {
        let text = try store.metadata("default_type") ?? "system"
        guard let type = ReminderType(rawValue: text) else { throw ControlError("invalid_data", "默认提醒类型数据无效，原数据已保留。") }; return type
    }
    public func setDefaultType(_ type: ReminderType) throws { try store.setMetadata("default_type", type.rawValue); changed() }
    public func reminders() throws -> [Reminder] { try store.reminders() }
    public func history() throws -> [Occurrence] { try store.occurrences() }
    public func enabledPreference() throws -> Bool { try store.metadata("app_enabled") == "true" }

    public func write(_ command: String, arguments raw: [String: JSONValue], source: String) throws -> WriteOutcome {
        var args = raw
        let allowed: Set<String>
        switch command {
        case "reminders_create": allowed = ["title", "note", "schedule", "reminderType", "requestId", "enablePlugin"]
        case "reminders_update": allowed = ["id", "title", "note", "schedule", "reminderType", "isEnabled", "requestId"]
        case "reminders_cancel": allowed = ["id", "requestId"]
        case "apps_set_enabled": allowed = ["appId", "enabled", "requestId"]
        default: throw ControlError("unknown_command", "未知写操作。")
        }
        try Self.checkKeys(args, allowed: allowed)
        let requestID = try Self.requiredString(args, "requestId", max: 200)
        args["requestId"] = .string(requestID)
        for key in ["title", "note"] where args[key] != nil {
            guard let text = args[key]?.string else { throw ControlError("invalid_argument", "\(key) 必须是字符串。") }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count <= (key == "title" ? 500 : 10000), key != "title" || !trimmed.isEmpty else { throw ControlError("invalid_argument", "提醒内容不能为空，标题最多 500 字、备注最多 10000 字。") }
            args[key] = .string(trimmed)
        }
        if let type = args["reminderType"] { guard let t = type.string, ReminderType(rawValue: t) != nil else { throw ControlError("invalid_type", "reminderType 仅支持 system 或 fullscreen。") } }
        for key in ["isEnabled", "enablePlugin", "enabled"] where args[key] != nil {
            guard args[key]?.bool != nil else { throw ControlError("invalid_argument", "\(key) 必须是布尔值。") }
        }
        if command == "apps_set_enabled" {
            let appID = MenoIdentity.pluginID(try Self.optionalString(args, "appId") ?? MenoIdentity.remindersID)
            guard appID == MenoIdentity.remindersID else { throw ControlError("app_not_found", "未安装此子应用。") }
            args["appId"] = .string(appID)
            guard args["enabled"]?.bool != nil else { throw ControlError("invalid_argument", "enabled 为必填布尔值。") }
        }
        let fingerprint = JSONValue.object(["command": .string(command), "arguments": .object(args)]).text()
        if let original = try store.original(requestID: requestID, fingerprint: fingerprint) {
            return WriteOutcome(original: original, replayed: true, enableRequested: false)
        }
        let current = now()
        let original: JSONValue = try store.transaction {
            if command == "apps_set_enabled" {
                let enabled = args["enabled"]!.bool!
                try store.setMetadata("app_enabled", enabled ? "true" : "false")
                let result = JSONValue.object(["saved": .bool(true), "requestedEnabled": .bool(enabled), "appId": .string(MenoIdentity.remindersID)])
                try store.record(requestID: requestID, fingerprint: fingerprint, result: result)
                return result
            }
            var reminder: Reminder
            if command == "reminders_create" {
                let title = try Self.requiredString(args, "title", max: 500)
                let schedule = try parseSchedule(args["schedule"], at: current)
                let resolvedType: ReminderType
                if let text = args["reminderType"]?.string, let type = ReminderType(rawValue: text) { resolvedType = type }
                else { resolvedType = try configuredDefaultType() }
                reminder = Reminder(title: title, note: try Self.optionalString(args, "note") ?? "", schedule: schedule,
                    reminderType: resolvedType, source: source, now: current)
            } else {
                let idText = try Self.requiredString(args, "id", max: 100)
                guard let id = UUID(uuidString: idText), let found = try store.reminders().first(where: { $0.id == id }) else { throw ControlError("reminder_not_found", "未找到这个提醒 ID。") }
                reminder = found
                if command == "reminders_cancel" { reminder.isCancelled = true; reminder.isEnabled = false }
                else {
                    guard !reminder.isCancelled else { throw ControlError("reminder_cancelled", "事项已取消，请创建新事项。") }
                    guard args.keys.contains(where: { !["id", "requestId"].contains($0) }) else { throw ControlError("invalid_argument", "至少提供一个要修改的字段。") }
                    if let value = args["title"]?.string { reminder.title = value }
                    if let value = args["note"]?.string { reminder.note = value }
                    if let value = args["reminderType"]?.string { reminder.reminderType = ReminderType(rawValue: value)! }
                    if args["schedule"] != nil { reminder.schedule = try parseSchedule(args["schedule"], at: current) }
                    if let value = args["isEnabled"]?.bool {
                        if value && reminder.schedule.rule == .once && reminder.schedule.date <= current { throw ControlError("past_date", "单次时间已过，请同时提供未来时间。") }
                        reminder.isEnabled = value
                    }
                }
                reminder.revision += 1; reminder.updatedAt = current
                for var occurrence in try store.occurrences() where occurrence.reminderID == reminder.id && occurrence.state.isPending {
                    occurrence.state = .cancelled; occurrence.updatedAt = current; occurrence.detail = "提醒已修改、暂停或取消"; try store.save(occurrence)
                }
            }
            try store.save(reminder)
            if args["enablePlugin"]?.bool == true { try store.setMetadata("app_enabled", "true") }
            let result = JSONValue.object(["id": .string(reminder.id.uuidString), "saved": .bool(true), "reminder": try .encode(reminder)])
            try store.record(requestID: requestID, fingerprint: fingerprint, result: result)
            return result
        }
        changed()
        return WriteOutcome(original: original, replayed: false, enableRequested: args["enablePlugin"]?.bool == true)
    }

    public func parseSchedule(_ value: JSONValue?, at current: Date) throws -> ReminderSchedule {
        guard let object = value?.object else { throw ControlError("invalid_schedule", "schedule 必须是结构化对象。") }
        let kind = try Self.requiredString(object, "kind", max: 20)
        switch kind {
        case "once":
            try Self.checkKeys(object, allowed: ["kind", "at"])
            let at = try Self.requiredString(object, "at", max: 80)
            guard at.range(of: "(Z|[+-][0-9]{2}:[0-9]{2})$", options: .regularExpression) != nil, let date = TimeText.parse(at) else { throw ControlError("invalid_schedule", "at 必须是带时区的 ISO 8601 时间。") }
            guard date > current else { throw ControlError("past_date", "单次提醒必须指定未来时间。") }
            return ReminderSchedule(rule: .once, date: date)
        case "delay":
            try Self.checkKeys(object, allowed: ["kind", "afterSeconds"])
            guard let seconds = object["afterSeconds"]?.number, seconds.isFinite, seconds > 0, seconds <= 315_360_000 else { throw ControlError("invalid_schedule", "afterSeconds 必须大于零且不超过十年。") }
            return ReminderSchedule(rule: .once, date: current.addingTimeInterval(seconds))
        case "daily", "weekdays":
            try Self.checkKeys(object, allowed: ["kind", "time"])
            let text = try Self.requiredString(object, "time", max: 5)
            guard text.range(of: "^([01][0-9]|2[0-3]):[0-5][0-9]$", options: .regularExpression) != nil else { throw ControlError("invalid_schedule", "重复时间必须为 24 小时制 HH:mm。") }
            var schedule = ReminderSchedule(rule: kind == "daily" ? .daily : .weekdays, date: current)
            let parts = text.split(separator: ":"); schedule.hour = Int(parts[0])!; schedule.minute = Int(parts[1])!
            return schedule
        default: throw ControlError("invalid_schedule", "时间类型仅支持 once、delay、daily、weekdays。")
        }
    }
    public static func checkKeys(_ args: [String: JSONValue], allowed: Set<String>) throws {
        if let key = args.keys.sorted().first(where: { !allowed.contains($0) }) { throw ControlError("unknown_argument", "不支持的参数：\(key)") }
    }
    public static func requiredString(_ args: [String: JSONValue], _ key: String, max: Int) throws -> String {
        guard let value = args[key]?.string, !value.contains("\0"), !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.count <= max else { throw ControlError("invalid_argument", "\(key) 为必填字符串，最多 \(max) 字且不能包含空字符。") }; return value
    }
    public static func optionalString(_ args: [String: JSONValue], _ key: String) throws -> String? {
        guard let value = args[key] else { return nil }; guard let text = value.string else { throw ControlError("invalid_argument", "\(key) 必须是字符串。") }; return text
    }

    /// Materialize one next regular occurrence per item. Snoozes are independent.
    public func preparePlans(catchUp: Bool) throws {
        let current = now()
        try store.transaction {
            for var occurrence in try store.occurrences() where [.planned, .failed].contains(occurrence.state) && occurrence.scheduledAt <= current {
                if !catchUp || current.timeIntervalSince(occurrence.scheduledAt) > 1800 {
                    occurrence.state = .missed; occurrence.updatedAt = current; occurrence.detail = "后台暂停期间到期或超出 30 分钟恢复窗口"; try store.save(occurrence)
                }
            }
            for reminder in try store.reminders() where reminder.isEnabled && !reminder.isCancelled {
                var dates: [Date] = []
                if reminder.schedule.rule == .once { dates = [reminder.schedule.date] }
                else {
                    if let next = reminder.schedule.nextFireDate(after: current, calendar: calendar()) { dates.append(next) }
                    for var old in try store.occurrences() where old.reminderID == reminder.id && old.reminderRevision == reminder.revision && !old.isSnooze && old.scheduledAt > current && [.planned, .submitted, .failed].contains(old.state) && !dates.contains(old.scheduledAt) {
                        old.state = .cancelled; old.updatedAt = current; old.detail = "时区或系统时间变化重算"; try store.save(old)
                    }
                    if catchUp {
                        let checkpoint = (try store.metadata("runtime_checkpoint")).flatMap(TimeText.parse) ?? current.addingTimeInterval(-1800)
                        let after = max(current.addingTimeInterval(-1800), checkpoint, reminder.createdAt.addingTimeInterval(-0.001))
                        if let missed = reminder.schedule.nextFireDate(after: after, calendar: calendar()), missed <= current { dates.append(missed) }
                    }
                }
                for date in dates {
                    var occurrence = Occurrence(reminder: reminder, at: date, now: current)
                    if let old = try store.occurrences().first(where: { $0.id == occurrence.id }) {
                        if old.state == .cancelled && old.detail == "时区或系统时间变化重算" && date > current { try store.save(occurrence) }
                        continue
                    }
                    if date <= current && (!catchUp || current.timeIntervalSince(date) > 1800) {
                        occurrence.state = .missed; occurrence.detail = "后台暂停期间到期或超出 30 分钟恢复窗口"
                    }
                    try store.save(occurrence)
                }
            }
            try store.setMetadata("runtime_checkpoint", TimeText.format(current))
        }
        changed()
    }
    public func setState(_ id: String, _ state: OccurrenceState, detail: String? = nil) throws {
        guard var occurrence = try store.occurrences().first(where: { $0.id == id }) else { throw ControlError("occurrence_not_found", "未找到这次触发。") }
        occurrence.state = state; occurrence.detail = detail; occurrence.updatedAt = now(); try store.save(occurrence); changed()
    }
    public func handleOccurrence(_ id: String, snooze: Bool) throws {
        try store.transaction {
            guard var occurrence = try store.occurrences().first(where: { $0.id == id }) else { throw ControlError("occurrence_not_found", "未找到这次触发。") }
            guard [.presenting, .delivered, .submitted].contains(occurrence.state),
                let reminder = try store.reminders().first(where: { $0.id == occurrence.reminderID }), !reminder.isCancelled, reminder.isEnabled else { throw ControlError("occurrence_inactive", "这次提醒已经处理或撤销。") }
            occurrence.state = snooze ? .snoozed : .acknowledged; occurrence.updatedAt = now(); try store.save(occurrence)
            if snooze { try store.save(Occurrence(reminder: reminder, at: now().addingTimeInterval(300), isSnooze: true, now: now())) }
        }
        changed()
    }
    public func runtimeStopped() throws {
        try store.transaction {
            try store.setMetadata("runtime_active", "false")
            try store.setMetadata("runtime_checkpoint", TimeText.format(now()))
            for var occurrence in try store.occurrences() {
                if occurrence.state == .presenting { occurrence.state = .missed; occurrence.detail = "后台已停止" }
                else if occurrence.state == .submitted && occurrence.scheduledAt > now() { occurrence.state = .planned }
                else { continue }
                occurrence.updatedAt = now(); try store.save(occurrence)
            }
        }
        changed()
    }
}
