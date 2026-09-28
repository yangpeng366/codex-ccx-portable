# 部署契约

## 路径

| 项 | 路径 |
|---|---|
| Codex 配置 | `%USERPROFILE%\.codex\config.toml` |
| Codex 凭据 | `%USERPROFILE%\.codex\auth.json` |
| 模型目录 | `%USERPROFILE%\.codex\ccx-model-catalog.json` |
| CCX 服务 | `%LOCALAPPDATA%\Programs\CCX Desktop\ccx-go.exe` |
| CCX 配置 | `%APPDATA%\ccx-desktop\.config\config.json` |
| CCX 日志 | `%APPDATA%\ccx-desktop\logs\app.log` |
| 自启任务 | `CodexCcxPortable` |

## 服务契约

- 进程：`ccx-go`，单实例。
- 本地地址：`http://127.0.0.1:3688`。
- 探活：`GET /health`，要求 `status=healthy`。
- Codex 接口：`POST /v1/responses`，强制 HTTPS+SSE，不使用 WebSocket。
- 浏览接口：`GET /v1/models`。

## Codex 关键约束

1. `supports_websockets = false` 必须保留；否则先走 WSS，容易造成超时。
2. `experimental_bearer_token` 与 CCX 本地入口令牌保持一致，并同步写入 `auth.json` 的 `OPENAI_API_KEY`。
3. 当前稳定参数为 262K 上下文、200K 自动压缩阈值；不要直接恢复旧 500K 配置。
4. 所有上游渠道密钥保存在 CCX `config.json`；不要把该文件放进公开仓库。

## 新机排障

1. `/health` 不通：确认 `ccx-go` 进程与 3688 端口；冷启动最长可等待约一分钟。
2. Codex 认证失败：比对 `auth.json` 与 `config.toml` 中的本地令牌。
3. `stream_stalled`：先将 `stream_idle_timeout_ms` 从 120000 提到 180000，再看 CCX 日志是否有上游补发终止符。
4. 渠道 JSON 启动失败：`apiKeys` 必须是数组，不能写字符串。
5. 想秒启：让渠道先以 `suspended` 冷启动，再改 `active` 热重载。
