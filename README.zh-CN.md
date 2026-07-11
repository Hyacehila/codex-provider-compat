# Codex Provider Compatibility

这是一个非官方、在本机运行、可以完整回滚的 Codex 自定义 provider 兼容补丁。它面向这样的情况：provider 支持标准 Responses 顶层工具定义，但不支持 Codex 内部的 Responses Lite `additional_tools` 协议。

[English](README.md)

> 本项目是社区工具，不是 OpenAI 产品，也不代表 OpenAI 或任何 API provider。

## 30 秒判断是否适用

如果下面大部分情况都符合，先运行 `doctor`：

- 当前模型是 `gpt-5.6-sol`、`gpt-5.6-terra` 或 `gpt-5.6-luna`；
- 使用 `wire_api = "responses"` 的普通自定义 provider；
- 普通文本正常，但 exec/shell、code mode、function/MCP、collaboration namespace、扩展工具或 Web Search 消失；
- 同一个 provider 换成非 Lite 模型后正常；
- provider 能处理公开 Responses API 的顶层工具定义。

普通用户的流程只有：

```text
运行脚本 -> 完全重启 Codex -> 新建任务
```

不需要抓包、手工请求 API、研究 `additional_tools`，也不需要手改 JSON/TOML。如果脚本无法证明某个操作安全，它会保持当前有效配置不变并停止。

如果 provider 只接受 Responses Lite、不支持相关标准 Responses 工具、当前模型不在三个目标中，或者官方 catalog 已经包含修复，就不应应用这个补丁。

## 症状和根因

对 Codex `0.144.1` 的官方 catalog 和请求形态复核表明，三个目标模型被标记为 `use_responses_lite = true`。Lite 模式会把客户端工具序列化为内部 `additional_tools` 输入项，省略标准顶层 `tools` 和 `instructions`，改变 parallel/reasoning/图片请求细节，并在规划时跳过 hosted Responses 工具。普通兼容 provider 可能完整实现公开 Responses API，却没有实现这套 Codex 内部协议。

Web Search 还有一层“双路径失效”：Lite 规划跳过 hosted `web_search`，独立 `web/run` 扩展又只向官方 OpenAI provider 或使用 OpenAI Actor Authorization 的 provider 注册。因此 Web Search 是重要验收场景，但仓库解决的是整类 provider/Responses 请求形态兼容，不是只改一个搜索开关。

非 Lite 模型通常正常，是因为 Codex 会发送标准顶层工具定义。官方 OpenAI/ChatGPT 链路不同，其后端和授权扩展理解 Codex 预期的 Lite 协议。

## 工具会做什么

首个补丁 ID：`responses-lite-standard-tools`

脚本会：

1. 发现 Codex home 和 CLI/Desktop/app-server 版本；
2. 版本冲突时停止，除非显式指定并审核 `--codex-version`；
3. 从严格匹配的官方 `rust-v<version>` tag 读取完整 catalog，或校验用户提供的离线文件；
4. 要求至少 8 个唯一模型，其中至少 5 个是非目标模型，并检查三个目标和布尔字段类型；
5. 只把三个目标的 `use_responses_lite` 改为 `false`，随后递归比较原对象、修改对象和重新序列化解析后的语义差异；
6. 原子写入 `model-catalogs/models-<version>.standard-responses-compat.json`；
7. 备份并只编辑用户级 `model_catalog_json`；只有显式传入参数时才设置 `web_search = "live"`；
8. 对 `models_cache.json` 只改名备份，不直接删除；
9. 用小型状态文件记录哈希和文件所有权，供 `status` 和精确 rollback 使用；
10. 对 apply/rollback 的每一个写阶段记录事务，发生中断后可在下一次写命令前恢复。

所有写路径都从所选 Codex home 重新构造。Windows 会拒绝已有的 junction/reparse point 组件；macOS 会先把 Apple 固定的 `/var`、`/tmp`、`/etc` 别名规范化到 `/private/...`，再拒绝其他 symlink 组件。rollback 不会把状态文件当成任意文件操作清单，而会重新计算预期路径，并严格检查 backup/archive 文件名。

