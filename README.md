# Meno

一个常驻 macOS 菜单栏的本地功能宿主。首个子应用「到点提醒」支持单次、每天、周一至周五提醒，每条事项独立选择系统通知或全屏提醒。关闭窗口不停止后台；暂停后台后仍可查看、编辑、保存，窗口会明确提示没有进入提醒调度。Meno 不包含 AI，不需要模型或密钥。

默认使用与全屏提醒相近的中性烟灰背景、浅色文字和原生液态玻璃，仍可在设置中选择明亮或跟随系统。窗口有独立背景，不会透出其他应用的文字。

## 构建与运行

运行需要 macOS 14+；构建需要 Xcode 26+（包含 macOS 26 SDK）及命令行工具，首次构建需下载锁定的 SwiftPM 依赖。macOS 26+ 使用原生液态玻璃；旧系统及开启“降低透明度”时提供清晰的回退界面。

```sh
scripts/test.sh
scripts/build.sh                    # Release，默认本地 ad-hoc 签名
open dist/Meno.app
# 可选：安装到当前用户的 Applications，保留既有安装的副本
scripts/install.sh
```

完整工程验证还包括真实协议和进程集成测试，使用独立测试 App 标识与临时数据，不修改日常 Meno 数据：

```sh
python3.12 -m venv .venv
.venv/bin/python -m pip install --require-hashes -r scripts/requirements-mcp.lock.txt
make integration
make verify
```

GitHub Actions 在 Apple Silicon 与 Intel 上执行检查、测试、Release 打包和隔离集成测试，输出日志、ZIP 与 SHA256SUMS。常用入口见 [开发约定](CONTRIBUTING.md)，安装恢复、分发与手工验收见 [发布与维护](docs/发布与维护.md)。CI 安装包为本地开发签名，未进行分发公证。

如需本机开发证书签名，执行 `MENO_SIGN_IDENTITY='<签名证书名称或 SHA-1>' scripts/build.sh`。构建输出包括 `dist/Meno.app`、`dist/Meno.zip` 和依赖、源文件摘要、签名信息所在的 `dist/build-info.json`。更换正在运行的构建前先执行 `dist/Meno.app/Contents/Helpers/meno quit`，正常退出会取消待触发任务并保存启用偏好。

首次启动只出现菜单栏图标，点击图标中的「到点提醒」打开独立窗口，右侧开关只控制后台。快速创建输入内容、点选时间、选择提醒类型后按回车；展开区域提供精确时间、重复和备注，列表支持编辑、暂停、取消及历史。默认全局快捷键是 **⌃⌥⇧M**，设置中可以更改或关闭，注册冲突时会提示。系统通知需要在设置页主动请求授权，全屏提醒不依赖此权限。

## 外部接入

标准 MCP 使用官方 [MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk/tree/0.12.1)，版本精确锁定为 0.12.1，随 App 提供 stdio 辅助程序 `Contents/Helpers/meno-mcp`；CLI 为 `Contents/Helpers/meno`。两者通过仅限当前用户的 Unix socket 调用唯一宿主，客户端退出不影响已启用的提醒。

```sh
dist/Meno.app/Contents/Helpers/meno reminders add --title '喝水' --in 20m --type fullscreen --enable-plugin --json
dist/Meno.app/Contents/Helpers/meno apps status reminders --json
```

完整配置、参数、回执和重试规则见 [MCP 与 CLI 接入](docs/MCP与CLI.md)，模块边界、数据迁移和恢复策略见 [开发说明](docs/开发说明.md)，真实运行证据及未覆盖环境见 [首版验收](docs/验收结果.md)。交接和设计原文保留在 `docs/`。
