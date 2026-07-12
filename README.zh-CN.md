# Codex Provider Compatibility

一个在本机运行、可回滚的 Codex 自定义 provider 兼容补丁。它解决三个目标模型在 Responses Lite 模式下无法向普通 OpenAI-compatible provider 正确暴露标准工具定义的问题。

[English](README.md) · [自动测试](https://github.com/Hyacehila/codex-provider-compat/actions/workflows/test.yml)

> 本项目是非官方社区工具，不是 OpenAI 产品，也不代表 OpenAI 或任何 API provider。

最短流程：`下载并校验 -> doctor -> apply -> 完全重启 Codex -> 新建任务`。

## 如何使用

### 先判断是否适用

如果下面大部分情况都符合，先运行 `doctor`：

- 当前模型是 `gpt-5.6-sol`、`gpt-5.6-terra` 或 `gpt-5.6-luna`；
- 使用 `wire_api = "responses"` 的自定义 provider；
- 普通文本正常，但 exec/shell、code mode、function/MCP、collaboration namespace、扩展工具或 Web Search 不可见；
- 同一个 provider 换成非 Lite 模型后正常；
- provider 支持公开 Responses API 的标准顶层工具定义。

如果 provider 只接受 Responses Lite、不支持所需的标准 Responses 工具，或当前模型不在三个目标中，请不要应用补丁。`doctor` 是只读命令；无法安全判断时，工具会停止而不改配置。

普通用户不需要抓包、手工调用 API、研究 provider 协议或编辑 JSON/TOML。

### 下载并校验 v0.1.0

从 [v0.1.0 Release 页面](https://github.com/Hyacehila/codex-provider-compat/releases/tag/v0.1.0) 下载对应平台的压缩包和 `SHA256SUMS.txt`：

- Windows：`codex-provider-compat-v0.1.0-windows.zip`
- macOS：`codex-provider-compat-v0.1.0-macos.zip`

Release 还提供方便审阅的独立脚本：

- `codex-provider-compat.ps1`
- `codex-provider-compat.sh`

Windows 校验：

```powershell
(Get-FileHash .\codex-provider-compat-v0.1.0-windows.zip -Algorithm SHA256).Hash.ToLowerInvariant()
Get-Content .\SHA256SUMS.txt
```

macOS 校验：

```sh
shasum -a 256 ./codex-provider-compat-v0.1.0-macos.zip
cat ./SHA256SUMS.txt
```

确认计算结果与 `SHA256SUMS.txt` 中对应文件一致，再解压并查看脚本。不要使用看不到下载内容的 `curl | sh` 或 `irm | iex` 管道。

### Windows

支持 Windows PowerShell 5.1 和 PowerShell 7.5 及以上版本，不需要 Python、Node、`jq`、Chocolatey 或 Scoop。

在解压后的目录中运行：

```powershell
Get-Content .\codex-provider-compat.ps1
.\codex-provider-compat.ps1 doctor
.\codex-provider-compat.ps1 apply
```

如果已经核对哈希并审阅脚本，但 Windows PowerShell 仍因执行策略阻止它，可以使用只对当前进程生效的方式：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\codex-provider-compat.ps1 doctor
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\codex-provider-compat.ps1 apply
```

### macOS

脚本只使用 macOS 自带的 shell 和系统工具，包括 `curl`、`awk`、`shasum` 与 `osascript -l JavaScript`，不需要 Homebrew、Python、Node 或 `jq`。

在解压后的目录中运行：

```sh
less ./codex-provider-compat.sh
chmod +x ./codex-provider-compat.sh
./codex-provider-compat.sh doctor
./codex-provider-compat.sh apply
```

### 应用后

```text
完全退出并重新启动 Codex，然后新建任务。
旧任务保留启动时的模型与工具快照，不会自动应用本次更改。
```

如果还希望启用 hosted Web Search，可以在确认 provider 支持标准 Responses `web_search` 后显式运行：

```powershell
.\codex-provider-compat.ps1 apply --enable-web-search
```

```sh
./codex-provider-compat.sh apply --enable-web-search
```

搜索可能由 provider 收费。Web Search 可用不代表 exec、MCP、code mode 或图片工具也一定可用。

### 检查和回滚

检查补丁状态：

```powershell
.\codex-provider-compat.ps1 status
```

```sh
./codex-provider-compat.sh status
```

完整回滚：

```powershell
.\codex-provider-compat.ps1 rollback
```

```sh
./codex-provider-compat.sh rollback
```

rollback 只恢复本工具拥有的配置键，不覆盖 apply 后用户新增的其他配置。生成 catalog 只有在内容和状态记录一致时才会清理；原 cache 路径已有新文件时不会覆盖。

rollback 后也要完全退出并重新启动 Codex，然后新建任务。

如果 `doctor` 或 `status` 报告 `recovery-required`，不要手工删除 transaction、lock 或 pending 文件。直接再次运行计划中的 `apply` 或 `rollback`；工具会先恢复被中断的事务。路径或状态不安全时会以退出码 3 停止。

### 命令、参数和退出码

| 命令 | 作用 |
|---|---|
| `doctor` | 只读检查环境、版本、配置和适用性 |
| `apply` | 校验、备份并应用补丁 |
| `status` | 检查 catalog、配置、版本和事务状态 |
| `rollback` | 精确撤销本工具拥有的修改 |

两个平台使用相同的公共参数：

```text
--yes
--dry-run
--codex-home <absolute-path>
--codex-version <version>
--catalog-file <absolute-path>
--enable-web-search
```

通常不需要指定 Codex home 或版本。脚本依次使用 `--codex-home`、`CODEX_HOME` 和 `~/.codex`，并自动发现 Codex 版本。发现不同版本时默认停止，由用户审核后再使用 `--codex-version`。`--catalog-file` 只作为经过审阅的完整离线 catalog 输入，不会成为写入目标。

| 退出码 | 含义 |
|---:|---|
| 0 | 成功或状态健康 |
| 1 | 一般用法或操作错误 |
| 2 | 不适用、未安装或官方修复已存在 |
| 3 | 不安全、歧义、损坏、漂移或需要恢复 |
| 4 | 当前版本的补丁或 catalog schema 已过期 |
| 5 | 官方 catalog 下载、HTTP、超时或大小错误 |

自动化应读取退出码，不要解析自然语言输出。

### 文件、更新和常见问题

所有持久 Codex 更改都限制在所选 Codex home 内。macOS 脚本还会在系统临时目录创建权限为 0700 的私有工作区，用于下载和分析，并在退出时清理。Codex home 内的持久路径如下：

```text
config.toml
config.toml.bak-provider-compat-YYYYMMDD-HHMMSS[.N]
model-catalogs/models-<version>.standard-responses-compat.json
models_cache.json.bak-provider-compat-YYYYMMDD-HHMMSS[.N]
provider-compat-state.json
provider-compat-state.json.rolled-back-YYYYMMDD-HHMMSS[.N]
provider-compat-transaction.json                  # 仅在写入或恢复期间
provider-compat.lock 或 provider-compat.lock.d/  # 仅在写入期间
```

工具不会删除 apply 前已经存在的 config，也不会删除 cache 数据。如果 apply 前没有 config，并且之后没有加入无关用户内容，rollback 会移除本工具创建的 config，以恢复原先不存在的状态。完整 config backup 是紧急人工恢复副本；正常 rollback 使用状态记录精确编辑 owned key。无法证明目标路径、文件所有权或配置形式安全时，操作会停止且不产生持久 Codex 更改。

Codex 升级后先运行 `status` 和 `doctor`。旧 catalog 是完整目录覆盖，继续使用可能隐藏新模型或保留过期能力信息。回滚旧版本补丁后，再为审核过的新版本运行 `apply`。如果官方 catalog 已经把三个目标全部改为非 Lite，`apply` 会返回 2，不再创建 override。

`status = healthy` 只说明工具拥有的用户级文件彼此一致。选中的 `$CODEX_HOME/<profile>.config.toml`、项目配置或 CLI/session override 仍可能改变某个任务的有效配置。

补丁成功但工具仍不可用，通常说明 provider 不支持对应的标准 Responses 工具。此时直接 rollback；用户不需要修改 provider、base URL、header 或服务端。

## 工作原理

### 根因

对 Codex `0.144.1` 的官方 catalog 和请求形态验证表明，三个目标模型被标记为 `use_responses_lite = true`：

```text
Lite catalog 标记
    -> Codex 使用内部 additional_tools
    -> 标准顶层 tools 缺失或为 null
    -> 普通 OpenAI-compatible provider 看不到标准工具定义

本补丁把三个目标模型设为非 Lite
    -> Codex 恢复标准 Responses 顶层 tools
    -> provider 可以处理它实际支持的工具
```

Lite 模式还会改变顶层 `instructions`、parallel tool calls、reasoning context、图片 detail 和内部 header/metadata。禁用 Lite 改变的是整个请求形态，不只是 Web Search。

Web Search 有额外的双路径问题：Lite 规划会跳过 hosted `web_search`，独立 `web/run` 扩展又受 provider 身份限制。因此搜索是重要验收场景，但本项目处理的是 provider 与 Responses 请求形态的整体兼容。

非 Lite 模型通常正常，因为 Codex 会发送标准顶层工具定义。官方 OpenAI/ChatGPT 链路通常不同，因为其后端和授权扩展理解 Codex 使用的 Lite 协议。

### 补丁做了什么

首个补丁 ID 是 `responses-lite-standard-tools`。脚本会：

1. 自动发现 Codex home 以及 CLI、Desktop、app-server 版本，版本冲突时安全停止；
2. 从严格匹配的官方 `rust-v<version>` tag 下载完整 catalog，或读取用户提供的完整离线 catalog；
3. 只把 `gpt-5.6-sol`、`gpt-5.6-terra` 和 `gpt-5.6-luna` 的 `use_responses_lite` 改为 `false`，并验证没有其他语义差异；
4. 原子写入生成 catalog，把用户级 `model_catalog_json` 指向它，备份 config 和 cache，并记录支持 `status`、恢复和 rollback 的最小状态。

只有显式使用 `--enable-web-search` 时，脚本才会额外设置用户级 `web_search = "live"`。它不会修改 `model`、`model_provider`、provider table 或其他配置。

### 安全边界

- catalog 必须完整、结构有效且 slug 唯一；在线下载只接受严格匹配的 Codex 官方 tag，离线文件只作为经过审阅的只读输入；下载、schema 或目标校验失败时不会碰 config 和 cache；
- 修改前后及重新序列化后都会做递归语义比较，允许的差异只有三个固定布尔值；
- TOML 编辑器保留注释、section、BOM、LF/CRLF、尾随换行、无关文本和权限；重复、dotted 或无法无损编辑的 owned key 会安全停止；
- 写操作使用锁、同目录原子替换和事务日志；apply/rollback 失败或被中断后可以恢复；
- 写路径从 Codex home 和固定命名规则重新构造，拒绝 Windows junction/reparse point 与 macOS 非系统 symlink 逃逸；
- `doctor` 和 `status` 保持只读。

本工具不修改、替换或注入 Codex CLI、Desktop、app-server、二进制或源码；不修改 OpenAI/Codex 服务端或第三方 provider；不运行 API 中转、远程修复服务或密钥托管服务。

### 能力边界和验证范围

补丁只能恢复标准工具定义，不能让 provider 实现它本来不支持的 exec、MCP、hosted search、图片能力或计费行为。只接受 Responses Lite 的 provider 可能在应用后失败。

自动测试覆盖 Windows PowerShell 5.1/7 生命周期、macOS shell/JXA 文件语义、完整 catalog、TOML 保真、路径逃逸、故障恢复，以及固定 Codex CLI 到 localhost mock Responses server 的 Lite/标准请求形态。测试不读取真实凭据，也不会向真实 provider 发起付费请求。

localhost mock 证明请求形态，不代表所有真实 provider 都兼容。v0.1.0 明确将以下项目标记为 `not-run`：macOS Codex CLI/Desktop 集成；真实 provider 上的 hosted Web Search、exec/shell、function/collaboration、code mode、MCP/dynamic tools 和图片工具执行；多轮历史；图片输入 detail。每个发布提交的 [GitHub Actions](https://github.com/Hyacehila/codex-provider-compat/actions/workflows/test.yml) 是自动测试结果来源。

### 隐私和许可证

工具不读取 `auth.json` 或 API Key，不访问 provider API，不上传 config、日志或诊断数据，也没有遥测。state/transaction 只保存恢复所需的最小补丁、路径、哈希、阶段和 owned key 元数据，不保存完整 config、凭据或 API 请求。

脚本使用 [MIT License](LICENSE)。运行时下载的官方完整 catalog 来自 Apache-2.0 的 [`openai/codex`](https://github.com/openai/codex) 仓库，详见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
