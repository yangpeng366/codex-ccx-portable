# codex-ccx-portable

Windows 上一键部署 OpenAI Codex CLI + 本地 CCX 代理的启动包。项目分两层：

- 公开包：安装脚本、Codex 配置模板、健康巡检与文档，不含上游 API Key。
- 私有包：由源机器用 `build-portable.ps1 -Private` 生成，额外携带 CCX 可执行文件、CCX 渠道配置、Codex 模型目录和本地代理令牌。

私有包等同凭据，只能通过可信通道分发，不得发布到 GitHub 或对象存储公开桶。

## 交付形态建议

推荐“开源工程 + 私有迁移包”，不推荐直接公开当前完整配置：

| 形态 | 适用 | 结论 |
|---|---|---|
| 只发压缩包 | 临时给可信同事 | 快，但难升级、难审计 |
| 只发开源工程 | 公共维护 | 安全，但新机缺少渠道密钥与二进制 |
| 开源工程 + 私有包 | 可重复部署 | 推荐；公开逻辑与私有凭据分离 |

## 目标机器要求

- Windows 10/11；`bootstrap.ps1` 可自动安装 PowerShell 7、Git 与 Node.js LTS。
- 能访问上游模型服务；本脚本只开放本地 `127.0.0.1:3688`。
- Node.js 22 与 npm 已在 PATH，或可用 `winget` 安装 Codex。
- 若使用私有包，无需手工安装 CCX Desktop；安装器会携带并启动 `ccx-go.exe`。

## 快速开始

在普通 Windows PowerShell 中执行；它会补齐 PowerShell 7、Git、Node.js 并调用主安装器：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\bootstrap.ps1 -RunInstaller
```

若还要安装本机 Nginx 8443 反向代理：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\bootstrap.ps1 -RunInstaller -InstallNginx
```

在源机器生成私有包：

```powershell
pwsh -NoProfile -File .\build-portable.ps1 -Private
```

把生成的 `dist/codex-ccx-portable-private.zip` 拷到新机，解压后执行：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

脚本会完成：

1. 安装 PowerShell 7、Git、Node.js LTS（已存在则跳过）。
2. 安装 Codex CLI；已存在时可传 `-SkipCodexInstall`。
3. 备份并写入 `%USERPROFILE%\.codex\config.toml` 与 `auth.json`。
4. 写入私有模型目录；无私有目录时省略 `model_catalog_json`。
5. 复制 CCX 配置与 `ccx-go.exe` 到用户目录。
6. 注册登录自启任务 `CodexCcxPortable`。
7. 等待 `/health` 返回 healthy，并执行一次 Codex smoke test。

只测服务与请求链路：

```powershell
.\scripts\Test-CcxHealthSnapshot.ps1
pwsh -NoProfile -File .\scripts\Invoke-SmokeTest.ps1
```

## 可选 Nginx

Nginx 不是 CCX 的必选项；只有需要通过本机 8443 反代部分上游时才安装：

```powershell
pwsh -NoProfile -File .\scripts\setup-nginx.ps1
```

默认行为：

- 安装官方 Windows Nginx 到 `%LOCALAPPDATA%\Programs\nginx`。
- 生成仅绑定 `127.0.0.1:8443` 的自签证书。
- 预置 `/minimax/`、`/siliconflow/`、`/stepfun/`、`/qiniu/` 四个反代路由。
- 校验配置，启动或重载，并验证 `https://127.0.0.1:8443/nginx-health` 返回 `ok`。

新增渠道时编辑 `%LOCALAPPDATA%\Programs\nginx\conf\nginx.conf`，保持 `proxy_ssl_server_name on`，然后执行 `nginx -s reload`。

## 安全边界

- 公开仓库只保存模板；默认令牌是占位符。
- `build-portable.ps1 -Private` 会生成非加密 ZIP，其中含上游 API Key，请使用压缩密码、加密网盘或点对点可信通道传输。
- 默认安装继承当前工作站配置：`approval_policy = "never"`、`sandbox_mode = "danger-full-access"`。给不熟悉 Codex 的机器使用时，请显式传：

```powershell
.\install.ps1 -ApprovalPolicy on-request -SandboxMode workspace-write
```

安装器只覆盖 `config.toml`、`auth.json` 和 `ccx-model-catalog.json`，不迁移会话、记忆、日志或 SQLite 状态。
