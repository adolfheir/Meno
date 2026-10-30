# MCP 与 CLI 接入

Meno 本身不理解自然语言、不调用模型。外部客户端将用户的话转换成确定字段，Meno 校验、事务保存并独立执行提醒。MCP、CLI 和界面进入同一串行业务命令服务，只有宿主写数据库；不能用修改 SQLite 或 JSON 文件代替控制协议。

## 标准 MCP

使用官方 MCP Swift SDK 0.12.1 的 Server、Tools、StdioTransport，`Package.resolved` 锁定全部依赖。将下面的路径改成实际安装路径后加入支持 `mcpServers` 的客户端；设置页「复制 MCP 配置」会根据当前 App 位置生成正确路径。不会自动修改任何其他客户端的全局配置。

```json
{
  "mcpServers": {
    "meno": {
      "command": "/Users/你的用户名/Applications/Meno.app/Contents/Helpers/meno-mcp",
      "args": []
    }
  }
}
```

客户端通过 stdio 启动桥接程序。标准输出只有 MCP JSON-RPC 消息，错误和日志走标准错误。握手和工具发现不启动宿主、不启用子应用；实际工具调用时，如果宿主尚未运行，会用后台方式打开辅助程序所属的 Meno.app，等待最多 12 秒。已有宿主上的调用超时为 30 秒，桥接断开不会退出宿主。

| 工具 | 参数与行为 |
| --- | --- |
| `reminders_create` | 必填 `title`、`schedule`、`requestId`；可选 `note`、`reminderType`、`enablePlugin` |
| `reminders_list` | `status` 为 all / active / paused / history / cancelled；可选 `reminderType`、`from`、`to`、`offset`、`limit`，默认 50、最多 200 |
| `reminders_update` | 必填 `id`、`requestId`，另至少提供 title / note / reminderType / schedule / isEnabled 中一个字段；省略字段保持原值，空备注使用空字符串 |
| `reminders_cancel` | 必填 `id`、`requestId`；撤销未来计划，保留事项和历史 |
| `apps_get_status` | 可选 `appId`，默认 com.meno.reminders，别名 reminders；返回实际运行、启用偏好、通知权限、受阻原因 |
| `apps_set_enabled` | 必填 `enabled`、`requestId`；可选 `appId`；显式控制后台，停用完成后待触发通知和覆盖层均清理 |

`reminderType` 仅接受 `system` 或 `fullscreen`，省略时采用设置中的默认值。`enablePlugin` 默认 false，保存不会隐式打开被用户停用的后台。所有字段严格校验，不接受未知字段、null 代替省略、布尔值代替数值或互相冲突的时间字段。

`schedule` 支持下列互斥规则。绝对时间必须包含时区；日历规则采用公历，星期按 ISO 编号（周一=1，周日=7）。保留原有单次、延迟、每天、周一至周五参数。

```json
{"kind":"delay","afterSeconds":1200}
{"kind":"once","at":"2027-01-02T09:00:00+08:00"}
{"kind":"daily","time":"15:00"}
{"kind":"weekdays","times":["09:30","18:00"]}
{"kind":"weekly","weekdays":[5,6,7],"times":["10:55","17:55"],"timeZone":"Asia/Shanghai"}
{"kind":"monthly","monthDays":[1,15,-1],"time":"09:00"}
{"kind":"monthly","ordinal":-1,"weekday":5,"time":"17:00"}
{"kind":"yearly","month":2,"monthDays":[29],"time":"09:00"}
{"kind":"yearly","month":11,"ordinal":4,"weekday":4,"time":"09:00"}
{"kind":"interval","everySeconds":7200}
```

日历规则必须且只能选择 `time` 或 `times`，后者为 1–24 个不重复的 `HH:mm`。`weekly.weekdays` 可任选 1–7，周末为 `[6,7]`。月/年规则选择 `monthDays`（1–31，`-1` 表示月末），或者同时提供 `ordinal`（1–5 或 `-1` 最后一个）与 `weekday`（1–7），两种方式互斥。`yearly` 额外需要 `month`（1–12）。