TOML 编辑器使用词法扫描，而不是逐行正则。它能区分注释、table、数组、inline table、quoted key 和四种 TOML 字符串，同时保留 BOM、LF/CRLF、尾随换行、注释、section 顺序、无关内容和原权限。遇到 dotted、重复、复杂或无法无损编辑的 owned key 时会安全停止，不做猜测。

## 工具不会做什么

它不会修改、替换或注入 Codex CLI、Desktop、app-server、二进制或源码；不会修改 OpenAI/Codex 服务端或第三方 provider；不会运行 API 中转、托管密钥或远程修复服务；不会读取 `auth.json`；不会访问真实 provider API；不会上传配置、日志或诊断信息；也没有遥测。

## 当前源码安装方式

这个仓库当前不发布 tag 或 GitHub Release。任何声称已经存在 Release 压缩包或 `SHA256SUMS` 的安装说明都不准确。

源码仓库：<https://github.com/Hyacehila/codex-provider-compat>

当前源码交付建议：

1. 在 GitHub 上选择一个 Actions 已通过的明确 commit；
2. 下载该 commit 对应的 ZIP，或 clone 后 checkout 到这个 commit，不要只依赖会继续移动的分支名；
3. 计算并保存对应平台脚本的 SHA-256；
4. 打开脚本阅读后再执行；
5. 先运行 `doctor`，再运行 `apply`。

例如：

```text
git clone https://github.com/Hyacehila/codex-provider-compat.git
cd codex-provider-compat
git checkout <reviewed-commit>
git rev-parse HEAD
```

不要使用看不见内容的 `curl | sh` 或 `irm | iex` 一键管道。

Windows 检查：

```powershell
Get-FileHash .\codex-provider-compat.ps1 -Algorithm SHA256
Get-Content .\codex-provider-compat.ps1
```

macOS 检查：

```sh
shasum -a 256 ./codex-provider-compat.sh
less ./codex-provider-compat.sh
chmod +x ./codex-provider-compat.sh
```

未来正式发布 GitHub Release 时，必须先提供稳定产物和独立校验和，README 才会把 Releases 改成主要安装入口。

## Windows

支持 Windows PowerShell 5.1 和 PowerShell 7.5 及以上版本。普通用户不需要 Python、Node、`jq`、Chocolatey 或 Scoop。

```powershell
.\codex-provider-compat.ps1 doctor
.\codex-provider-compat.ps1 apply
```

