import Darwin
import Foundation
import MenoControlProtocol
import XCTest

final class ControlProtocolTests: XCTestCase {
    func testISOTimeRejectsNormalizationTrailingTextAndMissingZone() {
        for text in ["2027-02-31T12:00:00Z", "2027-04-31T12:00:00+08:00", "2027-01-01T24:00:00Z", "2027-01-01T00:00:00ZgarbageZ", "2027-01-01T00:00:00", "2027-02-29T00:00:00Z"] { XCTAssertNil(TimeText.parse(text), text) }
        XCTAssertNotNil(TimeText.parse("2028-02-29T12:00:00.123456789+08:00"))
        XCTAssertNotNil(TimeText.parse("2027-01-01T00:00:00Z"))
    }
    func testJSONCanonicalEncodingAndStrictScalarTypes() throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data("{\"b\":true,\"a\":1}".utf8))
        XCTAssertEqual(value.text(), "{\"a\":1,\"b\":true}")
        XCTAssertNil(value["b"].number); XCTAssertNil(value["a"].bool)
    }
    func testToolCatalogContainsSixStructuredToolsAndExclusiveTimeBranches() throws {
        XCTAssertEqual(ToolCatalog.tools.count, 6)
        XCTAssertEqual(Set(ToolCatalog.tools.compactMap { $0["name"].string }).count, 6)
        XCTAssertEqual(ToolCatalog.schedule["oneOf"].array?.count, 4)
        for tool in ToolCatalog.tools {
            XCTAssertEqual(tool["inputSchema"]["additionalProperties"].bool, false)
            if !["reminders_list", "apps_get_status"].contains(tool["name"].string!) { XCTAssertTrue(tool["inputSchema"]["required"].array!.contains(.string("requestId"))) }
        }
    }
    func testPrivateDirectoryLockAndUnixSocketRoundTrip() throws {
        let dir = URL(fileURLWithPath: "/tmp/meno-ipc-" + UUID().uuidString)
        let original = ProcessInfo.processInfo.environment["MENO_DATA_DIR"]
        setenv("MENO_DATA_DIR", dir.path, 1)
        defer {
            if let original { setenv("MENO_DATA_DIR", original, 1) } else { unsetenv("MENO_DATA_DIR") }
            try? FileManager.default.removeItem(at: dir)
        }
        let lock = try InstanceLock(directory: dir)
        try withExtendedLifetime(lock) { XCTAssertThrowsError(try InstanceLock(directory: dir)) }
        let server = LocalControlServer(path: MenoIdentity.socketPath) { request in
            ControlResponse(id: request.id, result: request.command == "large" ? .string(String(repeating: "x", count: 1_048_577)) : .object(["command": .string(request.command)]))
        }
        try server.start(); defer { server.stop() }
        let result = try LocalControlClient().call(ControlRequest(command: "ping"), autoLaunch: false)
        XCTAssertEqual(result["command"].string, "ping")
        XCTAssertThrowsError(try LocalControlClient().call(ControlRequest(command: "large"), autoLaunch: false)) { XCTAssertEqual(($0 as? ControlError)?.code, "message_too_large") }
        let mode = try FileManager.default.attributesOfItem(atPath: MenoIdentity.socketPath)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        var unsupported = ControlRequest(command: "ping"); unsupported.version = 99
        XCTAssertThrowsError(try LocalControlClient().call(unsupported, autoLaunch: false)) { XCTAssertEqual(($0 as? ControlError)?.code, "protocol_version") }
    }
    func testSocketPathCannotOverwriteAnExistingDataFile() throws {
        let dir = URL(fileURLWithPath: "/tmp/meno-file-" + UUID().uuidString)
        try PrivateDirectory.prepare(dir); defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("control.sock"), data = Data("preserve".utf8); try data.write(to: path)
        let server = LocalControlServer(path: path.path) { ControlResponse(id: $0.id) }
        XCTAssertThrowsError(try server.start()); XCTAssertEqual(try Data(contentsOf: path), data)
    }
}
