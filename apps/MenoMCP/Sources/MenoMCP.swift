import Foundation
import MCP
import MenoControlProtocol

@main
struct MenoMCP {
    static func main() async {
        do {
            let server = Server(name: "Meno", version: "0.1.0", capabilities: .init(tools: .init(listChanged: false)))
            let tools = try ToolCatalog.tools.map { try JSONDecoder().decode(Tool.self, from: JSONEncoder.meno.encode($0)) }
            await server.withMethodHandler(ListTools.self) { _ in .init(tools: tools) }
            await server.withMethodHandler(CallTool.self) { params in
                do {
                    guard tools.contains(where: { $0.name == params.name }) else { throw ControlError("unknown_tool", "未知工具。") }
                    let arguments = try JSONDecoder.meno.decode([String: JSONValue].self, from: JSONEncoder().encode(params.arguments ?? [:]))
                    let request = ControlRequest(command: params.name, arguments: arguments, source: "mcp")
                    let result = try await Task.detached { try LocalControlClient().call(request) }.value
                    let structured = try JSONDecoder().decode(Value.self, from: JSONEncoder.meno.encode(result))
                    return .init(content: [.text(text: result.text(), annotations: nil, _meta: nil)], structuredContent: Optional.some(structured), isError: false)
                } catch {
                    let error = (error as? ControlError) ?? ControlError("operation_failed", error.localizedDescription)
                    let result = JSONValue.object(["error": try .encode(error)])
                    let structured = try JSONDecoder().decode(Value.self, from: JSONEncoder.meno.encode(result))
                    return .init(content: [.text(text: result.text(), annotations: nil, _meta: nil)], structuredContent: Optional.some(structured), isError: true)
                }
            }
            try await server.start(transport: StdioTransport())
            await server.waitUntilCompleted()
        } catch {
            FileHandle.standardError.write(Data(("Meno MCP：" + error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
}
