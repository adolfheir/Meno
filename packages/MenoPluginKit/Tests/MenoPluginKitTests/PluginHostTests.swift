import MenoPluginKit
import SwiftUI
import XCTest

@MainActor private final class SpyRuntime: PluginRuntime {
    var starts = 0, stops = 0
    var startError: Error?
    func start() async throws { starts += 1; if let startError { throw startError } }
    func stop() async { stops += 1 }
}
@MainActor private final class SpyModule: MenoPlugin {
    var runtimes: [SpyRuntime] = []
    var startError: Error?
    func makeRuntime() throws -> any PluginRuntime { let r = SpyRuntime(); r.startError = startError; runtimes.append(r); return r }
    func makeView() -> AnyView { AnyView(EmptyView()) }
}
final class PluginHostTests: XCTestCase {
    @MainActor func testDisabledModuleCanOpenWindowWithoutCreatingRuntime() async throws {
        var constructions = 0
        let module = SpyModule()
        let host = makeHost { constructions += 1; return module }
        await host.restore(); XCTAssertEqual(constructions, 0)
        _ = try host.module(for: "one").makeView()
        _ = try host.module(for: "one").makeView()
        XCTAssertEqual(constructions, 1); XCTAssertTrue(module.runtimes.isEmpty); XCTAssertTrue(host.instances.isEmpty)
    }
    @MainActor func testStopRetainsModuleAndReenableCreatesFreshRuntime() async throws {
        let module = SpyModule(); var persisted: Set<String> = []
        let host = makeHost(persist: { persisted = $0 }) { module }
        await host.setEnabled(true, for: "one"); await host.setEnabled(false, for: "one")
        XCTAssertEqual(module.runtimes[0].stops, 1); XCTAssertEqual(host.modules.count, 1)
        XCTAssertTrue(host.instances.isEmpty); XCTAssertTrue(persisted.isEmpty)
        _ = try host.module(for: "one").makeView(); XCTAssertEqual(module.runtimes.count, 1)
        await host.setEnabled(true, for: "one"); XCTAssertEqual(module.runtimes.count, 2)
        await host.shutdown(); XCTAssertEqual(module.runtimes[1].stops, 1); XCTAssertEqual(persisted, ["one"])
    }
    @MainActor func testDisablingOneModuleCannotStopAnother() async {
        let a = SpyModule(), b = SpyModule()
        let host = PluginHost(definitions: [definition("one", a), definition("two", b)], enabledIDs: [], dataDirectory: URL(fileURLWithPath: "/unused"), persist: { _ in })
        await host.setEnabled(true, for: "one"); await host.setEnabled(true, for: "two")
        await host.setEnabled(false, for: "one")
        XCTAssertTrue(host.isRunning("two")); XCTAssertEqual(b.runtimes[0].stops, 0)
        await host.shutdown(); XCTAssertEqual(b.runtimes[0].stops, 1)
    }
    @MainActor func testFailedPersistenceStopsNewRuntime() async {
        let module = SpyModule()
        let host = makeHost(persist: { _ in throw CocoaError(.fileWriteNoPermission) }) { module }
        await host.setEnabled(true, for: "one")
        XCTAssertEqual(module.runtimes[0].stops, 1); XCTAssertFalse(host.isRunning("one")); XCTAssertNotNil(host.failures["one"])
    }
    @MainActor func testFailedStartIsCleanedUp() async {
        let module = SpyModule(); module.startError = CocoaError(.fileReadCorruptFile)
        let host = makeHost { module }; await host.setEnabled(true, for: "one")
        XCTAssertEqual(module.runtimes[0].stops, 1); XCTAssertFalse(host.isRunning("one"))
    }
    func testCorruptJSONIsNotOverwritten() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("state.json"), bytes = Data("invalid json".utf8)
        try bytes.write(to: url)
        XCTAssertThrowsError(try JSONStore<[String]>(url: url).load(default: [])); XCTAssertEqual(try Data(contentsOf: url), bytes)
    }
    @MainActor private func definition(_ id: String, _ module: SpyModule) -> PluginDefinition {
        PluginDefinition(descriptor: PluginDescriptor(id: id, name: id, summary: "", symbol: "bell", version: "1"), makePlugin: { _ in module })
    }
    @MainActor private func makeHost(persist: @escaping (Set<String>) throws -> Void = { _ in }, factory: @escaping @MainActor () -> any MenoPlugin) -> PluginHost {
        PluginHost(definitions: [PluginDefinition(descriptor: PluginDescriptor(id: "one", name: "One", summary: "", symbol: "bell", version: "1"), makePlugin: { _ in factory() })], enabledIDs: [], dataDirectory: URL(fileURLWithPath: "/unused"), persist: persist)
    }
}
