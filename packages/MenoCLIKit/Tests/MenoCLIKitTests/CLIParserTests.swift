import MenoCLIKit
import MenoControlProtocol
import XCTest

final class CLIParserTests: XCTestCase {
  private func request(_ input: [String]) throws -> ControlRequest {
    guard case .request(let request, _) = try CLIParser.parse(input) else {
      throw ControlError("test_failure", "Expected a request")
    }
    return request
  }

  func testHelpAndVersionNeverRequireHost() throws {
    for input in [[], ["help"], ["--help"], ["--version"]] {
      guard case .text(let text) = try CLIParser.parse(input) else { return XCTFail() }
      XCTAssertFalse(text.isEmpty)
    }
  }

  func testCreateConvertsUnitsAndPreservesExplicitRequestID() throws {
    for (text, seconds) in [("1.5m", 90.0), ("30s", 30), ("2h", 7200), ("1d", 86400)] {
      let r = try request([
        "reminders", "add", "--title", "喝水", "--in", text, "--type", "fullscreen",
        "--enable-plugin", "--request-id", "retry-1",
      ])
      XCTAssertEqual(r.command, "reminders_create")
      XCTAssertEqual(r.arguments["schedule"]?["afterSeconds"].number, seconds)
      XCTAssertEqual(r.arguments["enablePlugin"], .bool(true))
      XCTAssertEqual(r.arguments["requestId"], .string("retry-1"))
      XCTAssertEqual(r.source, "cli")
    }
  }

  func testUpdatePreservesOmittedFieldsAndAcceptsEmptyNote() throws {
    let r = try request(["reminders", "update", "id", "--note", "", "--enabled", "false"])
    XCTAssertEqual(r.command, "reminders_update")
    XCTAssertEqual(r.arguments["note"], .string(""))
    XCTAssertEqual(r.arguments["isEnabled"], .bool(false))
    XCTAssertNil(r.arguments["title"])
    XCTAssertNil(r.arguments["schedule"])
  }

  func testEachNewWriteGetsItsOwnRetryID() throws {
    let a = try request(["apps", "enable"])
    let b = try request(["apps", "enable"])
    XCTAssertNotEqual(a.arguments["requestId"], b.arguments["requestId"])
    XCTAssertNotNil(a.arguments["requestId"]?.string.flatMap { UUID(uuidString: $0) })
  }

  func testNoLaunchAndRawCallPreserveStructuredParameters() throws {
    guard
      case .request(let r, let launch) = try CLIParser.parse([
        "call", "reminders_list", "--arguments", "{\"limit\":2}", "--no-launch", "--json",
      ])
    else { return XCTFail() }
    XCTAssertFalse(launch)
    XCTAssertEqual(r.command, "reminders_list")
    XCTAssertEqual(r.arguments["limit"], .number(2))
  }

  func testAlternateScheduleBranches() throws {
    for (flag, value, key) in [
      ("at", "2027-01-01T00:00:00Z", "at"), ("daily", "15:00", "time"),
      ("weekdays", "09:00", "time"),
    ] {
      let r = try request(["reminders", "add", "--title", "事项", "--" + flag, value])
      XCTAssertEqual(r.arguments["schedule"]?[key], .string(value))
      XCTAssertEqual(r.arguments["schedule"]?["kind"], .string(flag == "at" ? "once" : flag))
    }
  }

  func testQueryAndNavigationCommands() throws {
    XCTAssertEqual(try request(["reminders", "history"]).arguments["status"], .string("history"))
    XCTAssertEqual(
      try request(["reminders", "list", "--limit", "200", "--offset", "2"]).arguments["offset"],
      .number(2))
    XCTAssertEqual(try request(["apps", "disable"]).arguments["enabled"], .bool(false))
    XCTAssertEqual(try request(["open", "settings"]).arguments["appId"], .string("settings"))
    XCTAssertEqual(try request(["notifications", "request"]).command, "notification_request")
    XCTAssertEqual(try request(["quit"]).command, "app_quit")
  }

  func testMalformedFlagsAndPositionalsAreRejectedBeforeIPC() {
    let cases = [
      ["--json"], ["unknown"], ["reminders"], ["reminders", "cancel"],
      ["reminders", "add", "extra"], ["apps", "status", "a", "b"],
      ["reminders", "add", "--title"], ["apps", "status", "--unknown", "x"],
      ["reminders", "add", "--title", "a", "--title", "b"],
      ["apps", "status", "--json", "--json"], ["apps", "status", "--enable-plugin"],
      ["reminders", "update", "id", "--enabled", "yes"],
      ["reminders", "update", "id", "--enable-plugin"],
      ["call", "x", "--arguments", "[]"], ["call", "x", "--arguments", "{"],
    ]
    for input in cases {
      XCTAssertThrowsError(try CLIParser.parse(input), input.joined(separator: " "))
    }
  }

  func testConflictingZeroAndOverflowDelaysAreRejected() {
    XCTAssertThrowsError(
      try CLIParser.parse(["reminders", "add", "--in", "1h", "--daily", "15:00"]))
    for value in [
      "0s", "-1s", "NaNs", "infs", "1e3s", "1", "315360001s",
      String(repeating: "9", count: 400) + "d",
    ] {
      XCTAssertThrowsError(try CLIParser.parse(["reminders", "add", "--in", value]), value)
    }
  }

  func testPaginationRejectsNonFiniteFractionalAndOutOfRangeNumbers() {
    for value in ["nan", "inf", "-1", "0", "201", "1.5", "x"] {
      XCTAssertThrowsError(try CLIParser.parse(["reminders", "list", "--limit", value]), value)
    }
    for value in ["-1", "1000001", "inf", "0.5"] {
      XCTAssertThrowsError(try CLIParser.parse(["reminders", "list", "--offset", value]), value)
    }
  }
}
