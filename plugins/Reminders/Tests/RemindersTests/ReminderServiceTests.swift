import Foundation
import MenoControlProtocol
import RemindersCore
import XCTest

final class ReminderServiceTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws { directory = FileManager.default.temporaryDirectory.appendingPathComponent("meno-test-" + UUID().uuidString) }
    override func tearDownWithError() throws { if let directory { try? FileManager.default.removeItem(at: directory) } }
    private let instant = TimeText.parse("2026-10-23T12:00:00+08:00")!
    private func args(id: String = "create-1", type: String = "fullscreen") -> [String: JSONValue] {
        ["title": .string("喝水"), "schedule": .object(["kind": .string("delay"), "afterSeconds": .number(1200)]), "reminderType": .string(type), "requestId": .string(id)]
    }
    @MainActor func testIdempotentRetryKeepsOriginalAbsoluteTimeAfterRestart() throws {
        var now = instant
        let first = try ReminderService(directory: directory, now: { now })
        let result = try first.write("reminders_create", arguments: args(), source: "mcp")
        now = now.addingTimeInterval(4000)
        let restarted = try ReminderService(directory: directory, now: { now })
        let retry = try restarted.write("reminders_create", arguments: args(), source: "mcp")
        XCTAssertTrue(retry.replayed); XCTAssertEqual(retry.original, result.original)
        let reminders = try restarted.reminders(); XCTAssertEqual(reminders.count, 1)
        XCTAssertEqual(reminders[0].schedule.date, instant.addingTimeInterval(1200)); XCTAssertEqual(reminders[0].source, "mcp")
    }
    @MainActor func testDifferentPayloadWithSameRequestIDConflicts() throws {
        let service = try ReminderService(directory: directory, now: { self.instant })
        _ = try service.write("reminders_create", arguments: args(), source: "mcp")
        var changed = args(); changed["title"] = .string("开会")
        XCTAssertThrowsError(try service.write("reminders_create", arguments: changed, source: "mcp")) { XCTAssertEqual(($0 as? ControlError)?.code, "idempotency_conflict") }
        XCTAssertEqual(try service.reminders().count, 1)
    }
    @MainActor func testDisabledCreateDoesNotEnableAndExplicitEnableIsAtomicWithRequest() throws {
        let s = try ReminderService(directory: directory, now: { self.instant })
        _ = try s.write("reminders_create", arguments: args(), source: "cli"); XCTAssertFalse(try s.enabledPreference())
        var a = args(id: "explicit"); a["enablePlugin"] = .bool(true)
        let result = try s.write("reminders_create", arguments: a, source: "cli")
        XCTAssertTrue(result.enableRequested); XCTAssertTrue(try s.enabledPreference())
        _ = try s.write("apps_set_enabled", arguments: ["enabled": .bool(false), "requestId": .string("stop")], source: "cli")
        let retry = try s.write("reminders_create", arguments: a, source: "mcp")
        XCTAssertTrue(retry.replayed); XCTAssertFalse(retry.enableRequested); XCTAssertFalse(try s.enabledPreference())
    }
    @MainActor func testRequestRecordFailureRollsBackReminderAndPreference() throws {
        let s = try ReminderService(directory: directory, now: { self.instant })
        try s.store.execute("CREATE TRIGGER fail_requests BEFORE INSERT ON requests BEGIN SELECT RAISE(ABORT, 'injected failure'); END")
        var a = args(); a["enablePlugin"] = .bool(true)
        XCTAssertThrowsError(try s.write("reminders_create", arguments: a, source: "mcp"))
        XCTAssertTrue(try s.reminders().isEmpty); XCTAssertFalse(try s.enabledPreference())
        try s.store.execute("DROP TRIGGER fail_requests")
        XCTAssertFalse(try s.write("reminders_create", arguments: a, source: "mcp").replayed)
        XCTAssertEqual(try s.reminders().count, 1)
    }
    @MainActor func testValidationRejectsConflictingInvalidAndPastSchedules() throws {
        let s = try ReminderService(directory: directory, now: { self.instant })
        let invalid: [JSONValue] = [
            .object(["kind": .string("delay"), "afterSeconds": .number(10), "at": .string("2028-01-01T00:00:00Z")]),
            .object(["kind": .string("delay"), "afterSeconds": .number(0)]),
            .object(["kind": .string("delay"), "afterSeconds": .bool(true)]),
            .object(["kind": .string("once"), "at": .string("2026-01-01T00:00:00Z")]),
            .object(["kind": .string("once"), "at": .string("2028-01-01T00:00:00")]),
            .object(["kind": .string("daily"), "time": .string("24:00")]),
        ]
        for schedule in invalid { var a = args(); a["schedule"] = schedule; XCTAssertThrowsError(try s.write("reminders_create", arguments: a, source: "mcp")) }
        var a = args(); a["reminderType"] = .string("both"); XCTAssertThrowsError(try s.write("reminders_create", arguments: a, source: "mcp"))
        a = args(); a["title"] = .string("   "); XCTAssertThrowsError(try s.write("reminders_create", arguments: a, source: "mcp"))
        XCTAssertTrue(try s.reminders().isEmpty)
    }
    @MainActor func testPartialUpdatePreservesUnspecifiedFieldsAndCancelsOldOccurrence() throws {
        let s = try ReminderService(directory: directory, now: { self.instant })
        let created = try s.write("reminders_create", arguments: args(), source: "ui"); try s.preparePlans(catchUp: false)
        let id = created.original["id"]
        _ = try s.write("reminders_update", arguments: ["id": id, "note": .string("新备注"), "reminderType": .string("system"), "requestId": .string("edit")], source: "mcp")
        let reminder = try s.reminders()[0]
        XCTAssertEqual(reminder.title, "喝水"); XCTAssertEqual(reminder.schedule.date, instant.addingTimeInterval(1200)); XCTAssertEqual(reminder.reminderType, .system)
        XCTAssertEqual(try s.history()[0].state, .cancelled)
        try s.preparePlans(catchUp: false); XCTAssertEqual(try s.history().filter { $0.state == .planned }.count, 1)
        _ = try s.write("reminders_cancel", arguments: ["id": id, "requestId": .string("cancel")], source: "cli")
        XCTAssertTrue(try s.reminders()[0].isCancelled); XCTAssertTrue(try s.history().allSatisfy { $0.state == .cancelled })
    }
    @MainActor func testSnoozeCreatesIndependentInstanceWithoutMovingRecurrence() throws {
        let s = try ReminderService(directory: directory, now: { self.instant })
        var a = args(); a["schedule"] = .object(["kind": .string("daily"), "time": .string("15:30")])
        _ = try s.write("reminders_create", arguments: a, source: "ui"); try s.preparePlans(catchUp: false)
        let before = try s.reminders()[0].schedule; let item = try s.history()[0]
        try s.setState(item.id, .presenting); try s.handleOccurrence(item.id, snooze: true)
        XCTAssertEqual(try s.reminders()[0].schedule, before)
        let snooze = try XCTUnwrap(s.history().first { $0.isSnooze }); XCTAssertEqual(snooze.scheduledAt, instant.addingTimeInterval(300))
        XCTAssertEqual(try s.history().first { $0.id == item.id }?.state, .snoozed)
        XCTAssertThrowsError(try s.handleOccurrence(item.id, snooze: true)); XCTAssertEqual(try s.history().filter { $0.isSnooze }.count, 1)
    }
    @MainActor func testIntentionalPauseSkipsMissedItemButCrashRecoveryKeepsRecentOne() throws {
        var now = instant
        let s = try ReminderService(directory: directory, now: { now })
        _ = try s.write("reminders_create", arguments: args(), source: "ui")
        now = instant.addingTimeInterval(1300); try s.preparePlans(catchUp: false)
        XCTAssertEqual(try s.history()[0].state, .missed)
        var a = args(id: "recover"); a["schedule"] = .object(["kind": .string("delay"), "afterSeconds": .number(1)])
        _ = try s.write("reminders_create", arguments: a, source: "ui"); now = now.addingTimeInterval(5)
        try s.preparePlans(catchUp: true)
        XCTAssertEqual(try s.history().filter { $0.state == .planned }.count, 1)
        try s.preparePlans(catchUp: true); XCTAssertEqual(try s.history().count, 2)
    }
    @MainActor func testPreviouslyPlannedItemExpiringDuringPauseIsNeverCaughtUp() throws {
        var now = instant
        let s = try ReminderService(directory: directory, now: { now })
        _ = try s.write("reminders_create", arguments: args(), source: "ui")
        try s.preparePlans(catchUp: false)
        try s.runtimeStopped()
        now = now.addingTimeInterval(1300)
        try s.preparePlans(catchUp: false); try s.preparePlans(catchUp: true)
        XCTAssertEqual(try s.history().count, 1); XCTAssertEqual(try s.history()[0].state, .missed)
    }
    @MainActor func testTimeZoneChangeReplacesRegularPlanAndCanReturnToOriginalZone() throws {
        let s = try ReminderService(directory: directory, now: { self.instant })
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        s.calendar = { calendar }
        var a = args(); a["schedule"] = .object(["kind": .string("daily"), "time": .string("15:30")])
        _ = try s.write("reminders_create", arguments: a, source: "ui"); try s.preparePlans(catchUp: false)
        let first = try XCTUnwrap(s.history().first { $0.state == .planned })
        calendar.timeZone = TimeZone(identifier: "Europe/London")!; try s.preparePlans(catchUp: true)
        XCTAssertEqual(try s.history().first { $0.id == first.id }?.state, .cancelled)
        XCTAssertEqual(try s.history().filter { $0.state == .planned }.count, 1)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!; try s.preparePlans(catchUp: true)
        XCTAssertEqual(try s.history().filter { $0.state == .planned }.map(\.id), [first.id])
    }
    @MainActor func testAppEnableReplayReportsOriginalIntentWithoutChangingNewerPreference() throws {
        let s = try ReminderService(directory: directory)
        let on: [String: JSONValue] = ["enabled": .bool(true), "requestId": .string("on")]
        _ = try s.write("apps_set_enabled", arguments: on, source: "mcp")
        _ = try s.write("apps_set_enabled", arguments: ["enabled": .bool(false), "requestId": .string("off")], source: "mcp")
        let retry = try s.write("apps_set_enabled", arguments: on, source: "mcp")
        XCTAssertTrue(retry.replayed); XCTAssertEqual(retry.original["requestedEnabled"].bool, true); XCTAssertFalse(try s.enabledPreference())
    }
    @MainActor func testLegacyMigrationBacksUpAndPreservesIDsAndIsRepeatable() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let reminder = Reminder(title: "旧事项", schedule: ReminderSchedule(rule: .daily, date: instant))
        var legacy = try JSONValue.encode(reminder).object!
        for key in ["reminderType", "isCancelled", "source", "createdAt", "updatedAt", "revision"] { legacy[key] = nil }
        let data = try JSONEncoder.meno.encode(JSONValue.object(["schemaVersion": .number(1), "reminders": .array([.object(legacy)])]))
        let path = directory.appendingPathComponent("reminders.json"); try data.write(to: path)
        let s = try ReminderService(directory: directory); XCTAssertEqual(try s.reminders()[0].id, reminder.id)
        XCTAssertEqual(try s.reminders()[0].reminderType, .system); XCTAssertEqual(try s.reminders()[0].source, "legacy")
        XCTAssertEqual(try Data(contentsOf: path.appendingPathExtension("pre-sqlite.bak")), data)
        let another = try ReminderService(directory: directory); XCTAssertEqual(try another.reminders().count, 1)
        XCTAssertEqual(try Data(contentsOf: path), data)
    }
    @MainActor func testCorruptLegacyAndUnknownSQLiteVersionAreNeverReplaced() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("reminders.json"), bytes = Data("invalid".utf8); try bytes.write(to: path)
        XCTAssertThrowsError(try ReminderService(directory: directory)); XCTAssertEqual(try Data(contentsOf: path), bytes)
        try FileManager.default.removeItem(at: path)
        let store = try ReminderStore(directory: directory); try store.execute("PRAGMA user_version=99")
        XCTAssertThrowsError(try ReminderService(directory: directory))
        XCTAssertEqual(try store.rows("PRAGMA user_version").first?.first, "99")
    }

    @MainActor func testWeeklySchedulePersistsRetryAndPartialEditWithoutMovingAnchor() throws {
        var now = instant
        let s = try ReminderService(directory: directory, now: { now })
        var a = args()
        a["schedule"] = .object(["kind": .string("weekly"), "weekdays": .array([.number(5), .number(6), .number(7)]), "times": .array([.string("10:55"), .string("17:55")]), "timeZone": .string("Asia/Shanghai"), "every": .number(2)])
        let result = try s.write("reminders_create", arguments: a, source: "cli")
        try s.preparePlans(catchUp: false)
        let saved = try s.reminders()[0].schedule
        XCTAssertEqual(try s.history()[0].scheduledAt, TimeText.parse("2026-10-23T17:55:00+08:00"))
        now = now.addingTimeInterval(86400)
        let restarted = try ReminderService(directory: directory, now: { now })
        XCTAssertTrue(try restarted.write("reminders_create", arguments: a, source: "mcp").replayed)
        _ = try restarted.write("reminders_update", arguments: ["id": result.original["id"], "note": .string("只改备注"), "requestId": .string("note")], source: "cli")
        XCTAssertEqual(try restarted.reminders()[0].schedule, saved)
        XCTAssertEqual(try restarted.reminders().count, 1)
    }

    @MainActor func testIntervalRecoveryIncludesEachRecentTickOnceAndPauseSkipsTicks() throws {
        var now = instant
        let s = try ReminderService(directory: directory, now: { now })
        var a = args()
        a["schedule"] = .object(["kind": .string("interval"), "everySeconds": .number(60)])
        _ = try s.write("reminders_create", arguments: a, source: "cli")
        try s.preparePlans(catchUp: false)
        now = instant.addingTimeInterval(181)
        try s.preparePlans(catchUp: true)
        XCTAssertEqual(try s.history().filter { $0.state == .planned }.map(\.scheduledAt).sorted(), [60, 120, 180, 240].map { instant.addingTimeInterval(Double($0)) })
        try s.preparePlans(catchUp: true)
        XCTAssertEqual(try s.history().count, 4)
        try s.runtimeStopped()
        now = instant.addingTimeInterval(361)
        try s.preparePlans(catchUp: false)
        try s.preparePlans(catchUp: true)
        XCTAssertEqual(try s.history().filter { $0.state == .planned }.map(\.scheduledAt), [instant.addingTimeInterval(420)])
    }

    @MainActor func testRejectedScheduleDoesNotPersistOrConsumeRequestID() throws {
        let s = try ReminderService(directory: directory, now: { self.instant })
        var a = args()
        a["schedule"] = .object(["kind": .string("weekly"), "weekdays": .array([]), "time": .string("09:00")])
        XCTAssertThrowsError(try s.write("reminders_create", arguments: a, source: "cli"))
        XCTAssertTrue(try s.reminders().isEmpty)
        a["schedule"] = .object(["kind": .string("weekly"), "weekdays": .array([.number(5)]), "time": .string("09:00")])
        XCTAssertFalse(try s.write("reminders_create", arguments: a, source: "cli").replayed)
    }
    @MainActor func testTimedPausePersistsSkipsTriggersAndCanResume() throws {
        var now = instant
        let s = try ReminderService(directory: directory, now: { now })
        var a = args(); a["schedule"] = .object(["kind": .string("interval"), "everySeconds": .number(3600)])
        let result = try s.write("reminders_create", arguments: a, source: "ui")
        let id = result.original["id"]
        try s.preparePlans(catchUp: false)
        let until = instant.addingTimeInterval(86400)
        _ = try s.write("reminders_update", arguments: ["id": id, "pauseUntil": .string(TimeText.format(until)), "requestId": .string("pause")], source: "ui")
        try s.preparePlans(catchUp: true)
        XCTAssertEqual(try s.history().filter { $0.state == .planned }.map(\.scheduledAt), [until])
        let restarted = try ReminderService(directory: directory, now: { now })
        XCTAssertEqual(try restarted.reminders()[0].pauseUntil, until)
        now = until.addingTimeInterval(10)
        try restarted.preparePlans(catchUp: true)
        XCTAssertFalse(try restarted.history().contains { $0.state == .planned && $0.scheduledAt < until })
        XCTAssertTrue(try restarted.history().contains { $0.state == .planned && $0.scheduledAt == until })
        _ = try restarted.write("reminders_update", arguments: ["id": id, "pauseUntil": .string(""), "requestId": .string("resume")], source: "ui")
        XCTAssertNil(try restarted.reminders()[0].pauseUntil)
    }

}