如果已经核对哈希并审阅脚本，但 Windows PowerShell 仍阻止下载的脚本，
可以使用只对当前进程生效的执行策略；它不会修改系统级或用户级策略：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\codex-provider-compat.ps1 doctor
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\codex-provider-compat.ps1 apply
```

已经审阅脚本、需要非交互执行时：

```powershell
.\codex-provider-compat.ps1 apply --yes
```

## macOS

脚本只使用系统 shell、`curl`、`awk`、`shasum` 和 `osascript -l JavaScript`。

```sh
./codex-provider-compat.sh doctor
./codex-provider-compat.sh apply
```

已经审阅脚本、需要非交互执行时：

```sh
./codex-provider-compat.sh apply --yes
```

apply 成功后，请完全退出所有 Codex CLI/Desktop/app-server 进程，重新启动 Codex，并新建任务。旧任务会继续使用启动时保存的模型和工具快照，不会热加载这次修改。

## 命令、参数和退出码

两个平台提供相同的四个命令：

- `doctor`：只读检查环境、版本、config、catalog、profile override 和风险；不会写 Codex home；
- `apply`：校验、确认、备份、原子应用并写状态；
- `status`：重新解析 catalog，检查三个目标、其他 Lite 模型、哈希、config 指向、可选 Web Search、版本漂移和恢复状态；
- `rollback`：以事务方式只恢复工具拥有的键，并安全恢复或保留 cache。

公共参数：

```text
--yes
--dry-run
--codex-home <absolute-path>
--codex-version <version>
--catalog-file <absolute-path>
--enable-web-search
```

`--catalog-file` 是只读离线输入，可以位于 Codex home 外，但仍必须是完整 catalog。`--enable-web-search` 可能产生计费搜索；provider 必须支持对应的标准 Responses hosted 工具。

| 退出码 | 含义 |
|---:|---|
| 0 | 成功或状态健康 |
| 1 | 一般用法或操作错误 |
| 2 | 不适用、未安装或官方修复已存在 |
| 3 | 不安全、歧义、损坏、漂移或需要恢复 |
| 4 | 当前 Codex 版本的补丁/catalog schema 已过期 |
| 5 | 官方 catalog 的网络、HTTP、超时或大小错误 |

自动化程序应使用退出码，不要解析自然语言输出。

## 会修改哪些文件

所有写入都位于所选 Codex home 内：显式 `--codex-home` 优先，其次 `CODEX_HOME`，最后 `~/.codex`。

```text
config.toml
config.toml.bak-provider-compat-YYYYMMDD-HHMMSS[.N]
model-catalogs/models-<version>.standard-responses-compat.json
models_cache.json.bak-provider-compat-YYYYMMDD-HHMMSS[.N]
provider-compat-state.json
provider-compat-state.json.rolled-back-YYYYMMDD-HHMMSS[.N]
provider-compat-transaction.json                  # 只在写入/恢复期间存在
provider-compat.lock 或 provider-compat.lock.d/  # 只在写入期间存在
```

如果进程被强制终止，可能留下带 nonce 的临时/pending 文件。工具会根据 transaction 中记录的固定目标路径与 nonce 精确重建其名称和路径，由下一次 `apply` 或 `rollback` 恢复；`doctor` 和 `status` 保持只读，只报告 `recovery-required`。

完整 config backup 只用于紧急人工恢复。正常 rollback 只编辑 `model_catalog_json`，以及工具确实拥有的 `web_search` 修改，所以 apply 后用户新增的其他配置会保留。如果 apply 前没有 config，rollback 会恢复为文件不存在，而不是留下空文件。

## 风险与 Codex 更新

- `model_catalog_json` 会替换新进程使用的完整模型目录；catalog 过期可能隐藏新模型或保留过期能力信息。
- 禁用 Lite 会改变整个请求协议，不只是 Web Search：instructions、顶层工具、parallel calls、reasoning context、图片 detail、内部 header/metadata 和历史表示都可能变化。
- 只接受 Responses Lite 的 provider 可能在应用补丁后失败。
- 补丁只能恢复标准工具定义，不能让 provider 凭空实现它不支持的工具、hosted search、图片能力或计费行为。
- 选中的 `$CODEX_HOME/<profile>.config.toml`、项目配置层或 CLI/session override 可能覆盖用户级 catalog。`doctor` 会报告能发现的 profile 文件，但无法推断每一次运行时选择。`status` 显示 healthy 只证明工具拥有的用户级文件彼此一致，不证明某个具体任务没有被更高优先级配置覆盖。
- `model_provider = "openai"` 通常表示内置 OpenAI provider，但 `openai_base_url` 或自定义 provider 定义可以重定向这个 ID。此时不能只凭 ID 判断后端支持 Responses Lite，应结合实际 override 和症状判断是否适用。
- 一个用户 catalog 可能影响多个 Codex surface。CLI 和 Desktop/app-server 版本不一致时，apply 默认停止，必须显式审核版本。
- 旧任务不会热加载 catalog，必须重启并新建任务。

Codex 更新后先运行 `status` 和 `doctor`，回滚旧 override，再为经过审核的新版本应用新 catalog。如果官方 catalog 已经把三个目标全部设为非 Lite，apply 会以退出码 2 结束且不创建 override。官方修复后应 rollback、重启并新建任务。

## 回滚与中断恢复

```powershell
.\codex-provider-compat.ps1 rollback --yes
```

```sh
./codex-provider-compat.sh rollback --yes
```

rollback 不会覆盖 apply 后由用户改动过的 owned key。只有生成 catalog 的内容、哈希和状态所有权一致时才清理它；cache 原路径已有新文件时绝不覆盖。

如果 `doctor` 或 `status` 报告 `recovery-required`，不要手工删除 journal 或移动文件。直接运行原本计划的 `apply` 或 `rollback`；脚本获得锁后会先恢复中断事务，再开始新操作。如果 journal 被篡改或包含不安全路径，会以退出码 3 停止。

## 故障排查

- 退出码 3 且发现多个版本：把 CLI/Desktop 更新到同一版本，或显式传入已审核的 `--codex-version`。
- 退出码 3 且 owned key 歧义：只有真正理解 config 时才消除重复/dotted/复杂形式；工具不会猜。
- 退出码 4：补丁不再匹配官方 catalog schema 或目标，不要用手写最小 catalog 强行继续。
- 退出码 5：严格匹配的官方 tag/catalog 无法安全下载。可以重试，或下载并检查该 tag 的完整 `models.json` 后使用 `--catalog-file`。
- 补丁应用成功但工具仍失败：provider 可能不支持对应的标准 Responses 工具。请 rollback；普通用户不需要修改 provider 或继续研究协议。
- Web Search 正常但其他能力失败：各能力相互独立。一次搜索成功不能证明 exec、MCP、code mode 或图片工具都正常。

## 测试与能力矩阵

所有写操作测试套件都设计为使用临时 Codex home，并比较测试前后的真实 home。workflow 会分别在 Windows PowerShell 5.1 和 PowerShell 7.5 及以上版本下运行 Windows 生命周期套件，运行固定 Codex 请求形态门禁，并由 `macos-latest` 执行完整 shell/JXA 生命周期。Windows 本地对 macOS 只能准确声称通过 `sh -n`；JXA 和 macOS 文件语义不能作为本地已通过项目。每个明确 commit 的 GitHub Actions 结果才是最终通过与否的权威记录。

`macos-latest` 只验证脚本、JXA 和文件语义，不会启动或操作 Codex Desktop；macOS Desktop 集成仍是 `not-run`，需要另行受控人工验证。

请求形态 job 只在 CI 中安装 Codex CLI `0.144.1`，并把配置的模型请求指向 localhost mock Responses server。子进程会清除 OpenAI/Codex/ChatGPT/Azure OpenAI 凭据和代理变量。该测试证明的是捕获到的模型请求结构以及本地错误路径会被拒绝；它不是操作系统级网络监控，不能证明不存在任何静默远程 socket。Node 只用于 CI 安装固定 CLI，不是用户依赖。

请求形态门禁验证 Lite 和补丁后的请求结构，不代表某一家真实 provider 的执行结果。它不会产生付费请求，也不会证明未知 provider 的全部能力。

| 能力 | 结果 | 证据 |
|---|---|---|
| 完整 catalog 与只修改三个目标 | passed | Windows fixtures、递归语义比较、官方 catalog 生命周期 |
| config 注释、section、BOM、换行、无关字节 | passed | Windows 词法编辑 fixtures；macOS 行为由 CI 验证 |
| 路径所有权、junction 逃逸、事务恢复 | passed | Windows 故障/终止注入；macOS symlink/信号行为由 CI 验证 |
| apply/status/rollback 生命周期 | passed | 临时 home 和官方 catalog fixtures |
| macOS shell/JXA 生命周期 | passed | CI：`macos-latest`；Windows 本地只做 `sh -n`，JXA/文件语义 not-run |
| macOS Desktop 集成 | not-run | `macos-latest` 只验证脚本/JXA/文件语义，不启动 Codex Desktop |
| hosted Web Search 定义 | passed | mock：localhost 请求形态捕获；真实 provider：not-run |
| exec/shell 定义 | passed | mock：localhost 请求形态捕获；真实 provider 执行：not-run |
| 普通 function 定义 | passed | mock：localhost 请求形态捕获；真实执行：not-run |
| collaboration namespace | passed | mock：localhost 请求形态捕获；真实执行：not-run |
| Lite header、instructions、parallel、reasoning context | passed | mock：Lite/标准 localhost 请求断言 |
| code mode 实际执行 | not-run | 没有独立 code-mode fixture，也未连接真实 provider 执行 |
| MCP 和 dynamic tools 实际执行 | not-run | v0.1 未连接真实 MCP/provider |
| image generation/extension tools | not-run | v0.1 未连接真实 provider |
| 普通文本响应 | passed | mock：Codex 消费 localhost Responses completion |
| 多轮历史 | not-run | 需要独立受控会话 fixture |
| 图片输入/detail 语义 | not-run | 已知源码差异，尚未加入请求 fixture |

每个 commit 的 GitHub Actions 结果才是云端验证事实。fixture 或 mock 通过不能解释为所有 provider 都兼容。

## 上游状态

这里记录的是带时间的上游复核快照，不是对未来 `main` 的承诺。截至 2026-07-11 21:22:20 UTC（Asia/Shanghai 2026-07-12 05:22:20），最新正式 release 是 `rust-v0.144.1`（7 月 9 日发布），复核的 main commit 是 `9e552e9d15ba52bed7077d5357f3e18e330f8f38`（提交时间为 2026-07-11 21:03:12 UTC）。两者当时仍保留三个 Lite 标记和相关 Lite 请求行为；复核的 main catalog 包含 8 个模型，只有三个补丁目标是 Lite。以下直接相关 Issue 当时均为 open：

- [#31894](https://github.com/openai/codex/issues/31894)
- [#31875](https://github.com/openai/codex/issues/31875)
- [#31870](https://github.com/openai/codex/issues/31870)
- [#31882](https://github.com/openai/codex/issues/31882)
- [#31864](https://github.com/openai/codex/issues/31864)
- [#32086](https://github.com/openai/codex/issues/32086)
- [#32101](https://github.com/openai/codex/issues/32101)

在该快照中，`#32119` 已关闭，但处理的是自定义 provider 的远程模型刷新，不是 Lite 工具协议。历史材料引用 `#31853` 和 `#31872` 是编号错误：它们属于无关内容，不再作为证据。

