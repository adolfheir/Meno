import Foundation
import MenoControlProtocol
@testable import RemindersCore
import XCTest

final class SyncConvergenceTests: XCTestCase {
    @MainActor
    func testOfflineReplicasJoinDisjointEditsAndConvergeAfterCancellation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = try XCTUnwrap(TimeText.parse("2026-11-24T00:00:00Z"))
        let server = UUID()
        let replicas = try (1...3).map { index in
            try ReminderService(directory: root.appendingPathComponent("device-\(index)"), now: { now })
        }
        let a = replicas[0], b = replicas[1], c = replicas[2]
        let initial = try a.write("reminders_create", arguments: [
            "requestId": .string("create"), "title": .string("Original"),
            "schedule": .object(["kind": .string("delay"), "afterSeconds": .number(600)]),
        ], source: "ui")
        let id = try XCTUnwrap(initial.original["id"].string)
        let seed = try a.store.syncState()
        for device in replicas { _ = try device.applySyncedState(seed, serverID: server) }

        _ = try a.write("reminders_update", arguments: [
            "requestId": .string("title"), "id": .string(id), "title": .string("iPhone title"),
        ], source: "ui")
        _ = try b.write("reminders_update", arguments: [
            "requestId": .string("note"), "id": .string(id), "note": .string("Mac note"),
            "schedule": .object(["kind": .string("delay"), "afterSeconds": .number(1200)]),
        ], source: "ui")
        let left = try a.store.syncState(), right = try b.store.syncState()
        let joined = try left.merging(right)
        XCTAssertEqual(joined, try right.merging(left))
        XCTAssertEqual(joined, try joined.merging(joined))
        let item = try XCTUnwrap(joined.reminders.first)
        XCTAssertEqual(item.title, "iPhone title")
        XCTAssertEqual(item.note, "Mac note")
        XCTAssertEqual(item.schedule.date, now.addingTimeInterval(1200))

        _ = try c.write("reminders_cancel", arguments: ["requestId": .string("cancel"), "id": .string(id)], source: "ui")
        let deleted = try c.store.syncState()
        let final = try joined.merging(deleted)
        XCTAssertEqual(final, try deleted.merging(right).merging(left))
        XCTAssertEqual(final, try left.merging(right.merging(deleted)))
        XCTAssertTrue(try XCTUnwrap(final.reminders.first).isCancelled)
        _ = try a.applySyncedState(final, serverID: server)
        XCTAssertEqual(try a.store.syncState(), final)
    }

    @MainActor
    func testAcknowledgementWinsOverConcurrentSnooze() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let a = try ReminderService(directory: root.appendingPathComponent("a"), now: { now })
        let b = try ReminderService(directory: root.appendingPathComponent("b"), now: { now })
        let server = UUID()
        let reminder = Reminder(title: "Handled", schedule: ReminderSchedule(rule: .once, date: now), now: now)
        var occurrence = Occurrence(reminder: reminder, at: now, now: now)
        occurrence.state = .submitted
        for device in [a, b] {
            _ = try device.applySyncedState(SyncState(reminders: [reminder]), serverID: server)
            try device.store.save(occurrence)
        }
        try a.handleOccurrence(occurrence.id, snooze: true)
        try b.handleOccurrence(occurrence.id, snooze: false)
        let first = try a.store.syncState(), second = try b.store.syncState()
        let merged = try first.merging(second)
        XCTAssertEqual(merged, try second.merging(first))
        XCTAssertEqual(merged.actions.first?.occurrence.state, .acknowledged)
        _ = try a.applySyncedState(merged, serverID: server)
        XCTAssertEqual(try a.history().first { $0.isSnooze }?.state, .cancelled)
    }
}
