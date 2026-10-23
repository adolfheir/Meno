# 开发与验证

使用 macOS 14+ 运行，使用带 macOS 26 SDK 的 Xcode 26+ 构建；CI 固定 Xcode 26.6。本机测试工具需要 Python 3.12，业务 App 本身不需要 Python。打开根目录 Package.swift 可在 Xcode 中开发，运行真实通知与菜单栏行为请使用打包后的 App。

```sh
make test
make build
python3.12 -m venv .venv
.venv/bin/python -m pip install --require-hashes -r scripts/requirements-mcp.lock.txt
make integration
make verify
```

`make test` 包含脚本语法、版本和依赖锁检查、四个 Swift package 测试及全部可执行入口构建。`make integration` 复制当前产物到本次创建的临时目录，使用独立 Bundle ID、通知命名空间和数据目录，关闭测试副本的全局快捷键，验证后正常退出并清理本轮临时目录。失败日志留在 test-results；退出失败时保留临时 App 和数据供排查。无需停用日常 Meno，也不会改动日常提醒。

界面、CLI、MCP 共用业务服务；新增输入必须在业务层校验，写入与幂等记录保持同一事务。改调度、恢复、持久化或 IPC 时增加能够证明行为的测试；不要用 mock 结果替代真实通知送达或桌面验收。修改版本时同步 Info.plist、CLI、MCP、模块 descriptor 和 diagnostics；源码检查会核对公开入口版本。

Swift 远端依赖使用根目录 Package.resolved；升级后执行完整测试和集成套件。Python 测试依赖入口为 scripts/requirements-mcp.txt，使用 `uv pip compile scripts/requirements-mcp.txt --python-version 3.12 --generate-hashes --no-header --output-file scripts/requirements-mcp.lock.txt` 更新完整锁文件，再验证 Python 3.12 环境。GitHub Actions 依赖锁定 commit，由 Dependabot 提交更新建议；依赖更新不会自动合并。

分支使用 codex/ 前缀；提交应说明实际变化和验证范围。请保留原需求、参考图与既有数据。不要提交构建目录、私有数据、密钥或签名证书。发布及兼容性边界见 [发布与维护](docs/发布与维护.md)。
