import Foundation
import MenoControlProtocol

public enum CLIAction {
  case text(String)
  case request(ControlRequest, autoLaunch: Bool)
}

/// Parse without IPC or launching the host, so malformed commands have no side effects.
public enum CLIParser {
  public static let help = """
    Meno 0.1.0 — 本地提醒控制工具
    meno reminders add --title 内容 (--in 20m | --at ISO8601 | --daily HH:mm | --weekdays HH:mm) [--type system|fullscreen] [--note 备注] [--enable-plugin] [--request-id ID] [--json]
    meno reminders update <id> [--title 内容] [--in 30m | --at ISO8601 | --daily HH:mm | --weekdays HH:mm] [--type system|fullscreen] [--enabled true|false] [--request-id ID]
    meno reminders cancel <id> [--request-id ID]
    时间规则：--daily HH:mm[,HH:mm] | --weekdays HH:mm[,HH:mm]
    --weekly 5,6,7 --times 10:55,17:55 | --monthly 1,15,-1 --time 09:00
    --yearly 02-29 --time 09:00 | --interval 2h | --schedule '<JSON>'
    重复选项：--every 2 --timezone Asia/Shanghai --start-at ISO8601 --end-at ISO8601 --exclude YYYY-MM-DD[,YYYY-MM-DD]
    星期 1=周一、7=周日；月日期 -1=月末。--schedule 支持每月第几个星期几等完整配置。
    meno reminders list [--status all|active|paused|history|cancelled] [--type system|fullscreen] [--from ISO8601] [--to ISO8601] [--limit 50] [--offset 0]
    meno reminders history
    meno apps status [reminders]
    meno apps enable|disable [reminders] [--request-id ID]
    meno open [reminders|settings|current-reminder]
    meno notifications request
    meno diagnostics
    meno quit
    meno call <command> --arguments '<JSON对象>'
    所有结果使用 JSON；--no-launch 禁止自动启动宿主。写操作请复用 --request-id 安全重试。
    """

