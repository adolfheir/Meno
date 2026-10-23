import Foundation

public enum ToolCatalog {
    private static func string(_ description: String, extra: [String: JSONValue] = [:]) -> JSONValue {
        .object(["type": .string("string"), "description": .string(description)].merging(extra) { _, new in new })
    }
    private static func object(_ properties: [String: JSONValue], required: [String]) -> JSONValue {
        .object(["type": .string("object"), "properties": .object(properties), "required": .array(required.map(JSONValue.string)), "additionalProperties": .bool(false)])
    }
    private static let requestID = string("每个新写操作使用唯一 requestId；相同参数重试必须复用，以避免重复。", extra: ["minLength": .number(1), "maxLength": .number(200)])
    private static let type = string("只使用所选提醒类型，不自动替换或同时展示两种。", extra: ["enum": .array([.string("system"), .string("fullscreen")])])
    private static let appID = string("子应用 ID，支持 com.meno.reminders 或别名 reminders。", extra: ["default": .string(MenoIdentity.remindersID)])
    public static let schedule: JSONValue = .object(["description": .string("四种互斥时间结构；重复提醒按本机当地墙上时钟，工作日为周一至周五。"), "oneOf": .array([
        object(["kind": .object(["const": .string("once")]), "at": string("未来的绝对时刻，必须带时区。", extra: ["format": .string("date-time")])], required: ["kind", "at"]),
        object(["kind": .object(["const": .string("delay")]), "afterSeconds": .object(["type": .string("number"), "exclusiveMinimum": .number(0), "maximum": .number(315_360_000)])], required: ["kind", "afterSeconds"]),
        object(["kind": .object(["const": .string("daily")]), "time": string("24 小时制 HH:mm", extra: ["pattern": .string("^([01][0-9]|2[0-3]):[0-5][0-9]$")])], required: ["kind", "time"]),
        object(["kind": .object(["const": .string("weekdays")]), "time": string("24 小时制 HH:mm", extra: ["pattern": .string("^([01][0-9]|2[0-3]):[0-5][0-9]$")])], required: ["kind", "time"]),
    ])])
    public static let tools: [JSONValue] = {
        let title = string("提醒内容，1 至 500 字。", extra: ["minLength": .number(1), "maxLength": .number(500)])
        let note = string("备注，可为空，最多 10000 字。", extra: ["maxLength": .number(10000)])
        let id = string("查询或创建回执中的提醒 UUID。")
        func tool(_ name: String, _ description: String, _ properties: [String: JSONValue], _ required: [String], readOnly: Bool = false) -> JSONValue {
            .object(["name": .string(name), "description": .string(description), "inputSchema": object(properties, required: required),
                "annotations": .object(["readOnlyHint": .bool(readOnly), "destructiveHint": .bool(false), "idempotentHint": .bool(true), "openWorldHint": .bool(false)])])
        }
        return [
            tool("reminders_create", "保存提醒；默认不启用后台。必须根据 saved、armed、blockedReason 告知用户实际状态。相对时间仅首次解析。", ["title": title, "note": note, "schedule": schedule, "reminderType": type, "enablePlugin": .object(["type": .string("boolean"), "default": .bool(false)]), "requestId": requestID], ["title", "schedule", "requestId"]),
            tool("reminders_list", "分页查询事项或触发历史；from 含、to 不含，均为带时区的 ISO 8601。", ["status": string("history 返回触发实例，其余返回提醒定义与当前调度状态。", extra: ["enum": .array(["all", "active", "paused", "history", "cancelled"].map(JSONValue.string))]), "reminderType": type,
                "from": string("时间区间起点", extra: ["format": .string("date-time")]), "to": string("时间区间终点", extra: ["format": .string("date-time")]),
                "offset": .object(["type": .string("integer"), "minimum": .number(0), "maximum": .number(1_000_000)]), "limit": .object(["type": .string("integer"), "minimum": .number(1), "maximum": .number(200), "default": .number(50)])], [], readOnly: true),
            tool("reminders_update", "按 ID 修改提醒；省略字段保持原值。修改会撤销旧计划并同步新计划，失败时保留已保存事项并报告调度状态。", ["id": id, "title": title, "note": note, "schedule": schedule, "reminderType": type, "isEnabled": .object(["type": .string("boolean")]), "requestId": requestID], ["id", "requestId"]),
            tool("reminders_cancel", "取消未来触发，保留事项和历史。", ["id": id, "requestId": requestID], ["id", "requestId"]),
            tool("apps_get_status", "查询后台状态、通知权限与受阻原因；查询不会启用子应用。", ["appId": appID], [], readOnly: true),
            tool("apps_set_enabled", "显式启停子应用后台；停用不关闭窗口、也不删除数据，停用期间到期不补弹。", ["appId": appID, "enabled": .object(["type": .string("boolean")]), "requestId": requestID], ["enabled", "requestId"]),
        ]
    }()
}
