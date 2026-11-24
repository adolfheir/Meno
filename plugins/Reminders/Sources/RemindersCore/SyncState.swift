import Foundation
import MenoControlProtocol

struct SyncAction: Codable, Equatable {
    let occurrence: Occurrence
    let snooze: Occurrence?

    func merging(_ other: Self) throws -> Self {
        if self == other { return self }
        if occurrence.state != other.occurrence.state {
            // Acknowledging an occurrence suppresses competing postponements.
            return occurrence.state == .acknowledged ? self : other
        }
        let a = try JSONEncoder.meno.encode(self)
        let b = try JSONEncoder.meno.encode(other)
        return a.lexicographicallyPrecedes(b) ? other : self
    }
}

struct SyncState: Codable, Equatable {
    var reminders: [Reminder] = []
    var actions: [SyncAction] = []
    var clocks: [String: ReminderClock] = [:]

    var maxCounter: Int { clocks.values.map(\.maxCounter).max() ?? 0 }

    func validated() throws -> SyncState {
        try ReminderBook(reminders: reminders).validate()
        let ids = Set(reminders.map(\.id))
        let keys = Set(ids.map(\.uuidString))
        guard reminders.allSatisfy({ $0.revision > 0 }),
              clocks.allSatisfy({ keys.contains($0.key) && $0.value.isValid }),
              Set(actions.map { $0.occurrence.id }).count == actions.count,
              actions.allSatisfy({ action in
                  let event = action.occurrence
                  guard ids.contains(event.reminderID), !event.id.isEmpty else { return false }
                  if event.state == .acknowledged { return action.snooze == nil }
                  guard event.state == .snoozed, let next = action.snooze else { return false }
                  return next.isSnooze && next.state == .planned && next.id != event.id &&
                      next.reminderID == event.reminderID && next.reminderRevision == event.reminderRevision
              }) else { throw ControlError("invalid_sync_state", "服务端提醒或处理记录格式无效。") }
        return SyncState(reminders: reminders.sorted { $0.id.uuidString < $1.id.uuidString },
                         actions: actions.sorted { $0.occurrence.id < $1.occurrence.id },
                         clocks: clocks.filter { !$0.value.edits.isEmpty })
    }

    /// Join two replicas: per-field Lamport registers, monotonic cancellation,
    /// and a deterministic terminal action for each occurrence.
    func merging(_ other: Self) throws -> Self {
        var items = Dictionary(uniqueKeysWithValues: reminders.map { ($0.id, $0) })
        for item in other.reminders {
            let key = item.id.uuidString
            if let left = items[item.id] {
                items[item.id] = try left.merging(item, clock: clocks[key] ?? ReminderClock(),
                                                  otherClock: other.clocks[key] ?? ReminderClock())
            } else {
                items[item.id] = item
            }
        }
        let versions = clocks.merging(other.clocks) { $0.merging($1) }
        var handled = Dictionary(uniqueKeysWithValues: actions.map { ($0.occurrence.id, $0) })
        for action in other.actions {
            let id = action.occurrence.id
            handled[id] = try handled[id]?.merging(action) ?? action
        }
        var normalized: [Reminder] = []
        for var item in items.values {
            item.revision = try versions[item.id.uuidString]?.generation(legacy: item.revision) ?? item.revision
            normalized.append(item)
        }
        return try SyncState(reminders: normalized, actions: Array(handled.values), clocks: versions).validated()
    }
}

extension ReminderStore {
    func occurrence(_ id: String) throws -> Occurrence? {
        try rows("SELECT payload FROM occurrences WHERE id=?", [id]).first.map {
            try JSONDecoder.meno.decode(Occurrence.self, from: Data($0[0].utf8))
        }
    }

    func save(_ action: SyncAction) throws {
        let payload = String(decoding: try JSONEncoder.meno.encode(action), as: UTF8.self)
        try execute("INSERT INTO sync_actions VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload",
                    [action.occurrence.id, payload])
    }

    func syncState() throws -> SyncState {
        let actions = try rows("SELECT payload FROM sync_actions ORDER BY id").map {
            try JSONDecoder.meno.decode(SyncAction.self, from: Data($0[0].utf8))
        }
        let clocks = try rows("SELECT id, payload FROM sync_clocks").map { row in
            (row[0], try JSONDecoder.meno.decode(ReminderClock.self, from: Data(row[1].utf8)))
        }
        return try SyncState(reminders: reminders(), actions: actions, clocks: Dictionary(uniqueKeysWithValues: clocks)).validated()
    }
}

extension ReminderService {
    static let remoteChangeDetail = "提醒已从其他设备修改、暂停或取消"
    static let syncServerKey = "sync_server_v1"

    /// Rejoin with edits made during the network round trip so they remain
    /// visible locally and are included in the next upload.
    func applySyncedState(_ synced: SyncState, serverID: UUID) throws -> Bool {
        let current = try store.syncState()
        let joined = try current.merging(synced)
        let currentItems = Dictionary(uniqueKeysWithValues: current.reminders.map { ($0.id, $0) })
        let currentActions = Dictionary(uniqueKeysWithValues: current.actions.map { ($0.occurrence.id, $0) })
        let changedItems = joined.reminders.filter { currentItems[$0.id] != $0 }
        let changedActions = joined.actions.filter { currentActions[$0.occurrence.id] != $0 }
        let changedClocks = joined.clocks.filter { current.clocks[$0.key] != $0.value }
        if joined == current, try store.metadata(Self.syncServerKey) == serverID.uuidString { return false }

        try store.transaction {
            for (key, clock) in changedClocks {
                guard let id = UUID(uuidString: key) else { throw ReminderError.invalidData }
                try store.saveClock(clock, for: id)
            }
            try store.observeClock(joined.maxCounter)
            for reminder in changedItems {
                try store.save(reminder)
                for row in try store.rows("SELECT payload FROM occurrences WHERE reminder_id=?", [reminder.id.uuidString]) {
                    var item = try JSONDecoder.meno.decode(Occurrence.self, from: Data(row[0].utf8))
                    guard item.state.isPending else { continue }
                    if item.reminderRevision == reminder.revision && reminder.isEnabled && !reminder.isCancelled { continue }
                    item.state = .cancelled
                    item.detail = Self.remoteChangeDetail
                    item.updatedAt = now()
                    try store.save(item)
                }
            }
            let byID = Dictionary(uniqueKeysWithValues: joined.reminders.map { ($0.id, $0) })
            for action in changedActions {
                let id = action.occurrence.id
                if let oldID = currentActions[id]?.snooze?.id, oldID != action.snooze?.id,
                   var old = try store.occurrence(oldID), old.state.isPending {
                    old.state = .cancelled
                    old.detail = "另一设备已处理这次提醒"
                    old.updatedAt = now()
                    try store.save(old)
                }
                try store.save(action.occurrence)
                if let next = action.snooze, let reminder = byID[next.reminderID],
                   reminder.isEnabled, !reminder.isCancelled, reminder.revision == next.reminderRevision,
                   next.scheduledAt > now(), try store.occurrence(next.id) == nil {
                    try store.save(next)
                }
                try store.save(action)
            }
            try store.setMetadata(Self.syncServerKey, serverID.uuidString)
        }
        let changed = !changedItems.isEmpty || !changedActions.isEmpty
        if changed { self.changed() }
        return changed
    }
}
