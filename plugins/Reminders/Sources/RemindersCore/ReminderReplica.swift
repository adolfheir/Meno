import CryptoKit
import Foundation
import MenoControlProtocol

struct EditStamp: Codable, Comparable {
    let counter: Int
    let replica: UUID

    static func < (a: Self, b: Self) -> Bool {
        a.counter == b.counter ? a.replica.uuidString < b.replica.uuidString : a.counter < b.counter
    }
}

struct ReminderClock: Codable, Equatable {
    enum Field: String, CaseIterable {
        case title, note, schedule, delivery, availability, cancelled
    }

    private(set) var edits: [String: EditStamp] = [:]

    var maxCounter: Int { edits.values.map(\.counter).max() ?? 0 }
    var isValid: Bool {
        edits.allSatisfy { Field(rawValue: $0.key) != nil && (1...9_007_199_254_740_990).contains($0.value.counter) }
    }

    func merging(_ other: Self) -> Self {
        ReminderClock(edits: edits.merging(other.edits, uniquingKeysWith: max))
    }

    mutating func record(_ changed: [Field], stamp: EditStamp) {
        for field in changed { edits[field.rawValue] = stamp }
    }

    func isNewer(_ other: Self, field: Field) -> Bool? {
        switch (edits[field.rawValue], other.edits[field.rawValue]) {
        case let (a?, b?) where a != b: return a > b
        case (_?, nil): return true
        case (nil, _?): return false
        default: return nil
        }
    }

    /// Use the complete causal version as the occurrence generation. Keep it
    /// within exact JSON integer precision so both schedulers derive the same IDs.
    func generation(legacy: Int) throws -> Int {
        guard !edits.isEmpty else { return legacy }
        let bytes = try JSONEncoder.meno.encode(self)
        return max(1, SHA256.hash(data: bytes).prefix(6).reduce(0) { ($0 << 8) | Int($1) })
    }
}

private struct Availability: Codable, Equatable {
    let enabled: Bool
    let pauseUntil: Date?
    init(_ reminder: Reminder) {
        enabled = reminder.isEnabled
        pauseUntil = reminder.pauseUntil
    }
}

extension Reminder {
    func editedFields(since previous: Reminder?) -> [ReminderClock.Field] {
        guard let previous else { return ReminderClock.Field.allCases }
        return ReminderClock.Field.allCases.filter { field in
            switch field {
            case .title: title != previous.title
            case .note: note != previous.note
            case .schedule: schedule != previous.schedule
            case .delivery: reminderType != previous.reminderType
            case .availability: Availability(self) != Availability(previous)
            case .cancelled: isCancelled != previous.isCancelled
            }
        }
    }

    func merging(_ other: Reminder, clock: ReminderClock, otherClock: ReminderClock) throws -> Reminder {
        func winner<Value: Encodable & Equatable>(_ field: ReminderClock.Field, _ a: Value, _ b: Value) throws -> Value {
            if a == b { return a }
            if let local = clock.isNewer(otherClock, field: field) { return local ? a : b }
            // Same stamp with different content is possible when importing an
            // older copy of a database. Resolve that tie consistently as well.
            let aBytes = try JSONEncoder.meno.encode(a)
            let bBytes = try JSONEncoder.meno.encode(b)
            return aBytes.lexicographicallyPrecedes(bBytes) ? b : a
        }
        var merged = self
        merged.title = try winner(.title, title, other.title)
        merged.note = try winner(.note, note, other.note)
        merged.schedule = try winner(.schedule, schedule, other.schedule)
        merged.reminderType = try winner(.delivery, reminderType, other.reminderType)
        let status = try winner(.availability, Availability(self), Availability(other))
        merged.isCancelled = isCancelled || other.isCancelled
        merged.isEnabled = status.enabled && !merged.isCancelled
        merged.pauseUntil = merged.isCancelled ? nil : status.pauseUntil
        if (other.createdAt, other.source) < (createdAt, source) {
            merged.createdAt = other.createdAt
            merged.source = other.source
        }
        merged.updatedAt = max(updatedAt, other.updatedAt)
        merged.revision = try clock.merging(otherClock).generation(legacy: max(revision, other.revision))
        return merged
    }
}

extension ReminderStore {
    func clock(_ id: UUID) throws -> ReminderClock {
        guard let value = try rows("SELECT payload FROM sync_clocks WHERE id=?", [id.uuidString]).first else {
            return ReminderClock()
        }
        return try JSONDecoder.meno.decode(ReminderClock.self, from: Data(value[0].utf8))
    }

    func saveClock(_ clock: ReminderClock, for id: UUID) throws {
        let payload = String(decoding: try JSONEncoder.meno.encode(clock), as: UTF8.self)
        try execute("INSERT INTO sync_clocks VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload",
                    [id.uuidString, payload])
    }

    func observeClock(_ counter: Int) throws {
        let current = Int(try metadata("sync_clock") ?? "") ?? 0
        if counter > current { try setMetadata("sync_clock", String(counter)) }
    }

    func recordEdit(_ fields: [ReminderClock.Field], for id: UUID) throws -> ReminderClock {
        var clock = try self.clock(id)
        guard !fields.isEmpty else { return clock }
        let current = Int(try metadata("sync_clock") ?? "") ?? 0
        let counter = max(current, clock.maxCounter) + 1
        let replica: UUID
        if let raw = try metadata("sync_replica"), let existing = UUID(uuidString: raw) {
            replica = existing
        } else {
            replica = UUID()
            try setMetadata("sync_replica", replica.uuidString)
        }
        clock.record(fields, stamp: EditStamp(counter: counter, replica: replica))
        try observeClock(counter)
        try saveClock(clock, for: id)
        return clock
    }
}
