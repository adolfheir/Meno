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
    private static func integer(_ min: Int, _ max: Int, description: String = "") -> JSONValue {
        .object(["type": .string("integer"), "minimum": .number(Double(min)), "maximum": .number(Double(max)), "description": .string(description)])
    }
    private static func array(_ items: JSONValue, min: Int = 1, max: Int) -> JSONValue {
        .object(["type": .string("array"), "items": items, "minItems": .number(Double(min)), "maxItems": .number(Double(max)), "uniqueItems": .bool(true)])
    }
    public static let schedule: JSONValue = {
        let absolute = string("带时区的 ISO 8601 绝对时间。", extra: ["format": .string("date-time")])
        let time = string("24 小时制 HH:mm", extra: ["pattern": .string("^([01][0-9]|2[0-3]):[0-5][0-9]$")])
        let day = string("公历日期 YYYY-MM-DD", extra: ["pattern": .string("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")])
        let days = JSONValue.object(["type": .string("integer"), "enum": .array(([-1] + Array(1...31)).map { .number(Double($0)) })])
        let ordinal = JSONValue.object(["type": .string("integer"), "enum": .array([-1, 1, 2, 3, 4, 5].map { .number(Double($0)) }), "description": .string("第几个星期几；-1 为最后一个。")])
        var branches = [
            object(["kind": .object(["const": .string("once")]), "at": absolute], required: ["kind", "at"]),
            object(["kind": .object(["const": .string("delay")]), "afterSeconds": .object(["type": .string("number"), "exclusiveMinimum": .number(0), "maximum": .number(315_360_000)])], required: ["kind", "afterSeconds"]),
        ]
        for kind in ["daily", "weekdays", "weekly", "monthly", "yearly", "interval"] {
            var properties: [String: JSONValue] = [
                "kind": .object(["const": .string(kind)]),
                "timeZone": string("IANA 时区，如 Asia/Shanghai；省略则跟随本机时区。"),
                "startAt": absolute, "endAt": absolute,
                "excludedDates": array(day, min: 0, max: 366),
            ]
            var required = ["kind"]
            var constraints: [JSONValue] = []
            if kind == "interval" {
                properties["everySeconds"] = .object(["type": .string("number"), "minimum": .number(60), "maximum": .number(315_360_000), "description": .string("固定秒数间隔。默认首次在一段间隔后；startAt 可指定首次。")])
                required.append("everySeconds")
            } else {
                properties["time"] = time; properties["times"] = array(time, max: 24)
                constraints.append(.object(["oneOf": .array([.object(["required": .array([.string("time")])]), .object(["required": .array([.string("times")])])])]))
                if kind != "weekdays" { properties["every"] = integer(1, 100, description: "每隔 N 天/周/月/年，默认 1，按开始时间所在周期锚定；周一为周首。") }
            }
            if kind == "weekly" {
                properties["weekdays"] = array(integer(1, 7, description: "周一=1，周日=7；周末为 [6,7]。"), max: 7)
                required.append("weekdays")
            }
            if kind == "monthly" || kind == "yearly" {
                properties["monthDays"] = array(days, max: 32)
                properties["ordinal"] = ordinal; properties["weekday"] = integer(1, 7)
                constraints.append(.object(["oneOf": .array([
                    .object(["required": .array([.string("monthDays")]), "not": .object(["anyOf": .array([.object(["required": .array([.string("ordinal")])]), .object(["required": .array([.string("weekday")])])])])]),
                    .object(["required": .array([.string("ordinal"), .string("weekday")]), "not": .object(["required": .array([.string("monthDays")])])]),
                ])]))
            }
            if kind == "yearly" { properties["month"] = integer(1, 12); required.append("month") }
            var schema = object(properties, required: required).object!
            if !constraints.isEmpty { schema["allOf"] = .array(constraints) }
            branches.append(.object(schema))
        }
        return .object(["description": .string("单次、延迟、每天、工作日、自选星期、每月、每年及固定间隔；支持多时点、间隔周期、时区、起止（含边界）与排除日期。公历不存在的日期跳过；夏令时缺失时间顺延，重复时间只用首次。"), "oneOf": .array(branches)])
    }()
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
