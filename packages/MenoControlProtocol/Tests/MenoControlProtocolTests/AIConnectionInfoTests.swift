import Foundation
import MenoControlProtocol
import XCTest

final class AIConnectionInfoTests: XCTestCase {
    func testConfigurationUsesSuppliedBundleAndRoundTripsSpecialCharacters() throws {
        let bundle = URL(fileURLWithPath: "/tmp/我的 Apps/Meno's \"Local\".app")
        let info = AIConnectionInfo(bundleURL: bundle)
        let config = try JSONDecoder().decode(JSONValue.self, from: Data(info.mcpConfiguration.utf8))
        XCTAssertEqual(config["mcpServers"]["meno"]["command"].string,
                       bundle.appendingPathComponent("Contents/Helpers/meno-mcp").path)
        XCTAssertEqual(config["mcpServers"]["meno"]["args"].array, [])
        XCTAssertTrue(info.prompt.contains(info.mcpConfiguration))
        for command in info.verificationCommands { XCTAssertTrue(info.prompt.contains(command)) }
    }

    func testCopiedCommandsExecuteFromPathsWithSpacesQuotesAndShellMetacharacters() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("meno-prompt-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = directory.appendingPathComponent("我的 Meno's $HOME `whoami` $(printf nope).app")
        let info = AIConnectionInfo(bundleURL: bundle)
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents/Helpers"), withIntermediateDirectories: true)
        // This fixture prints the arguments it actually receives from the shell.
        try Data("#!/bin/sh\nprintf '%s\\n' \"$@\"\n".utf8).write(to: URL(fileURLWithPath: info.cliPath))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: info.cliPath)
        let expected = ["apps\nstatus\nreminders\n--json\n", "reminders\nlist\n--status\nactive\n--limit\n20\n--json\n"]
        for (command, arguments) in zip(info.verificationCommands, expected) {
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            process.standardOutput = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            XCTAssertEqual(String(decoding: data, as: UTF8.self), arguments)
        }
    }
}
