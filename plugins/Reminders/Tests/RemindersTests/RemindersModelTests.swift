import Foundation
import MenoControlProtocol
import MenoPluginKit
import RemindersCore
@testable import RemindersPlugin
import XCTest

final class RemindersModelTests: XCTestCase {
    @MainActor func testReadFailureKeepsLastLoadedItemsAndReportsError() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("meno-view-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try RemindersModel(context: PluginContext(dataDirectory: directory))
        _ = try model.service.write("reminders_create", arguments: ["title": .string("保留已载入事项"), "schedule": .object(["kind": .string("delay"), "afterSeconds": .number(3600)]), "requestId": .string("create")], source: "ui")
        XCTAssertEqual(model.reminders.count, 1)
        try model.service.store.execute("ALTER TABLE reminders RENAME TO preserved_reminders")
        model.service.changed()
        XCTAssertEqual(model.reminders.count, 1)
        XCTAssertTrue(model.error?.contains("保留上次载入") == true)
        XCTAssertEqual(try model.service.store.rows("SELECT count(*) FROM preserved_reminders")[0][0], "1")
    }
}