| 可选字段 | 规则 |
| --- | --- |
| `every` | daily / weekly / monthly / yearly 的间隔周期，1–100，默认 1；如每 3 天、每 2 周、每 3 个月、每 2 年。按开始所在周期锚定，周一为周首。 |
| `timeZone` | 固定时区，如 `Asia/Shanghai`；省略则跟随本机时区。间隔规则仍按真实经过的秒数，时区仅用于排除日期。 |
| `startAt` | 带时区的开始时间（包含边界）；日历规则默认从保存时开始，固定间隔默认首次在一段间隔后。 |
| `endAt` | 带时区的结束时间（包含边界）；省略为无限重复。 |
| `excludedDates` | 最多 366 个不重复的 `YYYY-MM-DD`，按规则时区跳过这些日期。 |

`interval.everySeconds` 为 60 秒到十年的固定间隔，可配合起止与排除日期；不接受钟点或 `every`。睡眠/重启按原始锚点恢复，不因恢复时刻改变间隔。

月末采用实际最后一天；31 日会跳过没有 31 日的月份，2 月 29 日会跳过平年，第 5 个星期几不存在时跳过，均不会溢出到下个月。夏令时缺失的钟点顺延到当天首个有效时间，重复的钟点只用第一次；同一天多个钟点顺延后重合时只触发一次。没有未来有效时间的配置会拒绝保存。开始/结束与排除条件均参与实际调度。

这套规则不推断法定节假日、调休、农历或自然语言，也不接受 cron/RRULE 表达式。界面、CLI、MCP 共用校验及下一次触发计算；新版本可直接读取旧提醒数据。后台仍每条事项滚动安排下一次触发，固定间隔和多时点在 30 分钟恢复窗口内逐次补入；主动暂停期间不会补弹。

例如，显式启用后台并创建全屏提醒：

```json
{
  "name":"reminders_create",
  "arguments":{
    "title":"喝水",
    "reminderType":"fullscreen",
    "schedule":{"kind":"delay","afterSeconds":1200},
    "enablePlugin":true,
    "requestId":"drink-water-001"
  }
}
```

## 回执和重试

成功工具同时返回 JSON 文本和 `structuredContent`，业务错误设置 `isError: true` 并包含 `error.code`、`error.message`。成功写入至少包含 `id`、`saved`、`armed`、`reminderType`、`nextTriggerAt`、`blockedReason`。`reminder` 是首次写入快照，`current` 是当前定义及运行状态，`replayed` 表示是否幂等重放；启停回执同时包含最初 `requestedEnabled` 和当前 `enabled` / `running`。

`saved: true, armed: false` 是已保存但未进入调度，例如后台暂停、单条暂停、通知未授权、系统队列容量暂满或提交失败；客户端应将受阻原因告知用户。`armed` 只表示当前类型具备运行条件且已进入相应队列，不能保证通知一定被人看到。通知送达、通知关闭、到期和用户确认是不同状态。

每个新写操作必须使用新的 `requestId`。相同 ID 与相同参数重试只产生一次事务，保留第一次解析的相对时间；不同参数复用 ID 返回 `idempotency_conflict`。记录和事项／启用偏好在同一事务内提交。重试不会重新执行旧的启用要求，`armed` 等字段根据当前状态重算：旧创建成功后用户停用后台，再重试仍返回未调度。

响应丢失、超时或连接中断时使用原 requestId 和原参数重试。不要在同一个业务重试中生成新 ID，也不要看到 armed=false 就盲目重复创建。标题和备注会去掉两端空白；其他省略字段与显式字段属于不同请求参数，重试请保持一致。

查询日期为带时区 ISO 8601，范围左闭右开。`history` 返回触发实例，其余状态返回事项及当前调度状态；分页返回 items、total、offset、nextOffset。

## CLI

