import CSQLite
import Foundation
import MenoControlProtocol

/// All callers execute on the host's main actor. Transactions never suspend.
public final class ReminderStore {
    private var db: OpaquePointer?
    public let url: URL
    public init(directory: URL) throws {
        try PrivateDirectory.prepare(directory)
        url = directory.appendingPathComponent("reminders.sqlite")
        if FileManager.default.fileExists(atPath: url.path) {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else { throw ControlError("storage_error", "数据库路径不是普通文件，原文件已保留。") }
        }
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let e = failure(); sqlite3_close(db); db = nil; throw e
        }
        do {
            let version = Int(try rows("PRAGMA user_version").first?.first ?? "0") ?? 0
            guard version <= 1 else { throw ControlError("unsupported_schema", "数据库版本较新，请更新 Meno；原数据已保留。") }
            guard try rows("PRAGMA quick_check").first?.first == "ok" else { throw ControlError("storage_corrupt", "SQLite 完整性检查失败，原数据已保留。") }
            try execute("PRAGMA journal_mode=WAL"); try execute("PRAGMA synchronous=FULL"); try execute("PRAGMA busy_timeout=5000")
            try transaction {
                try execute("CREATE TABLE IF NOT EXISTS reminders (id TEXT PRIMARY KEY, payload TEXT NOT NULL)")
                try execute("CREATE TABLE IF NOT EXISTS occurrences (id TEXT PRIMARY KEY, reminder_id TEXT NOT NULL, at REAL NOT NULL, payload TEXT NOT NULL)")
                try execute("CREATE INDEX IF NOT EXISTS occurrence_time ON occurrences(at)")
                try execute("CREATE TABLE IF NOT EXISTS requests (id TEXT PRIMARY KEY, fingerprint TEXT NOT NULL, result TEXT NOT NULL)")
                try execute("CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
                try execute("PRAGMA user_version=1")
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            try migrateLegacy(directory.appendingPathComponent("reminders.json"))
        } catch { sqlite3_close(db); db = nil; throw error }
    }
    deinit { sqlite3_close(db) }
    private func failure() -> ControlError { ControlError("storage_error", "提醒数据库操作失败，原数据已保留：\(db.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开数据库")") }
    private func statement(_ sql: String, _ parameters: [String]) throws -> OpaquePointer {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK, let s else { throw failure() }
        for (index, value) in parameters.enumerated() {
            let status = value.withCString { sqlite3_bind_text(s, Int32(index + 1), $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            guard status == SQLITE_OK else { sqlite3_finalize(s); throw failure() }
        }
        return s
    }
    public func execute(_ sql: String, _ parameters: [String] = []) throws {
        let s = try statement(sql, parameters); defer { sqlite3_finalize(s) }
        var result = sqlite3_step(s)
        while result == SQLITE_ROW { result = sqlite3_step(s) }
        guard result == SQLITE_DONE else { throw failure() }
    }
    public func rows(_ sql: String, _ parameters: [String] = []) throws -> [[String]] {
        let s = try statement(sql, parameters); defer { sqlite3_finalize(s) }
        var values: [[String]] = []; var status = sqlite3_step(s)
        while status == SQLITE_ROW {
            values.append((0..<sqlite3_column_count(s)).map { index in sqlite3_column_text(s, index).map { String(cString: $0) } ?? "" })
            status = sqlite3_step(s)
        }
        guard status == SQLITE_DONE else { throw failure() }; return values
    }
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do { let value = try body(); try execute("COMMIT"); return value }
        catch { try? execute("ROLLBACK"); throw error }
    }
    public func reminders() throws -> [Reminder] { try rows("SELECT payload FROM reminders ORDER BY id").map { try JSONDecoder.meno.decode(Reminder.self, from: Data($0[0].utf8)) } }
    public func occurrences() throws -> [Occurrence] { try rows("SELECT payload FROM occurrences ORDER BY at, id").map { try JSONDecoder.meno.decode(Occurrence.self, from: Data($0[0].utf8)) } }
    public func save(_ reminder: Reminder) throws {
        try execute("INSERT INTO reminders VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload", [reminder.id.uuidString, String(decoding: try JSONEncoder.meno.encode(reminder), as: UTF8.self)])
    }
    public func save(_ occurrence: Occurrence) throws {
        try execute("INSERT INTO occurrences VALUES (?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload", [occurrence.id, occurrence.reminderID.uuidString, String(occurrence.scheduledAt.timeIntervalSince1970), String(decoding: try JSONEncoder.meno.encode(occurrence), as: UTF8.self)])
    }
    public func metadata(_ key: String) throws -> String? { try rows("SELECT value FROM metadata WHERE key=?", [key]).first?.first }
    public func setMetadata(_ key: String, _ value: String) throws { try execute("INSERT INTO metadata VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [key, value]) }
    public func original(requestID: String, fingerprint: String) throws -> JSONValue? {
        guard let row = try rows("SELECT fingerprint, result FROM requests WHERE id=?", [requestID]).first else { return nil }
        guard row[0] == fingerprint else { throw ControlError("idempotency_conflict", "requestId 已用于不同参数；请为新操作使用新的 requestId。") }
        return try JSONDecoder.meno.decode(JSONValue.self, from: Data(row[1].utf8))
    }
    public func record(requestID: String, fingerprint: String, result: JSONValue) throws {
        try execute("INSERT INTO requests VALUES (?, ?, ?)", [requestID, fingerprint, result.text()])
    }
    private func migrateLegacy(_ legacy: URL) throws {
        guard FileManager.default.fileExists(atPath: legacy.path), try metadata("legacy_migrated") == nil else { return }
        let data = try Data(contentsOf: legacy)
        let book: ReminderBook
        do { book = try JSONDecoder.meno.decode(ReminderBook.self, from: data); try book.validate() }
        catch { throw ControlError("legacy_corrupt", "旧 reminders.json 读取失败，未覆盖原文件：\(error.localizedDescription)") }
        let backup = legacy.appendingPathExtension("pre-sqlite.bak")
        if !FileManager.default.fileExists(atPath: backup.path) { try data.write(to: backup, options: .withoutOverwriting) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        try transaction {
            let existing = Set(try reminders().map(\.id))
            for reminder in book.reminders where !existing.contains(reminder.id) { try save(reminder) }
            try setMetadata("legacy_migrated", TimeText.format(.now))
        }
    }
}