  public static func parse(_ input: [String]) throws -> CLIAction {
    if input.isEmpty || input == ["--help"] || input == ["help"] { return .text(help) }
    if input == ["--version"] { return .text("0.1.0") }
    var positions: [String] = []
    var flags: [String: String] = [:]
    var booleans: Set<String> = []
    var index = 0
    while index < input.count {
      let token = input[index]
      if token.hasPrefix("--") {
        let key = String(token.dropFirst(2))
        guard flags[key] == nil && !booleans.contains(key) else {
          throw ControlError("invalid_argument", "重复参数：" + token)
        }
        if ["json", "enable-plugin", "no-launch"].contains(key) {
          booleans.insert(key)
        } else {
          guard index + 1 < input.count, !input[index + 1].hasPrefix("--") else {
            throw ControlError("invalid_argument", token + " 缺少参数值。")
          }
          index += 1
          flags[key] = input[index]
        }
      } else {
        positions.append(token)
      }
      index += 1
    }
    guard let first = positions.first else { throw ControlError("invalid_argument", "缺少命令。") }
    var args: [String: JSONValue] = [:]
    var command = ""
    var allowed: Set<String> = []
    var writing = false
    let scheduleFlags: Set<String> = ["in", "at", "daily", "weekdays", "weekly", "monthly", "yearly", "interval", "schedule", "time", "times", "every", "timezone", "start-at", "end-at", "exclude"]
    func duration(_ value: String) throws -> Double {
      guard let match = value.range(of: "^[0-9]+(\\.[0-9]+)?[smhd]$", options: .regularExpression), match == value.startIndex..<value.endIndex,
        let number = Double(value.dropLast()), number.isFinite, number > 0, let unit = value.last
      else { throw ControlError("invalid_schedule", "时长使用如 30s、20m、1h、2d。") }
      let scale: Double = unit == "s" ? 1 : unit == "m" ? 60 : unit == "h" ? 3600 : 86400
      guard number * scale <= 315_360_000 else { throw ControlError("invalid_schedule", "时长不能超过十年。") }
      return number * scale
    }
    func schedule() throws -> JSONValue? {
      let selectors = ["in", "at", "daily", "weekdays", "weekly", "monthly", "yearly", "interval", "schedule"]
      let keys = selectors.filter { flags[$0] != nil }
      guard keys.count <= 1 else { throw ControlError("invalid_schedule", "只能选择一种时间规则。") }
      guard let key = keys.first, let value = flags[key] else {
        if flags.keys.contains(where: { scheduleFlags.contains($0) }) { throw ControlError("invalid_schedule", "时间选项需要同时指定时间规则。") }
        return nil
      }
      if ["in", "at", "schedule"].contains(key) {
        guard !flags.keys.contains(where: { scheduleFlags.contains($0) && $0 != key }) else { throw ControlError("invalid_schedule", "此时间规则不能与其他时间参数混用。") }
        if key == "in" { return .object(["kind": .string("delay"), "afterSeconds": .number(try duration(value))]) }
        if key == "at" { return .object(["kind": .string("once"), "at": .string(value)]) }
        guard let data = value.data(using: .utf8), let result = try? JSONDecoder.meno.decode(JSONValue.self, from: data), result.object != nil else { throw ControlError("invalid_schedule", "--schedule 需要 JSON 对象。") }
        return result
      }
      var result: [String: JSONValue] = ["kind": .string(key)]
      func csv(_ text: String) -> [String] { text.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) } }
      if key == "interval" {
        guard flags["time"] == nil, flags["times"] == nil, flags["every"] == nil else { throw ControlError("invalid_schedule", "固定间隔不接受钟点或日历周期。") }
        result["everySeconds"] = .number(try duration(value))
      } else {
        let clock: String
        if key == "daily" || key == "weekdays" {
          guard flags["time"] == nil, flags["times"] == nil else { throw ControlError("invalid_schedule", "请直接在 --daily 或 --weekdays 后指定时点。") }
          clock = value
        } else {
          guard (flags["time"] != nil) != (flags["times"] != nil) else { throw ControlError("invalid_schedule", "请使用 --time HH:mm 或 --times HH:mm,HH:mm。") }
          clock = flags["time"] ?? flags["times"]!
        }
        if clock.contains(",") { result["times"] = .array(csv(clock).map(JSONValue.string)) }
        else { result["time"] = .string(clock) }
        if key == "weekly" || key == "monthly" {
          let items = csv(value)
          guard items.allSatisfy({ Int($0) != nil }) else { throw ControlError("invalid_schedule", "星期或月日期必须为逗号分隔的整数。") }
          result[key == "weekly" ? "weekdays" : "monthDays"] = .array(items.map { .number(Double(Int($0)!)) })
        }
        if key == "yearly" {
          let parts = value.split(separator: "-", omittingEmptySubsequences: false)
          guard parts.count == 2, let month = Int(parts[0]), let day = Int(parts[1]) else { throw ControlError("invalid_schedule", "--yearly 使用 MM-DD，例如 02-29。") }
          result["month"] = .number(Double(month)); result["monthDays"] = .array([.number(Double(day))])
        }
        if let every = flags["every"] {
          guard let n = Int(every), (1...100).contains(n), key != "weekdays" else { throw ControlError("invalid_schedule", "--every 为 1–100，周一至周五规则不接受此选项。") }
          result["every"] = .number(Double(n))
        }
      }
      for (flag, field) in [("timezone", "timeZone"), ("start-at", "startAt"), ("end-at", "endAt")] {
        if let value = flags[flag] { result[field] = .string(value) }
      }
      if let value = flags["exclude"] { result["excludedDates"] = .array(csv(value).map(JSONValue.string)) }
      return .object(result)
    }
    switch first {
    case "reminders":
      guard positions.count >= 2 else {
        throw ControlError("invalid_argument", "缺少 reminders 子命令。")
      }
      switch positions[1] {
      case "add", "update":
        let update = positions[1] == "update"
        guard positions.count == (update ? 3 : 2) else {
          throw ControlError("invalid_argument", update ? "update 需要唯一提醒 ID。" : "add 不接受位置参数。")
        }
        command = update ? "reminders_update" : "reminders_create"
        writing = true
        allowed = Set(["title", "note", "type", "request-id"]).union(scheduleFlags)
        if update {
          args["id"] = .string(positions[2])
          allowed.insert("enabled")
        }
        if let title = flags["title"] { args["title"] = .string(title) }
        if let note = flags["note"] { args["note"] = .string(note) }
        if let type = flags["type"] { args["reminderType"] = .string(type) }
        if let schedule = try schedule() { args["schedule"] = schedule }
        if let enabled = flags["enabled"] {
          guard ["true", "false"].contains(enabled) else {
            throw ControlError("invalid_argument", "--enabled 仅接受 true 或 false。")
          }
          args["isEnabled"] = .bool(enabled == "true")
        }
        if booleans.contains("enable-plugin") {
          guard !update else { throw ControlError("invalid_argument", "--enable-plugin 仅用于创建。") }
          args["enablePlugin"] = .bool(true)
        }
      case "cancel":
        guard positions.count == 3 else {
          throw ControlError("invalid_argument", "cancel 需要唯一提醒 ID。")
        }
        command = "reminders_cancel"
        writing = true
        args["id"] = .string(positions[2])
        allowed = ["request-id"]
      case "list", "history":
        guard positions.count == 2 else { throw ControlError("invalid_argument", "list 不接受位置参数。") }
        command = "reminders_list"
        allowed = ["status", "type", "from", "to", "limit", "offset"]
        for (key, value) in flags where allowed.contains(key) {
          if key == "limit" || key == "offset" {
            guard let n = Double(value), n.isFinite, n.rounded() == n,
              n >= (key == "limit" ? 1 : 0), n <= (key == "limit" ? 200 : 1_000_000)
            else { throw ControlError("invalid_argument", key + " 必须为整数。") }
            args[key] = .number(n)
          } else {
            args[key == "type" ? "reminderType" : key] = .string(value)
          }
        }
        if positions[1] == "history" { args["status"] = .string("history") }
      default: throw ControlError("invalid_argument", "未知 reminders 子命令。")
      }
    case "apps":
      guard (2...3).contains(positions.count) else {
        throw ControlError("invalid_argument", "使用 apps status|enable|disable [reminders]。")
      }
      args["appId"] = .string(positions.count == 3 ? positions[2] : "reminders")
      switch positions[1] {
      case "status": command = "apps_get_status"
      case "enable", "disable":
        command = "apps_set_enabled"
        args["enabled"] = .bool(positions[1] == "enable")
        writing = true
        allowed = ["request-id"]
      default: throw ControlError("invalid_argument", "未知 apps 子命令。")
      }
    case "open":
      guard positions.count <= 2 else { throw ControlError("invalid_argument", "open 只接受一个子应用。") }
      command = "app_open"
      args["appId"] = .string(positions.count == 2 ? positions[1] : "reminders")
    case "notifications":
      guard positions == ["notifications", "request"] else {
        throw ControlError("invalid_argument", "使用 notifications request。")
      }
      command = "notification_request"
    case "diagnostics", "quit":
      guard positions.count == 1 else { throw ControlError("invalid_argument", "参数过多。") }
      command = first == "quit" ? "app_quit" : "diagnostics"
    case "call":
      guard positions.count == 2, let text = flags["arguments"],
        let object = try JSONDecoder.meno.decode(JSONValue.self, from: Data(text.utf8)).object
      else { throw ControlError("invalid_argument", "使用 call <command> --arguments '<JSON对象>'。") }
      command = positions[1]
      args = object
      allowed = ["arguments"]
    default: throw ControlError("invalid_argument", "未知命令，使用 meno --help。")
    }
    if let invalid = flags.keys.sorted().first(where: { !allowed.contains($0) }) {
      throw ControlError("invalid_argument", "不支持参数 --" + invalid)
    }
    if booleans.contains("enable-plugin") && command != "reminders_create" {
      throw ControlError("invalid_argument", "--enable-plugin 仅用于创建。")
    }
    if writing { args["requestId"] = .string(flags["request-id"] ?? UUID().uuidString) }
    return .request(
      ControlRequest(command: command, arguments: args), autoLaunch: !booleans.contains("no-launch")
    )
  }
}
