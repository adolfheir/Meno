import Foundation

/// Connection instructions use the running bundle, so moving Meno does not leave stale paths.
public struct AIConnectionInfo {
    public let cliPath: String
    public let mcpPath: String

    public init(bundleURL: URL) {
        cliPath = bundleURL.appendingPathComponent("Contents/Helpers/meno").path
        mcpPath = bundleURL.appendingPathComponent("Contents/Helpers/meno-mcp").path
    }

    public var mcpConfiguration: String {
        JSONValue.object(["mcpServers": .object(["meno": .object([
            "command": .string(mcpPath), "args": .array([])
        ])])]).text(pretty: true)
    }

    public var verificationCommands: [String] {
        let command = "'" + cliPath.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return [command + " apps status reminders --json",
                command + " reminders list --status active --limit 20 --json"]
    }

    public var prompt: String {
        """
        请连接这台 Mac 上的 Meno，之后按我的要求管理本地提醒。现在先验证连接、读取后台状态和待提醒事项，不要创建测试事项。

        连接方式（选当前环境可用的一种）：
        1. 如果已有 Meno MCP 工具，调用 apps_get_status（appId: "reminders"），再调用 reminders_list（status: "active", limit: 20）。
        2. 如果可以在这台 Mac 执行终端命令，直接使用随 App 提供的 CLI，无需安装额外依赖：
        ```sh
        \(verificationCommands.joined(separator: "\n"))
        ```
        后续命令可通过同一路径的 meno --help 查询。
        3. 如果需要配置 MCP，这是当前安装位置对应的 stdio 配置；将 meno 这一项合入客户端现有 MCP 配置，保留其他服务，并按客户端要求重新加载：
        ```json
        \(mcpConfiguration)
        ```

        后续操作约定：
        - 通过 CLI 或 MCP 创建、查询、修改、取消提醒，不直接修改数据库。
        - 时间含糊时先确认；绝对时间包含时区。提醒类型使用我的选择或应用默认值。
        - 每个新写操作使用唯一 requestId（CLI 为 --request-id）；相同参数重试复用同一个 ID。
        - 根据回执中的 saved、armed、blockedReason 说明实际结果：已保存不代表已安排。后台暂停或通知未授权时说明原因，不自行切换提醒类型或启用后台。
        - 验证成功后告诉我连接方式、后台状态和待提醒数量。若没有本机命令执行或 MCP 能力，明确说明尚未连接，不要声称已执行。
        """
    }
}