```sh
MENO='/实际位置/Meno.app/Contents/Helpers/meno'
"$MENO" --help
"$MENO" reminders add --title '喝水' --in 20m --type system --request-id water-001 --json
"$MENO" reminders add --title '站起来活动' --daily 15:00 --type fullscreen --enable-plugin --json
"$MENO" reminders add --title '周末提醒' --weekly 5,6,7 --times 10:55,17:55 --timezone Asia/Shanghai --request-id weekend-001
"$MENO" reminders add --title '月末' --monthly -1 --time 09:00 --request-id month-end-001
"$MENO" reminders add --title '闰日' --yearly 02-29 --time 09:00 --request-id leap-001
"$MENO" reminders add --title '每两小时' --interval 2h --request-id interval-001
"$MENO" reminders add --title '每月最后一个周五' --schedule '{"kind":"monthly","ordinal":-1,"weekday":5,"time":"17:00"}' --request-id last-friday-001
"$MENO" reminders list --status active --limit 20 --json
"$MENO" reminders history --json
"$MENO" reminders update <id> --in 30m --type fullscreen --json
"$MENO" reminders update <id> --enabled false --json
"$MENO" reminders cancel <id> --json
"$MENO" apps status reminders --json
"$MENO" apps enable reminders --json
"$MENO" apps disable reminders --json
"$MENO" open reminders
"$MENO" open settings
"$MENO" open current-reminder     # 显式聚焦当前全屏提醒，之后 Esc 延期五分钟
"$MENO" notifications request
"$MENO" diagnostics
"$MENO" quit
```

CLI 始终输出 JSON，业务错误写标准错误并使用非零退出码。未传 `--request-id` 时为新写入生成 UUID；脚本重试必须自己提供并复用 ID。`--in`、`--interval` 支持 s/m/h/d；所有时间规则互斥。`--daily`、`--weekdays` 后可直接写逗号分隔的多个时点；自选星期、月、年使用 `--time` 或 `--times`。重复规则可追加 `--every`、`--timezone`、`--start-at`、`--end-at`、`--exclude`；`--schedule` 接受完整 JSON，不能再混用其他时间参数。`--no-launch` 仅探测已运行宿主，不自动启动。`meno call <command> --arguments '<JSON对象>'` 供精确协议调试。

如果把 CLI 复制到 App 之外，设置 `MENO_APP_PATH=/实际位置/Meno.app`，或安装到 `/Applications/Meno.app`。开发／测试可以用 `MENO_DATA_DIR=/私有短路径` 隔离数据，宿主和客户端必须使用同一目录，socket 全路径需少于 104 字节；自动启动会传递此变量。不同数据目录不适合同时运行同 Bundle ID 的真实通知测试，系统通知命名空间仍属于同一个 App。

## 可复现客户端验证

```sh
uv venv --python 3.12 .venv
uv pip sync --python .venv/bin/python --require-hashes scripts/requirements-mcp.lock.txt
# 推荐入口：独立测试 App 和数据，覆盖下方全部非视觉流程及 SIGTERM
.venv/bin/python scripts/integration-test.py
# 单脚本调试会操作所指定 App 的数据及后台状态
.venv/bin/python scripts/mcp-smoke.py --discover-only
.venv/bin/python scripts/mcp-smoke.py --output /tmp/meno-mcp-smoke.json
.venv/bin/python scripts/retry-smoke.py --output /tmp/meno-retry-smoke.json
.venv/bin/python scripts/runtime-smoke.py --output /tmp/meno-runtime-smoke.json
# 额外留下一条 8 秒后的真实全屏提醒，客户端先退出，用于人工验收
.venv/bin/python scripts/mcp-smoke.py --delivery --output /tmp/meno-mcp-delivery.json
```

使用官方 Python MCP SDK 作为真实 stdio 客户端，验证握手、六工具发现、Schema、增查改取消、启停、幂等冲突和当前状态回读。常规 smoke 只取消本轮创建的 ID，并恢复原启用偏好；`--delivery` 会显式启用后台并留下一条真实全屏事项，需要确认或取消。该测试验证 MCP 协议客户端，不等同于已配置某个商业 AI 客户端或已完成模型端自然语言理解验收。

`retry-smoke.py` 真实断开 IPC 响应后用相同参数重试，并启动两个独立 MCP 客户端并发同一请求；`runtime-smoke.py` 验证停用期间不补弹、类型和时间修改、非零错误码、宿主正常退出及自动恢复。这两个脚本只取消自己创建的事项，运行时测试会短暂启停后台并恢复原偏好，请在没有临近重要提醒时运行。