官方[配置参考](https://learn.chatgpt.com/docs/config-file/config-reference#configtoml)确认用户配置位于 `~/.codex/config.toml`，`model_catalog_json` 在启动时加载，选中的 profile 可以覆盖它。上游源码和 Issue 只用于研究和测试，本工具不会修改或重编译 Codex。

## 参与贡献

欢迎提交 Issue 和 Pull Request。报告问题前请先运行 `doctor`，并且只提供操作系统、Codex 版本来源、执行命令、退出码和经过脱敏的诊断结论。不要公开 `auth.json`、API Key、Authorization header、完整 config，或可能含 secret 的 provider URL。任何改动都必须保持“仅修改本机 Codex home”的交付边界，确保两个平台的四个公共命令兼容，并为安全、事务或 rollback 行为的变化补充针对性测试。

## 隐私、许可证和项目边界

工具不会上传 secret、provider 请求、完整 config 或诊断数据。state/transaction 只保存恢复所需的最小补丁与回滚元数据，例如经过校验的 owned path、哈希、阶段、nonce、版本、时间、动作标记和 owned key 的原值；不记录凭据、API 请求或完整配置。

脚本使用 MIT License。官方 catalog 来自 Apache-2.0 的 `openai/codex` 仓库，详见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

未来补丁仍必须保持本地、窄范围、可检测、强校验和可回滚。本仓库不是 Codex fork、二进制补丁、通用插件框架、provider 代理、远程修复服务或密钥托管服务。
