import RemindersCore
@testable import RemindersPlugin
import UserNotifications
import XCTest

@MainActor final class FakeNotificationClient: NotificationClient {
    var status: UNAuthorizationStatus = .authorized
    var requests: [String: UNNotificationRequest] = [:]
    var delivered: Set<String> = []
    var added: [String] = []
    var failure: Error?
    var onAdd: (() async -> Void)?
    func authorizationStatus() async -> UNAuthorizationStatus { status }
    func requestAuthorization() async throws -> Bool { status = .authorized; return true }
    func pendingRequests() async -> [UNNotificationRequest] { Array(requests.values) }
    func deliveredIDs() async -> Set<String> { delivered }
    func add(_ request: UNNotificationRequest) async throws {
        if let onAdd { await onAdd() }; if let failure { throw failure }
        requests[request.identifier] = request; added.append(request.identifier)
    }
    func remove(_ identifiers: [String]) { identifiers.forEach { requests[$0] = nil } }
    func removeDelivered(_ identifiers: [String]) { delivered.subtract(identifiers) }
}
final class NotificationSchedulerTests: XCTestCase {
    private func item(type: ReminderType = .system, at: Date = .now.addingTimeInterval(3600)) -> Occurrence {
        let r = Reminder(title: "Test", schedule: ReminderSchedule(rule: .once, date: at), reminderType: type)
        return Occurrence(reminder: r, at: at)
    }
    @MainActor func testOnlySelectedTypeIsSubmittedAndStopDoesNotTouchOtherModules() async {
        let client = FakeNotificationClient(); client.requests["other"] = UNNotificationRequest(identifier: "other", content: UNMutableNotificationContent(), trigger: nil)
        let scheduler = NotificationScheduler(client: client)
        await scheduler.sync([item(), item(type: .fullscreen)], active: true)
        XCTAssertEqual(client.requests.count, 2); XCTAssertEqual(scheduler.armedIDs.count, 1)
        await scheduler.sync([], active: false); XCTAssertEqual(Set(client.requests.keys), ["other"])
    }
    @MainActor func testStopWaitsForSuspendedSystemWriteThenRemovesIt() async {
        let client = FakeNotificationClient(); let scheduler = NotificationScheduler(client: client)
        var continuation: CheckedContinuation<Void, Never>?
        client.onAdd = { await withCheckedContinuation { continuation = $0 } }
        let task = Task { await scheduler.sync([item()], active: true) }
        while continuation == nil { await Task.yield() }
        let stopping = Task { await scheduler.sync([], active: false) }; await Task.yield()
        continuation?.resume(); await task.value; await stopping.value
        XCTAssertTrue(client.requests.isEmpty); XCTAssertTrue(scheduler.armedIDs.isEmpty)
    }
    @MainActor func testPermissionDenialKeepsSavedItemsOutOfSystemQueue() async {
        let client = FakeNotificationClient(); client.status = .denied
        let scheduler = NotificationScheduler(client: client); await scheduler.sync([item()], active: true)
        XCTAssertTrue(client.requests.isEmpty); XCTAssertEqual(scheduler.authorization, .denied)
    }
    @MainActor func testTypeOrTimeEditRevokesOldStableID() async {
        let client = FakeNotificationClient(); let scheduler = NotificationScheduler(client: client)
        await scheduler.sync([item()], active: true); let previous = client.requests.keys.first!
        await scheduler.sync([item(type: .fullscreen)], active: true)
        XCTAssertNil(client.requests[previous]); XCTAssertTrue(client.requests.isEmpty)
    }
    @MainActor func testReconcileDoesNotResubmitExistingOrDeliveredRequests() async {
        let client = FakeNotificationClient(); let scheduler = NotificationScheduler(client: client); let i = item()
        await scheduler.sync([i], active: true); await scheduler.sync([i], active: true); XCTAssertEqual(client.added.count, 1)
        client.requests = [:]; client.delivered = [NotificationScheduler.prefix + i.id]
        await scheduler.sync([i], active: true); XCTAssertEqual(client.added.count, 1)
    }
    @MainActor func testPastSubmittedWithoutDeliveryEvidenceIsNotResent() async {
        let client = FakeNotificationClient(); let scheduler = NotificationScheduler(client: client)
        var i = item(at: .now.addingTimeInterval(-10)); i.state = .submitted
        await scheduler.sync([i], active: true); XCTAssertTrue(client.added.isEmpty)
    }
    @MainActor func testRollingQueueKeepsNearestSixtyAndReportsCapacity() async {
        let client = FakeNotificationClient(); let scheduler = NotificationScheduler(client: client)
        let items = (0..<65).map { item(at: .now.addingTimeInterval(Double(100 + $0))) }
        await scheduler.sync(items.reversed(), active: true)
        XCTAssertEqual(client.requests.count, 60); XCTAssertEqual(scheduler.failures.count, 5)
        XCTAssertFalse(scheduler.armedIDs.contains(items.last!.id)); XCTAssertTrue(scheduler.armedIDs.contains(items.first!.id))
    }
    @MainActor func testSubmissionFailureIsReportedAndCanRecover() async {
        let client = FakeNotificationClient(); client.failure = CocoaError(.fileWriteUnknown)
        let scheduler = NotificationScheduler(client: client); let i = item()
        await scheduler.sync([i], active: true); XCTAssertNotNil(scheduler.failures[i.id]); XCTAssertTrue(scheduler.armedIDs.isEmpty)
        client.failure = nil; await scheduler.sync([i], active: true); XCTAssertTrue(scheduler.armedIDs.contains(i.id))
    }
}
