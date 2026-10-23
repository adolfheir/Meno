import Foundation
import MenoCLIKit
import MenoControlProtocol

do {
    switch try CLIParser.parse(Array(CommandLine.arguments.dropFirst())) {
    case .text(let text): print(text)
    case .request(let request, let autoLaunch):
        print(try LocalControlClient().call(request, autoLaunch: autoLaunch).text(pretty: true))
    }
} catch {
    let e = (error as? ControlError) ?? ControlError("operation_failed", error.localizedDescription)
    let value = JSONValue.object(["error": (try? .encode(e)) ?? .string(e.localizedDescription)])
    FileHandle.standardError.write(Data((value.text() + "\n").utf8)); exit(1)
}
