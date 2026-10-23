import Foundation
import MenoControlProtocol

public enum ReminderType: String, Codable, CaseIterable, Identifiable, Sendable {
    case system, fullscreen
    public var id: Self { self }
    public var label: String { self == .system ? "系统通知" : "全屏提醒" }
    public var symbol: String { self == .system ? "bell" : "rectangle.inset.filled" }
}

public enum RepeatRule: String, Codable, CaseIterable, Identifiable, Sendable {
    case once, daily, weekdays
    public var id: Self { self }
    public var label: String {
        switch self {
        case .once: "仅一次"
        case .daily: "每天"
        case .weekdays: "周一至周五"
        }
    }
}

public struct ReminderSchedule: Codable, Equatable, Sendable {
    public var rule: RepeatRule
    public var date: Date
    // Recurring wall-clock times must not change when the system time zone changes.
    public var hour: Int
    public var minute: Int

    public init(rule: RepeatRule, date: Date, calendar: Calendar = .current) {
        self.rule = rule
        self.date = date
        self.hour = calendar.component(.hour, from: date)
        self.minute = calendar.component(.minute, from: date)
    }

    public var isValid: Bool { (0...23).contains(hour) && (0...59).contains(minute) }

    public func nextFireDate(after now: Date, calendar: Calendar = .current) -> Date? {
        guard isValid else { return nil }
        if rule == .once { return date > now ? date : nil }
        // Search one wall-clock occurrence per day. The first occurrence on a DST
        // fold is used, even when now lies between the two equal clock readings.
        for offset in 0...8 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)) else { continue }
            let weekday = calendar.component(.weekday, from: day)
            if rule == .weekdays && !(2...6).contains(weekday) { continue }
            let match = DateComponents(hour: hour, minute: minute, second: 0)
            if let candidate = calendar.nextDate(after: day.addingTimeInterval(-0.001), matching: match,
                matchingPolicy: .nextTime, repeatedTimePolicy: .first), calendar.isDate(candidate, inSameDayAs: day), candidate > now { return candidate }
        }
        return nil
    }

    public func notificationDates(after now: Date, calendar: Calendar = .current) -> [DateComponents] {
        guard nextFireDate(after: now, calendar: calendar) != nil else { return [] }
        if rule == .once {
            var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
            components.timeZone = calendar.timeZone
            return [components]
        }
        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        components.second = 0
        if rule == .daily { return [components] }
        return (2...6).map { weekday in
            var match = components
            match.weekday = weekday
            return match
        }
    }
}

public struct Reminder: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var note: String
    public var schedule: ReminderSchedule
    public var isEnabled: Bool
    public var reminderType: ReminderType
    public var isCancelled: Bool
    public var source: String
    public var createdAt: Date
    public var updatedAt: Date
    public var revision: Int

    public init(id: UUID = UUID(), title: String, note: String = "", schedule: ReminderSchedule, isEnabled: Bool = true,
                reminderType: ReminderType = .system, source: String = "ui", now: Date = .now) {
        self.id = id
        self.title = title
        self.note = note
        self.schedule = schedule
        self.isEnabled = isEnabled
        self.reminderType = reminderType; self.isCancelled = false; self.source = source
        self.createdAt = now; self.updatedAt = now; self.revision = 1
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, note, schedule, isEnabled, reminderType, isCancelled, source, createdAt, updatedAt, revision
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); title = try c.decode(String.self, forKey: .title)
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        schedule = try c.decode(ReminderSchedule.self, forKey: .schedule)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        reminderType = try c.decodeIfPresent(ReminderType.self, forKey: .reminderType) ?? .system
        isCancelled = try c.decodeIfPresent(Bool.self, forKey: .isCancelled) ?? false
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? "legacy"
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        revision = try c.decodeIfPresent(Int.self, forKey: .revision) ?? 1
    }

    public func nextFireDate(after now: Date = .now) -> Date? {
        isEnabled && !isCancelled ? schedule.nextFireDate(after: now) : nil
    }
}

public enum OccurrenceState: String, Codable, Sendable {
    case planned, submitted, delivered, presenting, acknowledged, snoozed, missed, cancelled, failed
    public var label: String {
        switch self {
        case .planned: "等待调度"
        case .submitted: "已提交系统，展示待核实"
        case .delivered: "通知中心已送达，未确认"
        case .presenting: "全屏展示中"
        case .acknowledged: "已确认"
        case .snoozed: "已延后 5 分钟"
        case .missed: "已错过，未补弹"
        case .cancelled: "计划已撤销"
        case .failed: "调度失败，可重试"
        }
    }
    public var isPending: Bool { [.planned, .submitted, .failed, .presenting].contains(self) }
}
public struct Occurrence: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let reminderID: UUID
    public let reminderRevision: Int
    public let title: String
    public let note: String
    public let reminderType: ReminderType
    public let scheduledAt: Date
    public let isSnooze: Bool
    public var state: OccurrenceState
    public var updatedAt: Date
    public var detail: String?
    public init(reminder: Reminder, at: Date, isSnooze: Bool = false, now: Date = .now) {
        id = isSnooze ? UUID().uuidString : "\(reminder.id.uuidString).\(reminder.revision).\(Int64((at.timeIntervalSince1970 * 1000).rounded()))"
        reminderID = reminder.id; reminderRevision = reminder.revision; title = reminder.title; note = reminder.note
        reminderType = reminder.reminderType; scheduledAt = at; self.isSnooze = isSnooze; state = .planned; updatedAt = now
    }
}

public struct ReminderBook: Codable, Equatable {
    public var schemaVersion = 1
    public var reminders: [Reminder]

    public init(reminders: [Reminder] = []) { self.reminders = reminders }

    public func validate() throws {
        guard schemaVersion == 1 else { throw ReminderError.unsupportedVersion }
        guard Set(reminders.map(\.id)).count == reminders.count,
              reminders.allSatisfy({ $0.schedule.isValid && !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        else { throw ReminderError.invalidData }
    }
}

public enum ReminderError: LocalizedError {
    case unsupportedVersion, invalidData, titleRequired, pastDate, tooManyRequests

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion: "提醒数据版本较新，请更新 Meno 后重试。"
        case .invalidData: "提醒数据格式有误，原文件已保留，请检查数据目录。"
        case .titleRequired: "请填写提醒内容。"
        case .pastDate: "请选择未来的提醒时间。"
        case .tooManyRequests: "待触发的通知数量超过 60 个，请先关闭一些提醒；工作日提醒会占用 5 个通知。"
        }
    }
}
