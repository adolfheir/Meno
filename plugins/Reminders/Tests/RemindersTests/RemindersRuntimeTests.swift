import AppKit
import MenoControlProtocol
import MenoPluginKit
import RemindersCore
import XCTest

@testable import RemindersPlugin

@MainActor private final class RecordingPresenter: ReminderPresenting {
  var onAction: ((String, Bool) -> Void)?
  var queue: [Occurrence] = []
  var count: Int { queue.isEmpty ? 0 : 1 }
  var contentScreenID: UInt32? { nil }
  func show(_ queue: [Occurrence]) { self.queue = queue }
  func close() { queue = [] }
  func focus(screenID: UInt32?) -> Bool { !queue.isEmpty }
}

final class RemindersRuntimeTests: XCTestCase {
  private var directory: URL!
  override func setUp() {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "meno-runtime-" + UUID().uuidString)
  }
  override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

  @MainActor private func model(_ client: FakeNotificationClient) throws -> RemindersModel {
    try RemindersModel(context: PluginContext(dataDirectory: directory), notificationClient: client)
  }
  @MainActor private func create(_ model: RemindersModel, type: String = "fullscreen") throws
    -> String
  {
    let result = try model.service.write(
      "reminders_create",
      arguments: [
        "title": .string("运行时验证"), "reminderType": .string(type),
        "schedule": .object(["kind": .string("delay"), "afterSeconds": .number(3600)]),
        "requestId": .string(UUID().uuidString),
      ], source: "ui")
    return result.original["id"].string!
  }

  @MainActor func testDueQueueAcknowledgementAndSnoozeUseSeparateChannels() async throws {
    let client = FakeNotificationClient()
    let presenter = RecordingPresenter()
    let m = try model(client)
    var now = Date()
    m.service.now = { now }
    _ = try create(m)
    _ = try create(m)
    _ = try create(m, type: "system")
    let runtime = RemindersRuntime(model: m, presenter: presenter, isScreenLocked: { false })
    try await runtime.start()
    XCTAssertEqual(client.requests.count, 1)
    XCTAssertTrue(presenter.queue.isEmpty)
    now = now.addingTimeInterval(3601)
    await runtime.reconcile()
    XCTAssertEqual(presenter.queue.count, 2)
    XCTAssertTrue(presenter.queue.allSatisfy { $0.reminderType == .fullscreen })
    let first = presenter.queue[0].id
    try await m.handleOccurrence(first, snooze: false)
    XCTAssertEqual(presenter.queue.count, 1)
    try await m.handleOccurrence(presenter.queue[0].id, snooze: true)
    XCTAssertTrue(presenter.queue.isEmpty)
    let snoozed = try XCTUnwrap(m.service.history().first { $0.isSnooze })
    XCTAssertEqual(snoozed.scheduledAt.timeIntervalSince(now), 300, accuracy: 0.001)
    now = now.addingTimeInterval(301)
    await runtime.reconcile()
    XCTAssertEqual(presenter.queue.map(\.id), [snoozed.id])
    await runtime.stop()
    XCTAssertTrue(presenter.queue.isEmpty)
    XCTAssertTrue(client.requests.isEmpty)
    XCTAssertFalse(m.isRunning)
    XCTAssertNil(m.runtime)
  }

  @MainActor func testLockedSessionDefersFullscreenAndExpiredRecoveryIsMissed() async throws {
    let client = FakeNotificationClient()
    let presenter = RecordingPresenter()
    let m = try model(client)
    var now = Date()
    m.service.now = { now }
    _ = try create(m)
    let runtime = RemindersRuntime(model: m, presenter: presenter, isScreenLocked: { true })
    try await runtime.start()
    now = now.addingTimeInterval(3601)
    await runtime.reconcile()
    XCTAssertTrue(runtime.presentationSuspended)
    XCTAssertTrue(presenter.queue.isEmpty)
    XCTAssertEqual(try m.service.history().first?.state, .planned)
    now = now.addingTimeInterval(1801)
    await runtime.reconcile()
    XCTAssertEqual(try m.service.history().first?.state, .missed)
    await runtime.stop()
  }

  @MainActor func testStopDuringNotificationWritePreventsLateOverlayAndCleansQueue() async throws {
    let client = FakeNotificationClient()
    let presenter = RecordingPresenter()
    let m = try model(client)
    _ = try create(m, type: "system")
    let runtime = RemindersRuntime(model: m, presenter: presenter, isScreenLocked: { false })
    var continuation: CheckedContinuation<Void, Never>?
    client.onAdd = { await withCheckedContinuation { continuation = $0 } }
    let starting = Task { try await runtime.start() }
    while continuation == nil { await Task.yield() }
    let stopping = Task { await runtime.stop() }
    await Task.yield()
    continuation?.resume()
    try await starting.value
    await stopping.value
    XCTAssertFalse(runtime.active)
    XCTAssertFalse(m.isRunning)
    XCTAssertTrue(client.requests.isEmpty)
    XCTAssertTrue(presenter.queue.isEmpty)
    XCTAssertEqual(try m.service.store.metadata("runtime_active"), "false")
    await runtime.reconcile()
    XCTAssertTrue(client.requests.isEmpty)
  }

  @MainActor func testDeniedSystemReceiptAndAuthorizedRecovery() async throws {
    let client = FakeNotificationClient()
    client.status = .denied
    let m = try model(client)
    _ = try create(m, type: "system")
    let runtime = RemindersRuntime(
      model: m, presenter: RecordingPresenter(), isScreenLocked: { false })
    try await runtime.start()
    let reminder = try XCTUnwrap(m.service.reminders().first)
    XCTAssertEqual(try m.receipt(reminder)["armed"], .bool(false))
    XCTAssertTrue(try XCTUnwrap(m.receipt(reminder)["blockedReason"].string).contains("未授权"))
    client.status = .authorized
    await runtime.reconcile()
    XCTAssertEqual(try m.receipt(reminder)["armed"], .bool(true))
    await runtime.stop()
    XCTAssertEqual(try m.receipt(reminder)["armed"], .bool(false))
  }

  @MainActor func testStorageFailureIsVisibleAndDoesNotClaimArmed() async throws {
    let client = FakeNotificationClient()
    let m = try model(client)
    _ = try create(m)
    let runtime = RemindersRuntime(
      model: m, presenter: RecordingPresenter(), isScreenLocked: { false })
    try await runtime.start()
    let reminder = try XCTUnwrap(m.service.reminders().first)
    try m.service.store.execute(
      "CREATE TRIGGER fail_checkpoint BEFORE UPDATE ON metadata BEGIN SELECT RAISE(ABORT, 'injected'); END"
    )
    await runtime.reconcile()
    XCTAssertNotNil(m.runtimeError)
    XCTAssertEqual(try m.receipt(reminder)["armed"], .bool(false))
    try m.service.store.execute("DROP TRIGGER fail_checkpoint")
    await runtime.reconcile()
    XCTAssertNil(m.runtimeError)
    XCTAssertEqual(try m.receipt(reminder)["armed"], .bool(true))
    await runtime.stop()
  }

  @MainActor func testWeeklySystemQueueAdvancesToSecondTimeAndThenNextDay() async throws {
    let client = FakeNotificationClient()
    let m = try model(client)
    var now = TimeText.parse("2026-10-23T09:00:00+08:00")!
    m.service.now = { now }
    _ = try m.service.write("reminders_create", arguments: [
      "title": .string("周末"), "reminderType": .string("system"), "requestId": .string("weekly"),
      "schedule": .object(["kind": .string("weekly"), "weekdays": .array([.number(5), .number(6), .number(7)]), "times": .array([.string("10:55"), .string("17:55")]), "timeZone": .string("Asia/Shanghai")]),
    ], source: "cli")
    let runtime = RemindersRuntime(model: m, presenter: RecordingPresenter(), isScreenLocked: { false })
    try await runtime.start()
    let reminder = try XCTUnwrap(m.service.reminders().first)
    XCTAssertEqual(try m.receipt(reminder)["armed"], .bool(true))
    XCTAssertEqual(try m.receipt(reminder)["nextTriggerAt"].string.flatMap(TimeText.parse), TimeText.parse("2026-10-23T10:55:00+08:00"))
    now = TimeText.parse("2026-10-23T10:56:00+08:00")!
    await runtime.reconcile()
    XCTAssertEqual(client.requests.count, 1)
    XCTAssertEqual(try m.receipt(reminder)["nextTriggerAt"].string.flatMap(TimeText.parse), TimeText.parse("2026-10-23T17:55:00+08:00"))
    now = TimeText.parse("2026-10-23T17:56:00+08:00")!
    await runtime.reconcile()
    XCTAssertEqual(client.requests.count, 1)
    XCTAssertEqual(try m.receipt(reminder)["nextTriggerAt"].string.flatMap(TimeText.parse), TimeText.parse("2026-10-24T10:55:00+08:00"))
    XCTAssertEqual(try m.receipt(reminder)["armed"], .bool(true))
    await runtime.stop()
    XCTAssertTrue(client.requests.isEmpty)
  }
}
