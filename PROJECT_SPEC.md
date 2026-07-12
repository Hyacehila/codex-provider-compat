# Codex 自定义 Provider 兼容工具：完整项目规格

## 1. 文档信息

- 公开仓库：<https://github.com/Hyacehila/codex-provider-compat>
- 本地目录：当前仓库根目录；规格不得依赖特定盘符、用户名或维护者机器路径
- 建议项目名：`codex-provider-compat`
- 项目性质：非官方、开源、本地运行的 Codex 社区兼容工具
- 文档日期：2026-07-12
- 当前阶段：v0.1.0 正式 Release 打包、验证和交付
- 首要平台：Windows、macOS
- 首要用户：中国及其他地区使用自定义 OpenAI-compatible API provider 的 Codex 用户

## 2. 执行摘要

Codex 0.144.1 的模型目录将 `gpt-5.6-sol`、`gpt-5.6-terra`、`gpt-5.6-luna` 标记为 `use_responses_lite = true`。在 Responses Lite 模式下，Codex 不会按普通标准 Responses 请求发送工具，而是把客户端工具说明放进内部 `additional_tools` 输入表示，同时跳过 hosted Responses 工具。普通 OpenAI-compatible provider 往往只实现公开的标准 Responses API，因此可能无法识别这套内部工具协议。

普通自定义 provider 往往只实现标准 OpenAI Responses API，并且已经能够正确处理：

```json
{
  "tools": [
    { "type": "web_search" }
  ]
}
```

Web Search 是最容易观察到的症状：Codex 在发送请求前根据模型元数据删除 hosted `web_search`，provider 实际收到的请求中 `tools` 为 `null`。但上游 Issue `#31894` 直接展示的症状是 exec/code-mode 工具不可见；相邻问题还涉及 Azure/custom provider 的 Lite header、collaboration namespace 和模型选择行为。因此，本项目要解决的是一类“Responses Lite 与标准 Responses provider 不兼容”的问题，而不是单独修补 Web Search。

本项目不修改代理服务端，也不发布修改版 Codex。它提供一个小型跨平台工具，在用户本机：

1. 自动发现 Codex home 和版本；
2. 获取与该版本严格匹配的完整官方模型目录；
3. 应用首个补丁 `responses-lite-standard-tools`：仅将三个目标模型的 `use_responses_lite` 改为 `false`；
4. 备份并更新用户级 `config.toml` 中的 `model_catalog_json`；
5. 备份可能过期的模型缓存；
6. 提供只读诊断、状态检查、重复执行保护和精确回滚；
7. 明确提醒用户完全退出 Codex、重新启动并新建任务。

### 2.1 不可改变的项目核心宗旨

本项目是一个小型外部兼容补丁，不是 Codex fork、客户端补丁、服务端补丁或代理适配层。

允许的修复面严格限定为：

```text
用户本机 Codex home
├─ 完整版本匹配的 model catalog
├─ 用户级 config.toml 中的 model_catalog_json
├─ 可选 web_search 配置
├─ 模型缓存的改名备份
└─ 本工具自己的状态与备份文件
```

明确禁止把社区发行方案变成：

- 修改或重新编译 Codex 客户端；
- 替换 CLI、Desktop 或 app-server 可执行文件；
- 修改 OpenAI/Codex 服务端；
- 要求第三方 provider 实现 `additional_tools`、`web/run` 或 `alpha/search`；
- 要求用户联系 provider、研究协议、抓包、手工构造 Responses 请求；
- 托管用户 API Key、代理用户请求或提供中转服务。

普通用户的产品路径必须始终是：

```text
下载社区工具
  -> 运行 doctor/apply
  -> 工具自动发现版本并完成本地文件补丁
  -> 完全退出并重启 Codex
  -> 新建任务
```

所有复杂度由项目实现和维护者承担。用户最多选择是否启用 live Web Search，不需要知道自己的 provider 如何实现工具协议。如果工具无法安全判断版本、catalog 或配置，它应停止并保持系统原样，而不是把技术调查工作转交给普通用户。

项目可以阅读和分析上游 Codex 源码，也可以向官方提交 Issue/PR，但这只属于研究和长期推动工作，不改变社区工具“外部、本地、零服务端修改”的交付边界。

## 3. 问题背景和已验证现象

### 3.1 典型用户配置

```toml
model_provider = "example_compatible"
model = "gpt-5.6-sol"
web_search = "live"

[model_providers.example_compatible]
name = "Example Compatible Provider"
base_url = "https://example-provider.invalid/v1"
wire_api = "responses"
requires_openai_auth = true
```

provider 名称只是通用占位符。本项目必须对普通自定义 provider 通用，不能硬编码任何具体服务商名称。

### 3.2 已观察到的请求与工具差异

| 场景 | 实际顶层 `tools` |
|---|---|
| `gpt-5.6-sol` + 自定义 provider | 顶层 `tools` 为 `null`，provider 看不到标准工具定义 |
| 非 Lite 模型 + 同一 provider | 顶层 `tools` 包含标准工具定义 |
| 直接调用 provider 并显式传入 hosted `web_search` | 成功，证明 Web Search 服务端能力存在 |
| 上游 `#31894` 的 custom provider 场景 | exec/code-mode 工具不可见或无法执行 |

### 3.3 根因链

1. 模型目录把目标模型标为 Responses Lite。
2. 工具规划阶段会在 Lite 模型下跳过 hosted Responses 工具。
3. 请求构造阶段会把客户端工具说明改放进 Lite 的 `additional_tools` 输入项，并把标准顶层 `tools` 设为 `null`。
4. Lite 的 Web Search 备用路径是独立的 `web/run` 扩展。
5. `web/run` 只对官方 OpenAI provider 或 OpenAI Actor Authorization provider 注册。
6. 普通自定义 provider 可能无法识别 `additional_tools` 中的客户端工具。
7. Web Search 还会额外失去 hosted `web_search` 和独立 `web/run` 两条搜索路径。

### 3.4 为什么官方链路通常不受同样影响

在 Codex 预期的官方 OpenAI/ChatGPT 链路中，服务端理解 Responses Lite 的内部协议，同时客户端有资格注册独立搜索扩展。普通 OpenAI-compatible provider 通常只声明和实现公开的标准 Responses API，不理解内部 `additional_tools` 语义，也没有实现 Codex 的独立 `alpha/search` 端点。

问题的本质不是“某个中国 provider 写错了”，而是：

```text
模型元数据选择了 Responses Lite
          +
provider 只兼容标准 Responses API
          +
Codex 缺少足够细的 provider 能力协商
          =
工具请求形态与 provider 能力不匹配
```

### 3.5 潜在受影响的能力系列

`tools = null` 只是线上的可见结果。需要分别研究和测试以下能力，不能把 Web Search 的成功等同于所有工具恢复：

| 能力族 | Lite 下的相关机制 | 普通标准 provider 的潜在表现 |
|---|---|---|
| hosted Web Search | hosted 工具被规划阶段跳过；独立 `web/run` 受 provider 身份限制 | 搜索工具完全缺失 |
| exec、shell、code mode | 工具 schema 进入内部 `additional_tools`，且可能使用 namespace/code-mode 表示 | 模型看不到工具、生成纯文本调用或无法执行 |
| function、MCP、dynamic tools | 客户端工具依赖 Lite 专用附加工具输入 | provider 若不理解该输入，函数调用能力可能缺失 |
| collaboration / multi-agent | namespace 工具和模型目录能力共同决定暴露方式 | namespace 可能缺失或模型选择异常 |
| image generation 与扩展工具 | 扩展工具同样可能依赖 namespace 或附加工具表示 | 是否受影响取决于 provider 和模型实现 |
| hosted 工具的未来扩展 | Lite 当前整体跳过 hosted Responses 工具 | 新 hosted 工具也可能出现同类兼容问题 |

表中的“潜在表现”必须通过 fixture、mock 请求和受控人工测试验证。项目不能在 README 中笼统声称所有工具必然失效，也不能因为 Web Search 恢复就声称所有工具必然修复。

### 3.6 Responses Lite 不只改变工具字段

当前源码还显示 Lite 模式会影响其他请求语义，包括但不限于：

- 把基础 instructions 改为 developer input item，而不是标准顶层 `instructions`；
- 设置内部 Responses Lite header 或 WebSocket metadata；
- 禁用标准 `parallel_tool_calls`；
- 调整 reasoning context；
- 对图片输入进行 Lite 特定处理，例如移除某些 detail 信息；
- 改变输入历史和工具说明的组合方式。

因此，`use_responses_lite = false` 是一个“切换完整请求协议形态”的兼容补丁，不是只开启一个工具的开关。测试必须覆盖普通文本、多轮历史、工具、图片和 reasoning 请求的基本回归。

### 3.7 相关上游问题

OpenAI Codex 仓库的 Issue `#31894` 描述了 Responses Lite 在自定义 provider 下导致顶层 `tools` 缺失，并以 code-mode/exec 工具不可用作为主要复现。相关 Issue 还涉及 Azure/custom provider 的内部 Lite header、Responses Lite 工具执行、collaboration namespace，以及模型目录刷新后 custom provider 仍看不到新模型等问题。

社区工具应把这些 Issue 作为“兼容问题地图”，但 v0.1 仍只实现一个经过验证、可回滚的 catalog 补丁。理想的官方长期修复仍应是 provider 能力协商，而不是让所有用户长期维护完整 catalog 覆盖。

### 3.8 2026-07-12 上游复核快照

以下事实检查于 2026-07-11 21:22:20 UTC（Asia/Shanghai 2026-07-12 05:22:20）。这是带时间的上游快照，不是对未来 `main` 的永久声明；未来交付或更新前仍必须再次刷新：

- 当时最新正式 release 为 `rust-v0.144.1`（2026-07-09 发布）；检查的 main 提交为 `9e552e9d15ba52bed7077d5357f3e18e330f8f38`（提交时间为 2026-07-11 21:03:12 UTC）。
- `rust-v0.144.1` 的官方完整 `models.json` 为 297884 字节、SHA-256 `DCAB00231A5178A9C84B7AEF4CC06A1E1359E37EE0DD7E69D5822C4B1DE723B1`，包含 8 个模型。完整目录的生产校验因此不能使用“约 20 个模型”之类的旧数量假设；当前补丁要求至少 8 个模型且至少 5 个非目标模型，防止把只含目标模型的手写目录误当作完整 catalog。
- release 与所检查 main 都仍把 `gpt-5.6-sol`、`gpt-5.6-terra`、`gpt-5.6-luna` 标为 Lite，且没有其他 Lite 模型。
- release 与 main 的请求构造仍在 Lite 下发送 `input[0].type = additional_tools`、省略顶层 `tools` 和顶层 `instructions`、强制 `parallel_tool_calls = false`、使用 `reasoning.context = all_turns`、移除图片 `detail`，并发送内部 Lite header。hosted Responses 工具仍在 Lite 规划阶段被整体跳过。
- 独立 `web/run` 扩展仍只对官方 OpenAI provider 或使用 OpenAI Actor Authorization 的 provider 注册。普通自定义 provider 因而仍可能同时失去 hosted `web_search` 和 `web/run`。
- 在该快照中，`#31894`、`#31875`、`#31870`、`#31882`、`#31864`、`#32086`、`#32101` 均为 open；`#32119` 已以 completed 关闭，但只涉及自定义 provider 的远程模型刷新，不代表 Lite 工具协议已经修复。
- 旧规格误把 `#31853` 和 `#31872` 作为直接相关 Issue。在该快照中，`#31853` 是无关的 “Add fail-closed plugin script resolver” PR，`#31872` 是无关的 sidebar 排序 Issue；二者保留在本段仅用于说明编号纠错，不再作为兼容问题证据。
- 当前官方配置文档确认用户配置位于 `~/.codex/config.toml`；`model_catalog_json` 是启动时加载、替换当前进程 bundled catalog 的完整目录。选中的 `$CODEX_HOME/<profile>.config.toml` 会覆盖基础用户配置中的同名值，项目配置和 CLI/session override 还可具有更高优先级。因此脚本只修改用户级配置，但 doctor/status 必须警告 profile 或更高层覆盖可能使补丁不生效。
- 官方配置文档把 `openai` 定义为内置/default provider ID，但 `openai_base_url` 或自定义 provider 定义可以重定向这个 ID。doctor 不能只凭字符串 `model_provider = "openai"` 就绝对证明请求进入 OpenAI-hosted 后端；发现 override 时应给出保守结论。
- 版本发现可能同时得到 CLI、Desktop、运行中 app-server 和用户态 runtime 的不同版本。只要发现版本歧义，未显式传入并审核 `--codex-version` 时 apply 必须停止；规格不记录某一维护者机器的具体安装版本。

由于该复核快照中的 release 和 main 都尚未消除核心不匹配，v0.1 继续提供 apply；每次运行仍须重新校验对应版本的官方目录。如果未来官方目录已把目标模型全部设为非 Lite，apply 返回“不适用”而不制造 override。

## 4. 已验证的补丁原型

受控实验验证了以下最小补丁形态；这些步骤是工具的实现依据，不是要求普通用户手工执行的安装流程：

1. 获取 Codex 0.144.1 的完整 `models.json`；
2. 将以下模型的 `use_responses_lite` 设置为 `false`：
   - `gpt-5.6-sol`
   - `gpt-5.6-terra`
   - `gpt-5.6-luna`
3. 把修改后的完整目录写入工具拥有的通用路径：

```text
$CODEX_HOME/model-catalogs/models-0.144.1.standard-responses-compat.json
```

4. 在用户级 `config.toml` 中设置：

```toml
model_catalog_json = "<absolute-CODEX_HOME>/model-catalogs/models-0.144.1.standard-responses-compat.json"
```

5. 保留原有 `model`、`model_provider`、`web_search` 和 provider 配置；
6. 完全退出并重启 Codex；
7. 新建任务，使新的模型与工具快照生效。

这个方案是本项目 MVP 的基础，但不能把某个维护者机器生成的静态 JSON 直接发给所有用户。`model_catalog_json` 是整表替换，必须根据每位用户实际检测并审核的 Codex 版本生成完整目录。

## 5. 项目目标

### 5.1 产品目标

为普通用户提供一个尽可能简单、透明、可审阅、无需额外运行时、可完整回滚的社区修复工具。

普通用户不需要理解 Responses Lite，不需要验证 provider 协议，也不需要编辑 provider 配置。默认成功路径只包含运行脚本、重启 Codex 和新建任务。

用户应能在下载并校验正式 Release 资产（或审核过的源码 checkout）后，通过一条本地命令完成：

```text
诊断 -> 验证是否适用 -> 安全应用 -> 输出自检 -> 提醒重启
```

并能通过另一条命令完成：

```text
状态检查 -> 精确回滚 -> 恢复原配置
```

### 5.2 技术目标

- Windows 和 macOS 均不要求用户安装 Python、Node、Go、Rust、`jq` 或其他第三方依赖。
- 不修改 Codex 二进制。
- 不修改、编译、注入或替换 Codex 客户端和 app-server。
- 不修改 OpenAI/Codex 服务端或任何第三方 provider 服务端。
- 不实现代理端 `web/run`。
- 不读取、复制、上传或打印任何 API Key、Authorization、`auth.json` 内容或用户请求内容。
- 不修改系统全局无关文件。
- 只操作用户 Codex home 下的 catalog、用户级 config、补丁状态文件和可选模型缓存备份。
- 所有写入都必须先验证、再备份、再原子替换。
- 所有测试必须使用临时 `CODEX_HOME`，不得损坏开发者真实配置。

### 5.3 社区目标

- 中英文文档清楚解释问题、适用范围和风险。
- GitHub Issue 模板能够收集脱敏诊断信息。
- 版本更新时能快速确认兼容性。
- 官方修复发布后，用户可以安全卸载本补丁。

## 6. 非目标

本项目明确不做以下事情：

- 不提供或运营 API 代理、中转、密钥托管服务。
- 不收集用户 provider 地址或凭据。
- 不替用户购买、共享或绕过任何模型权限。
- 不把 `gpt-5.5` 作为唯一解决方案。
- 不修改 Windows Store、npm、Homebrew 或应用包中的 Codex 可执行文件。
- 不硬编码某一家 provider。
- 不要求普通用户研究或修改 provider 适配。
- 不声称对所有 provider 都有效。
- 不保证 provider 免费提供 hosted 工具或 Web Search，也不干预其计费。
- 不在旧任务中热更新工具快照。
- 不把社区 workaround 描述成 OpenAI 官方修复。

### 6.1 用户体验边界

README 可以解释技术根因，但快速使用流程不得要求用户：

- 查看 Codex Rust 源码；
- 抓取 `/responses` 请求；
- 自己调用 provider API；
- 确认 `additional_tools`、namespace 或 hosted tool 的实现细节；
- 修改 `base_url`、auth、header 或 provider 服务端；
- 手工下载、编辑或替换 JSON/TOML。

这些行为只属于维护者诊断、自动测试或高级故障排查。普通用户应由脚本自动完成文件生成和配置更新。

## 7. 最小仓库设计

第一版应保持非常小：

```text
codex-provider-compat/
├─ README.md
├─ README.zh-CN.md
├─ PROJECT_SPEC.md
├─ IMPLEMENTATION_PROMPT.md
├─ codex-provider-compat.ps1
├─ codex-provider-compat.sh
├─ LICENSE
├─ THIRD_PARTY_NOTICES.md
├─ .gitattributes
├─ .gitignore
├─ scripts/
│  └─ build-release.ps1
├─ tests/
│  ├─ fixtures/
│  │  ├─ models-valid.json
│  │  ├─ models-missing-target.json
│  │  ├─ config-basic.toml
│  │  └─ config-complex.toml
│  ├─ test-windows.ps1
│  ├─ test-request-shape-windows.ps1
│  ├─ test-release-package.ps1
│  └─ test-macos.sh
└─ .github/workflows/
   ├─ test.yml
   └─ package-release.yml
```

不要为了代码复用引入复杂构建系统。两个平台脚本允许少量重复，但必须共享同一套行为规范、状态文件格式和测试场景。

## 8. 平台实现策略

### 8.0 简单的补丁模型

v0.1 不设计插件系统，只在两个脚本顶部维护一个很小的内置补丁定义：

```text
patch_id: responses-lite-standard-tools
target_models: gpt-5.6-sol, gpt-5.6-terra, gpt-5.6-luna
catalog_mutation: use_responses_lite = false
purpose: make affected models use standard Responses request semantics
```

状态文件必须记录 `patch_id`。未来如发现另一个明确、独立且可回滚的 provider 兼容问题，可以新增第二个内置补丁，但不能提前建设动态插件加载、远程脚本执行或复杂依赖解析框架。

### 8.1 Windows

使用单个 PowerShell 脚本：

```text
codex-provider-compat.ps1
```

只使用 PowerShell 和 .NET 内置能力：

- `Get-Command` / `Start-Process` / `System.Diagnostics.Process`
- `System.Net.Http.HttpClient`
- `ConvertFrom-Json` / `ConvertTo-Json`
- `Get-FileHash`
- `Copy-Item` / `Move-Item` / `Rename-Item`
- .NET 原子文件替换能力或同卷临时文件重命名

不得要求用户安装 Python 或 `jq`。

### 8.2 macOS

使用单个 POSIX 风格 shell 脚本：

```text
codex-provider-compat.sh
```

只使用 macOS 系统通常自带的工具：

- `/bin/sh` 或 `/bin/bash`
- `/usr/bin/curl`
- `/usr/bin/osascript -l JavaScript`，通过 JXA 解析和修改 JSON
- `/usr/bin/awk`
- `/usr/bin/shasum`
- `/bin/cp` / `/bin/mv`

不要假设存在 Python 3、Node、Homebrew、`jq` 或 GNU 工具。

### 8.3 为什么第一版不发布自定义二进制

- 可读脚本更容易获得社区信任。
- macOS 未签名二进制会触发 Gatekeeper。
- Windows 未签名二进制可能触发 SmartScreen。
- 两个小脚本足以完成当前范围。
- 后续只有在脚本维护成本明显上升时，才考虑 Go/Rust 单文件程序。

## 9. 命令行界面

第一版必须支持以下命令：

### 9.1 `doctor`

完全只读，不写任何文件。

职责：

- 输出工具版本、操作系统、Codex home。
- 检测可用 Codex 版本来源。
- 检查用户级 `config.toml` 是否存在。
- 只展示以下非敏感配置：
  - `model_catalog_json`
  - `web_search`
  - `model`
  - `model_provider`
- 检查当前 model 是否是目标模型。
- 检查当前 provider 是否为自定义 provider；内置 `openai` provider 只提示通常无需补丁，不强制禁止。若 `openai_base_url` 或自定义 provider table 覆盖了该 ID，则不能把名称本身当成官方后端证明，应给出保守结论。
- 不要求用户判断 provider 的 Lite 能力；doctor 根据已知本地事实给出简单结论和风险说明。
- 检查当前 catalog 是否存在、是否完整、是否匹配当前 Codex 版本。
- 检查三个目标模型的 `use_responses_lite`。
- 枚举 catalog 中所有 `use_responses_lite = true` 的模型，并区分“本补丁已验证目标”和“尚未验证的新 Lite 模型”。
- 输出静态能力风险矩阵：standard tools、exec/code mode、function/MCP、collaboration namespace、hosted tools、图片/扩展工具。
- 检查模型缓存是否存在。
- 检查是否有补丁状态文件。
- 给出明确结论：`applicable`、`already-applied`、`stale`、`not-needed`、`unsafe` 或 `unknown`。

### 9.2 `apply`

执行完整修复。默认交互式展示即将修改的路径；提供明确的非交互参数供 CI 和高级用户使用，但不应默认静默修改。

建议参数：

```text
--yes
--codex-home <absolute-path>
--codex-version <version>
--catalog-file <local-offline-models.json>
--enable-web-search
--dry-run
```

`--catalog-file` 主要用于离线使用和自动测试。即使使用本地文件，也必须执行完整性和差异校验。基础兼容补丁默认只切换 Responses 模式；只有用户传入 `--enable-web-search` 时才把顶层 `web_search` 设置为 `live`，避免一个通用工具在未告知用户时开启网络搜索。

### 9.3 `status`

只读检查已安装补丁：

- 状态文件是否有效；
- catalog 文件是否存在且哈希匹配；
- catalog 版本是否与当前 Codex 版本一致；
- config 是否仍指向该 catalog；
- 三个目标模型是否仍为 `false`；
- 是否出现新的、尚未纳入补丁定义的 Lite 模型；
- 是否需要重新运行 `apply`；
- 是否可能已经有官方修复。

`healthy` 只表示工具拥有的用户级 state、catalog、backup 和 config 指针彼此一致。status 必须同时提醒：选中的 profile、project config 和 CLI/session override 具有更高优先级，仍可能改变某个具体任务的有效 catalog。

### 9.4 `rollback`

精确撤销工具拥有的修改，不覆盖用户后来修改的其他配置。

建议参数：

```text
--yes
--codex-home <absolute-path>
--dry-run
```

### 9.5 暂不作为 v0.1 必需项的 `update`

`update` 可以在 v0.2 加入。v0.1 中，版本变化时重新运行 `apply` 即可。README 必须明确这一点，避免命令面过宽。

## 10. Codex home 发现规则

按以下顺序确定：

1. 显式 `--codex-home`；
2. 非空的 `CODEX_HOME` 环境变量；
3. 默认 `$HOME/.codex`；
4. Windows 等价路径 `%USERPROFILE%\.codex`。

要求：

- 转换为绝对规范路径。
- 如果路径不存在，`doctor` 报告；`apply` 可在确认后创建必要子目录。
- 不允许空路径、根目录或明显危险路径。
- 所有写操作必须验证最终路径仍位于确定的 Codex home 内。

## 11. Codex 版本自动发现

### 11.1 优先顺序

1. 显式 `--codex-version`；
2. PATH 中的 `codex --version`；
3. 当前运行中的 Codex/app-server 可执行文件；
4. Codex home 下已知的用户态 app-server 副本；
5. 平台常见 Desktop 应用资源路径；
6. 无法确定时停止写入并要求用户显式指定版本。

### 11.2 Windows 候选

- `Get-Command codex`
- 运行中的 `codex.exe` 进程路径
- `%CODEX_HOME%\plugins\.plugin-appserver\codex.exe`
- 其他通过实际环境发现的用户态路径

不要硬编码某个 Windows Store 包版本目录。

### 11.3 macOS 候选

- PATH 中的 `codex`
- `/Applications/Codex.app/Contents/Resources/codex`
- `$HOME/Applications/Codex.app/Contents/Resources/codex`
- `$CODEX_HOME/plugins/.plugin-appserver/codex`

### 11.4 多版本冲突

如果检测到 CLI 和 Desktop 是不同版本：

- `doctor` 必须同时报告；
- `apply` 默认停止，避免为错误版本生成整表 catalog；
- 用户可通过 `--codex-version` 明确选择；
- README 解释一个用户级 catalog 可能同时影响多个 Codex surface，因此版本不一致需要谨慎处理。

## 12. 上游 catalog 获取规则

### 12.1 来源优先级

1. 用户显式提供的完整 `--catalog-file`；
2. 能可靠读取的本机当前版本完整模型目录；
3. 与检测版本匹配的官方 GitHub tag：

```text
https://raw.githubusercontent.com/openai/codex/rust-v<version>/codex-rs/models-manager/models.json
```

4. 仅在版本确实无法检测、用户明确确认的兼容模式中，才允许使用文档指定的保守 fallback。禁止在无人确认时悄悄使用 0.144.1 覆盖未知新版本。

### 12.2 下载安全

- 只允许 HTTPS。
- 默认只接受官方 `raw.githubusercontent.com/openai/codex` 来源。
- URL 必须由版本号严格构造为 HTTPS `raw.githubusercontent.com/openai/codex/rust-v<version>/codex-rs/models-manager/models.json`；不接受用户注入其他下载域名。
- 禁止跨域或同域重定向。Windows 使用关闭自动重定向的 `HttpClientHandler`；macOS `curl` 不使用 `-L`，并限制为 HTTPS。
- 同时设置连接与整段响应流总超时；不能只对建立连接计时。
- 在读取前检查 `Content-Length`，并在流式读取期间再次强制最大字节数；空响应、超大响应、截断连接、HTTP 错误和超时都返回退出码 5。
- 先下载到 Codex home 下的临时目录或系统临时目录。
- 下载失败时不得修改 config、cache 或现有 catalog。
- 输出明确失败原因和来源 URL，但不得输出认证信息。

## 13. Catalog 完整性和补丁校验

这是项目最关键的安全边界。

### 13.1 输入结构校验

必须确认：

- 顶层是 JSON object。
- 存在 `models` 数组。
- `models` 不是空数组。
- 模型数量至少为 8，并且至少有 5 个不属于三个固定目标的模型。
- 每个模型有非空唯一 `slug`。
- 三个目标 slug 各出现且只出现一次。
- 三个目标条目原始 `use_responses_lite` 是布尔值。
- 记录所有其他 Lite 模型，但不得自动修改未经过验证的 slug。

### 13.2 允许的变更

只允许：

```text
gpt-5.6-sol   use_responses_lite -> false
gpt-5.6-terra use_responses_lite -> false
gpt-5.6-luna  use_responses_lite -> false
```

其他字段和模型必须保持语义不变。

实现应在写入前执行递归语义深比较：

- 克隆原始解析对象；
- 修改三个布尔值；
- 比较所有非目标路径；
- 把修改对象序列化后重新解析，再与预期修改对象比较；
- 如果发现额外差异，立即停止。

### 13.3 输出路径

```text
$CODEX_HOME/model-catalogs/models-<version>.standard-responses-compat.json
```

文件名不要包含某一家 provider 名称，以保持通用。

### 13.4 原子写入

1. 创建 `model-catalogs` 目录。
2. 写入同目录临时文件。
3. 重新读取临时文件并执行完整校验。
4. 计算 SHA-256。
5. 通过同卷原子重命名替换最终文件。
6. 绝不让 config 指向一个尚未成功写完的文件。
7. 原子替换后重新打开文件，验证完整结构、三个目标值、文件哈希和权限。

### 13.5 写路径所有权和链接防逃逸

- Codex home 必须规范化为非空绝对路径，不能是文件系统根目录。
- config、生成 catalog、cache、state、transaction、lock、backup、archive 和 pending 文件的最终路径必须位于同一个 Codex home，且符合固定文件名或目录命名规则。
- Windows 在写入前逐个检查现有路径组件，拒绝 junction、mount point 和其他 reparse point。macOS 先把 Apple 系统固定的 `/var`、`/tmp`、`/etc` 别名规范化为 `/private/...`，随后拒绝其他用户可控 symlink 组件和 symlink leaf。
- rollback 不得直接信任状态文件中的路径。实现必须根据 Codex home、已校验的 Codex 版本和固定命名规则重建预期路径，再与状态值逐字比较。
- 状态文件中的 config backup、cache backup 和 state archive 必须位于预期父目录并匹配严格文件名模式。空路径、根目录、`..`、外部路径和名称不匹配均以退出码 3、零写入停止。
- `--catalog-file` 是只读输入，允许位于 Codex home 外；它永远不能成为移动、覆盖或删除目标。

## 14. 用户配置修改规范

### 14.1 配置位置

```text
$CODEX_HOME/config.toml
```

必须修改用户级 config，不能只修改项目 `.codex/config.toml`。

### 14.2 备份

写入前创建：

```text
config.toml.bak-provider-compat-YYYYMMDD-HHMMSS
```

同时在状态文件中记录：

- 备份路径；
- 修改前 config SHA-256；
- 原 `model_catalog_json` 值；
- 原 `web_search` 值；
- 原文件换行风格和编码信息（在合理可检测范围内）。

### 14.3 允许修改的顶层键

工具只允许修改或插入：

```toml
model_catalog_json = "<absolute-path>"
```

只有显式使用 `--enable-web-search` 时，才允许额外修改或插入：

```toml
web_search = "live"
```

不得修改：

- `model`
- `model_provider`
- `[model_providers.*]`
- provider URL
- `requires_openai_auth`
- 审批、安全、MCP、plugin、hook 或其他配置

### 14.4 TOML 文本保护

两个平台必须使用行为一致的小型 TOML 词法扫描器，不得用逐行正则猜测配置结构。扫描器至少跟踪：

- basic string、literal string、multiline basic string、multiline literal string；
- 注释、数组、inline table、普通 table 和 array-table 上下文；
- 未引用、单引号和双引号形式的键。

编辑规则：

- 只编辑并拥有顶层 `model_catalog_json` 和可选的 `web_search`；同时只读识别顶层 `model`、`model_provider`、`openai_base_url` 以及 `[model_providers.openai]` override，用于保守诊断。多行字符串、注释、无关 section 或其他值中的相似文本不得被识别为键。
- owned key 使用复杂 dotted key、重复定义、无法可靠解析的键或无法无损替换的值时 fail closed，不猜测。
- 保留 UTF-8 BOM 有无、LF/CRLF、尾随换行、注释、section 顺序、无关字节和原文件权限。
- config 不存在时创建 UTF-8 最小文件，使用平台原生换行并将权限收紧；rollback 必须恢复到“文件不存在”，不能留下空文件。
- Windows 路径写入 TOML 时转换为正斜杠并正确转义双引号。
- 交互确认后、任何写入前重新读取 config 并比较 SHA-256。若确认期间发生变化，重新生成计划并最多重新确认一次；再次变化则退出 3。

### 14.5 可选 `web_search` 策略

- 基础 `apply` 不改变用户的 `web_search`。
- 使用 `--enable-web-search` 时：若不存在则添加 `web_search = "live"`；若已为 `live` 则保持；若为 `cached`、`indexed` 或 `disabled`，明确展示将发生的修改并记录原值。
- `doctor` 始终报告 Web Search 配置，但不得把它当作唯一兼容性判断。

## 15. 模型缓存处理

如果存在：

```text
$CODEX_HOME/models_cache.json
```

则改名备份为：

```text
models_cache.json.bak-provider-compat-YYYYMMDD-HHMMSS
```

规则：

- 只改名，不永久删除。
- 状态文件记录原路径、备份路径和哈希。
- 若备份目标已存在，生成新的唯一时间戳。
- rollback 仅在原路径不存在且备份仍匹配时恢复；否则保留两者并给出人工处理提示。

## 16. 状态文件

建议路径：

```text
$CODEX_HOME/provider-compat-state.json
```

建议结构：

```json
{
  "schema_version": 1,
  "patch_version": "0.1.0",
  "patch_id": "responses-lite-standard-tools",
  "codex_version": "0.144.1",
  "source_catalog": {
    "kind": "official-github-tag",
    "url": "https://raw.githubusercontent.com/openai/codex/rust-v0.144.1/codex-rs/models-manager/models.json",
    "sha256": "...",
    "model_count": 8
  },
  "generated_catalog": {
    "path": "...",
    "sha256": "..."
  },
  "config": {
    "path": "...",
    "backup_path": "...",
    "before_sha256": "...",
    "existed": true,
    "had_bom": false,
    "newline": "crlf",
    "original_mode": null,
    "previous_model_catalog_json_present": false,
    "previous_model_catalog_json": null,
    "previous_model_catalog_json_literal": null,
    "web_search_modified": false,
    "previous_web_search_present": true,
    "previous_web_search": "live",
    "previous_web_search_literal": "\"live\""
  },
  "cache": {
    "original_path": "...",
    "backup_path": "...",
    "sha256": "..."
  },
  "applied_at": "2026-07-11T20:00:00+08:00"
}
```

状态文件本身不得包含凭据或完整 provider 配置。

### 16.1 事务日志

写操作使用独立文件：

```text
$CODEX_HOME/provider-compat-transaction.json
```

事务日志使用 `schema_version = 1`，只记录 `operation`、`phase`、随机 `nonce`、从 Codex home 重建并验证过的固定路径、必要哈希和动作布尔值。不得记录完整 config、provider URL、请求内容、Authorization 或任何 secret。

两个平台共享同一个 journal schema。顶层字段固定为：

```text
schema_version, operation, phase, nonce, created_at, updated_at,
codex_version, root, paths, hashes, flags

paths:
  config, config_backup, config_snapshot,
  generated_catalog, generated_catalog_pending,
  cache_original, cache_backup, state, state_archive

hashes:
  config_before, config_after, generated_catalog, cache, state

flags:
  config_existed, config_should_delete,
  generated_catalog_owned, cache_should_restore
```

某个 operation 不使用的路径或哈希必须显式为 `null`，不能通过删除字段形成平台差异。phase 名称也跨平台统一：apply 使用 `prepared`、`config-backed-up`、`generated-catalog-written`、`cache-backed-up`、`config-written`、`state-written`；rollback 使用 `prepared`、`config-snapshotted`、`generated-catalog-pending`、`cache-restored`、`config-written`、`state-archived`。

- apply 在第一次可能改变用户状态的动作之前原子写入日志，按 catalog、cache、config、state 阶段推进并在每个阶段原子更新。
- rollback 先保存当前 config；生成 catalog 先改名为 nonce 绑定的 pending 文件；cache、config 和 state archive 的每一步都必须可以反向恢复。
- 正常完成并验证所有最终文件后才清理 pending 文件和 transaction。
- 捕获到普通异常、SIGINT 或 SIGTERM 时，提交点前立即按日志恢复到操作前状态；当最终 state 已验证并进入不可逆清理提交点后，应完成已提交操作的清理，而不是尝试使用已经删除的 pending/snapshot 反向恢复。两种路径都必须先处理 transaction，再释放锁，不能留下无法判定的半提交状态。
- SIGKILL、断电或进程崩溃留下日志时，`doctor`/`status` 只读报告 `recovery-required`；下一次 `apply` 或 `rollback` 获得锁后先自动恢复，再重新执行用户请求。
- transaction 中任一路径或名称不满足固定规则时停止自动恢复并返回退出码 3。

## 17. 幂等性和并发控制

### 17.1 重复应用

重复运行 `apply` 必须：

- 不重复插入 config 键；
- 不反复创建无意义备份；
- 如果当前状态完全正确，输出 `already-applied` 并退出成功；
- 如果版本发生变化，输出 `stale` 并重新走完整验证；
- 如果用户手动修改了生成 catalog，停止并要求先检查，不覆盖未知内容。

### 17.2 进程和锁

- 检测 Codex 是否正在运行并警告更改只会在重启和新任务中生效。
- 不强制结束用户进程。
- 使用排他锁防止两个补丁进程同时写入；metadata 包含 PID、时间和随机 nonce。
- macOS 锁目录刚创建但 metadata 尚未落盘时仍视为活动锁，不能被第二个进程删除。
- 只允许持有相同 nonce 的进程清理自己的锁；支持在严格验证后恢复失效锁。

## 18. Rollback 设计

rollback 不能简单地把旧 `config.toml` 整文件覆盖回来，因为用户可能在应用补丁后修改了其他配置。

正确流程：

1. 读取并校验状态文件。
2. 检查当前 config。
3. 只恢复工具拥有的顶层键：
   - 恢复原 `model_catalog_json`；原来不存在则删除当前工具写入的键。
   - 只有状态文件表明 apply 使用过 `--enable-web-search` 时才处理 `web_search`：恢复原值；原来不存在则仅在当前值仍是工具写入值时删除。
4. 保留其他用户修改。
5. 只有当生成 catalog 哈希与状态文件一致时才删除该文件；否则保留并警告。
6. 按安全规则恢复 cache。
7. 将状态文件改名为 rollback 记录或删除前另存审计副本。
8. 提醒完全退出、重启并新建任务。

rollback 的所有路径必须按 Codex home、版本和固定命名规则重建，不得把损坏或被篡改的 state 当作任意文件操作清单。rollback 本身是一个事务：任何阶段失败都恢复操作开始前的 config、catalog、cache 和 state；cache 原路径出现新文件时绝不覆盖。

完整 config 备份是最后的人工恢复手段，不是默认 rollback 的唯一机制。

## 19. 隐私和安全要求

工具必须做到：

- 不读取 `$CODEX_HOME/auth.json`。
- 不读取 API Key 环境变量。
- 不打印 Authorization header。
- 不向项目维护者服务端发送任何遥测。
- 不上传 config。
- 默认网络请求只访问官方 GitHub catalog 来源。
- 输出配置时只输出允许的四个顶层键。
- provider URL 默认不输出；如诊断确需输出，只显示 hostname，并允许完全隐藏。
- 错误日志不得包含 config 全文。
- 所有路径检查防止意外写入 Codex home 外部。

## 20. 适用范围判断

工具可认为“可能适用”的条件：

- 当前模型是 `gpt-5.6-sol`、`gpt-5.6-terra` 或 `gpt-5.6-luna`；
- 模型目录显示 `use_responses_lite = true`；
- 用户遇到标准工具缺失、exec/code mode 不工作、MCP/function/namespace 不可见，或 Web Search 双路径失效中的至少一种症状；
- provider 不是普通官方 OpenAI 默认链路，或用户明确要求检查自定义 provider；
- 当前配置使用普通自定义 provider，且症状与已知 Responses Lite 工具缺失问题一致。

工具不能从静态配置绝对证明 provider 支持每一种工具，但这不是普通用户的前置研究任务。`doctor` 应用通俗语言明确区分：

```text
客户端补丁可应用
```

和：

```text
项目维护者或自动化测试已验证某类 provider 支持某项标准 Responses 工具能力
```

后者由项目维护者的受控测试、社区支持矩阵或未来明确授权的本地自检负责。基础 apply 不要求用户直接调用 API，也不读取用户凭据。如果补丁应用后具体 provider 仍不兼容，工具应提供一键 rollback 和脱敏诊断输出，而不是要求用户改服务端。

## 21. 已知后果和风险

README 必须用醒目章节说明：

1. `model_catalog_json` 是完整目录替换，过期目录可能隐藏 Codex 新模型。
2. Codex 每次升级后都必须重新运行 `doctor`；版本不一致时应重新应用或回滚。
3. 把 `use_responses_lite` 改为 `false` 会改变目标模型的整体请求格式，不只改变 Web Search。
4. 代码工具、指令注入方式、图片细节、并行工具调用、推理上下文等行为可能与 Lite 模式不同。
5. 对只接受 Responses Lite 的 provider，本补丁可能导致请求失败。
6. provider 必须实际支持标准 Responses hosted `web_search`。
7. provider 可能对搜索计费。
8. 旧任务保留启动时的模型与工具快照，不会自动生效。
9. 必须完全退出并重启 Codex，然后新建任务。
10. 官方修复发布后，应 rollback，避免长期维护 override。
11. 本工具不是 OpenAI 官方产品，不代表 OpenAI 或任何 provider。

## 22. 测试策略总览

测试目标不是“脚本能跑一次”，而是证明它不会破坏普通用户系统。

所有测试必须在临时目录中设置显式 `CODEX_HOME`。测试结束后检查真实 `$HOME/.codex` 和 `%USERPROFILE%\.codex` 没有变化。

### 22.1 Catalog 和补丁定义测试

- 完整有效 catalog 成功。
- 补丁 ID 正确写入状态文件。
- 三个目标模型全部修改为 `false`。
- 所有其他字段保持一致。
- 所有其他模型保持一致。
- 目标模型已经是 `false` 时幂等成功。
- 缺少一个目标模型时失败且无写入。
- 目标 slug 重复时失败。
- `models` 为空时失败。
- 输入不是 JSON 时失败。
- JSON 被截断时失败。
- `use_responses_lite` 类型错误时失败。
- 只有三个模型的最小伪 catalog 在生产模式下被拒绝。
- 下载超时、404、500、空响应、超大响应均安全失败。
- tag 不存在时失败并解释版本不受支持。

### 22.2 Config 测试

- config 不存在时安全创建。
- 空 config。
- 仅有顶层键。
- 包含多个 provider section。
- 包含注释和空行。
- CRLF 和 LF。
- UTF-8 BOM 和无 BOM（在平台合理支持范围内）。
- 已存在 `model_catalog_json`。
- 已存在其他用户 catalog override。
- `web_search` 不存在、live、cached、indexed、disabled，并验证基础 apply 不会擅自修改它。
- section 中出现相似字符串时不误改。
- 注释里出现 `model_catalog_json` 时不误改。
- 四种字符串、数组、inline table 和多行字符串中出现相似文本时不误改。
- 未引用、单引号和双引号形式的顶层 owned key 能被正确识别；复杂 dotted 或无法无损编辑的形式安全失败。
- 重复顶层键时安全停止。
- provider、model 和其他配置逐字保持。
- 路径包含空格和非 ASCII 字符。
- 确认期间 config 被其他进程修改时重新规划；连续两次变化时零写入退出。

### 22.3 Backup 和原子性测试

- config 备份命名正确。
- 同一秒重复操作不会覆盖备份。
- catalog 临时文件校验失败时最终文件不出现。
- config 写入失败时保留原文件。
- 中途模拟异常后可以重新运行。
- apply 和 rollback 每个事务阶段都进行失败注入，并验证恢复到操作前状态。
- 真实终止留下 transaction 后，doctor/status 报告 recovery-required，下一次写命令自动恢复。
- 磁盘只读、权限不足、目录不存在时给出清晰错误。
- 锁文件阻止并发写入。
- 失效锁可安全恢复。
- Windows junction/reparse point 和 macOS symlink 组件不能把写入、移动或删除逃逸到 Codex home 外。
- 篡改 state 中的 catalog、backup、cache 或 archive 路径时以退出码 3 零写入停止。

### 22.4 Cache 测试

- cache 不存在时正常。
- cache 存在时只改名备份。
- 备份冲突时生成唯一名称。
- rollback 在安全条件下恢复。
- 原路径已有新 cache 时不覆盖。

### 22.5 状态和幂等测试

- 首次 apply。
- 第二次 apply 返回 already-applied。
- catalog 被用户修改后 status 检测哈希不一致。
- config 不再指向 catalog 时 status 检测 drift。
- Codex 版本升级时 status 返回 stale。
- 状态文件损坏时不盲目 rollback。
- apply 后用户修改其他配置，rollback 保留这些修改。

### 22.6 版本发现测试

- PATH 中只有一个 Codex。
- 只有 Desktop 候选路径。
- 显式版本覆盖。
- CLI/Desktop 同版本。
- CLI/Desktop 不同版本时默认停止。
- `codex --version` 输出异常。
- 未检测到版本时不给未知版本写 catalog。

### 22.7 平台测试

GitHub Actions 至少运行：

- `windows-latest`：分别使用 Windows PowerShell 5.1 与 PowerShell 7 执行同一完整测试套件，并运行固定 Codex 请求形态集成测试。
- `macos-latest`：执行完整 shell/JXA 测试。

两个测试套件使用相同 fixtures 和相同预期状态文件结构。

### 22.8 固定 Codex 请求形态集成测试

在不触碰真实用户配置的前提下：

- 安装并校验固定 `@openai/codex@0.144.1`，版本不匹配立即失败。
- 使用临时 `CODEX_HOME`。
- 使用 .NET `TcpListener` 本地 mock Responses server，只接受 `/v1/responses`。
- 清除 OpenAI/Codex/ChatGPT/Azure OpenAI key、token 和代理环境变量，关闭更新、remote plugin、apps、analytics/telemetry 和其他已知远程功能；把 Codex 子进程配置的模型/auth endpoint 指向 localhost。
- 验证补丁前 Lite 模型的顶层 `tools` 缺失。
- 同时验证首项 `additional_tools`、Lite header、`parallel_tool_calls = false`、`reasoning.context = all_turns`，以及 hosted `web_search`/`web-run` 均未暴露。
- 应用补丁并启动全新任务，验证非空顶层 tools、非空 instructions、无 `additional_tools`、无 Lite header、parallel 为 true、无 Lite reasoning context，并存在 exec/shell、collaboration namespace 和 hosted `web_search`。
- 规范化比较 Lite `additional_tools` 与标准顶层客户端工具集合；hosted `web_search` 是唯一允许新增的 hosted 工具。
- 最后执行 status/rollback，验证 config、cache、catalog、state 和 transaction 全部恢复。

这是公开源码交付的 release gate，不得使用真实 provider 凭据，也不得把 Node/npm 变成用户运行依赖。TcpListener capture 只能证明实际到达 localhost 的请求和被拒绝的本地额外路径；除非另有操作系统级网络监控，测试与文档不得声称它能发现所有静默远程 socket。

### 22.9 工具能力回归矩阵

应使用本地 mock、固定响应 fixture 或受控 provider，对以下能力分别记录 `passed`、`failed`、`not-supported` 或 `not-run`：

- hosted Web Search；
- exec/shell；
- code mode namespace；
- 普通 function calling；
- MCP 和 dynamic tools；
- collaboration/multi-agent namespace；
- image generation/extension tools；
- 普通无工具文本请求；
- 多轮历史；
- 图片输入与 detail；
- reasoning 参数；
- parallel tool call 行为。

项目的结论必须按能力报告，不能用一次 Web Search 成功代替整组工具验证。

### 22.10 人工端到端验收与发布披露

在维护者拥有对应设备、测试账号并明确接受可能计费时，建议执行：

- Windows CLI。
- Windows Desktop。
- macOS CLI。
- macOS Desktop。
- 自定义 provider 直接 API 的标准工具和 hosted Web Search 基线。
- 应用补丁后的新 Codex 任务工具能力矩阵。
- 搜索后 open/find 等连续操作。
- 无搜索普通编码任务。
- shell/MCP/代码模式基本回归。
- rollback 后恢复原始行为。

人工测试不得读取或复用用户的真实凭据，也不得为了满足发布门禁而要求普通用户或第三方 provider 配合协议研究。缺少 macOS Desktop、真实 provider 或明确可计费账号时，可以不执行对应项目，但 README 和 Release notes 必须逐项标记为 `not-run`，不能把 mock、fixture 或 CI 结果写成真实 provider 已通过。

报告必须区分：本地自动测试、CI 平台测试和真实 provider 人工测试，不能把未执行的测试写成已通过。未执行的人工测试本身不阻止 v0.1.0 发布；虚构测试结果、隐藏已知失败或把未知 provider 差异宣传为普遍兼容则属于发布阻断问题。

README 不固定记录容易随测试增长而过时的 case 数，也不沿用旧脚本的“连续通过”结论。最终 commit 的 Actions 页面是云端结果事实；非 macOS 本地只能报告实际运行的 shell 语法检查，不能把 JXA 或 macOS 文件语义写成已本地通过。

## 23. 验收标准

v0.1.0 只有在以下条件全部满足时才能发布：

- Windows 和 macOS 脚本都实现 `doctor/apply/status/rollback`。
- 不依赖第三方运行时。
- 所有写入都限制在 Codex home。
- 下载失败时零配置变更。
- 目标 catalog 是完整目录。
- 只有三个目标布尔值发生语义变化。
- config 备份和原子更新经过测试。
- 重复 apply 幂等。
- rollback 不覆盖用户后续无关修改。
- cache 只改名备份。
- GitHub Actions 的 Windows/macOS 测试通过。
- PowerShell 5.1 和 PowerShell 7 完整套件连续通过两轮；固定请求形态集成测试连续通过两轮。
- 最终远端 commit 的 Windows、macOS 和 integration jobs 连续两次全绿。
- README 中英文版完整说明适用条件、风险、重启和旧任务快照问题。
- 日志和状态文件不包含秘密。
- 正式 Release 提供 Windows ZIP、macOS ZIP、两个独立脚本和 `SHA256SUMS.txt`，并在发布前复验产物内容及 SHA-256。
- 明确标记非官方社区工具。
- 普通用户能够仅通过本地脚本完成应用和回滚，无需手工编辑 JSON/TOML。
- 仓库不包含 Codex 二进制替换、客户端注入、服务端适配或 API 中转实现。
- 文档不把 provider 协议研究作为普通用户使用前置条件。

## 24. README 内容要求

最终 README 的正文只使用两个一级部分：

1. “如何使用”：适用条件、Release 下载与 SHA-256 校验、Windows/macOS 命令、重启与新任务、`doctor/apply/status/rollback`、参数与退出码、修改文件、Codex 更新、故障恢复和完整回滚。
2. “工作原理”：根因简图、为什么非 Lite/官方链路不同、补丁的最小修改、安全边界、能力与验证限制、隐私和许可证。

标题区保留一句用途说明、语言切换、自动测试入口和醒目的非官方声明。允许在两个一级部分内使用短小的三级标题，但不得重新堆叠成开发过程报告。详细 case 数、连续通过轮次、完整上游 Issue 清单、历史诊断过程和内部状态机说明不放入 README；它们留在规格、测试、Actions 或 Release notes 中。

正式 v0.1.0 的主要安装路径是 GitHub Release，必须提供：

- `codex-provider-compat-v0.1.0-windows.zip`
- `codex-provider-compat-v0.1.0-macos.zip`
- `codex-provider-compat.ps1`
- `codex-provider-compat.sh`
- `SHA256SUMS.txt`

README 应让用户下载平台 ZIP 和校验和、核对 SHA-256、查看脚本后本地运行。不要只提供不透明的 `curl | sh` 或 `irm | iex`。独立脚本用于审阅或高级下载场景，不替代校验步骤。

## 25. 发布与维护策略

### 25.1 v0.1.0

- 两个脚本。
- 四个核心命令。
- 中英文 README。
- 完整自动测试。
- 已完成的首次公开源码交付保留为历史里程碑。
- 正式 v0.1.0 Release 提供 Windows/macOS ZIP、独立脚本和 `SHA256SUMS.txt`；打包结果必须可复现审阅，并由自动化测试复验内容和哈希。
- 能执行的受控人工测试应在发布前完成；缺少设备、真实 provider 或可计费账号的项目必须准确披露为 `not-run`，不以不安全的凭据访问换取表面覆盖率。
- 支持当时已验证的 Codex 版本，并明确列出。

### 25.2 新 Codex 版本

每次 Codex 发布新版本：

1. 检查上游模型目录。
2. 确认目标模型是否仍为 Lite。
3. 检查官方是否已修复 provider 能力协商。
4. 运行完整 CI。
5. 在设备和测试账号可用时进行受控人工验证；否则记录未执行范围。
6. 更新支持矩阵。

由于脚本按版本动态生成 catalog，通常不需要为每个版本提交静态 JSON，但仍需要验证上游 schema 没有变化。

### 25.3 官方修复后的退场

- `doctor` 能提示版本可能已包含官方修复。
- README 将 rollback 放在醒目位置。
- 停止鼓励新用户应用 override。
- 保留仓库作为历史诊断和卸载工具。

## 26. 上游协作

社区工具用于立即帮助用户，不能替代理想的官方修复。

应在 `#31894` 中补充：

- `additional_tools`、顶层 `tools = null` 与 code-mode/exec 的具体失效链；
- hosted Web Search 的双路径失效作为特殊案例；
- 自定义 provider 能处理标准 Responses 工具定义的证据；
- catalog override 的社区 workaround；
- workaround 的整表覆盖风险；
- 更理想的 provider capability opt-in 设计；
- 自动测试结果。

Codex 当前贡献规范要求外部贡献先获得维护者邀请，因此不要用社区工具仓库冒充官方 fork。等待维护者确认后，再准备独立、最小的上游 PR。

## 27. 许可证和归属

- 工具脚本可以使用宽松开源许可证，例如 MIT。
- README 和 `THIRD_PARTY_NOTICES.md` 必须说明工具会在用户本地下载并修改 OpenAI Codex 的 Apache-2.0 模型目录。
- 如果未来在 Release 中直接分发修改后的完整 catalog，必须同时保留适用的上游 LICENSE、NOTICE 和修改说明。
- 项目名、描述和页面必须醒目标明“非官方社区工具”。

## 28. 实施顺序

1. 在本仓库内重新阅读本规格，不直接复制临时目录中的未经审计代码。
2. 重新验证当前上游代码、Issue 和配置文档。
3. 定义两个脚本完全一致的命令和退出码。
4. 先实现纯函数式的 catalog 校验和修改。
5. 实现 config 顶层键安全编辑。
6. 实现状态文件、备份和 rollback。
7. 实现版本与 Codex home 发现。
8. 实现下载和离线 catalog 输入。
9. 实现 doctor/status 输出。
10. 编写 fixtures 和平台测试。
11. 在临时 `CODEX_HOME` 中进行破坏性故障注入测试。
12. 编写中英文 README。
13. 运行本机测试和可运行的静态检查。
14. 配置 Windows/macOS GitHub Actions。
15. 只在所有自动测试和 Release 产物复验通过后发布 v0.1.0；发布 Windows/macOS ZIP、两个独立脚本和 `SHA256SUMS.txt`，并准确披露未执行的人工测试。

## 29. 参考资料

- 上游 Issue：<https://github.com/openai/codex/issues/31894>
- Codex 0.144.1 模型目录：<https://github.com/openai/codex/blob/rust-v0.144.1/codex-rs/models-manager/models.json>
- Responses 请求构造：<https://github.com/openai/codex/blob/rust-v0.144.1/codex-rs/core/src/client.rs>
- 工具规划：<https://github.com/openai/codex/blob/rust-v0.144.1/codex-rs/core/src/tools/spec_plan.rs>
- Web Search 扩展限制：<https://github.com/openai/codex/blob/rust-v0.144.1/codex-rs/ext/web-search/src/extension.rs>
- Responses Lite 工具不可见 Issue：<https://github.com/openai/codex/issues/31894>
- Responses Lite 工具执行相关 Issue：<https://github.com/openai/codex/issues/31875>
- Azure/custom provider Lite header Issue：<https://github.com/openai/codex/issues/31870>
- Catalog metadata/provider capability Issue：<https://github.com/openai/codex/issues/31882>
- Collaboration namespace Issue：<https://github.com/openai/codex/issues/31864>
- Deferred multi-agent tools Issue：<https://github.com/openai/codex/issues/32086>
- Code mode/deferred MCP discovery Issue：<https://github.com/openai/codex/issues/32101>
- Codex 配置参考：<https://learn.chatgpt.com/docs/config-file/config-reference#configtoml>
- Codex 高级配置与 profile：<https://learn.chatgpt.com/docs/config-file/config-advanced#profiles>
- Codex 贡献规范：<https://github.com/openai/codex/blob/main/docs/contributing.md>

## 30. 最终原则

这个项目的价值不是“把三处 true 改成 false”。真正需要交付的是：

```text
一个普通用户敢运行、看得懂、不会偷偷上传秘密、失败时不破坏配置、升级后能发现过期、并且能够完整回滚的社区工具。
```

它还必须满足：

```text
修复复杂度留在仓库内部，用户只运行一个小型外部补丁。
不修改 Codex，不修改服务端，不要求 provider 额外适配。
```

任何实现选择都应优先满足这个原则，而不是追求更炫的安装方式或更复杂的架构。

## 31. 核心宗旨合规审计

### 31.1 当前文档审计结果

截至 2026-07-11，本仓库现有 README、项目规格和实施提示词已经按以下问题完成检查：

| 审计项 | 当前结果 |
|---|---|
| 是否把修改 Codex 客户端源码作为社区方案 | 否 |
| 是否要求重新编译或替换 Codex 可执行文件 | 否 |
| 是否修改 Codex/OpenAI 服务端 | 否 |
| 是否要求修改第三方 provider/代理服务端 | 否 |
| 是否提供 API 中转或密钥托管 | 否 |
| 是否要求普通用户研究 provider 协议 | 否 |
| 是否要求普通用户抓包或直接调用 API | 否 |
| 是否要求普通用户手工编辑 catalog/config | 否，脚本负责生成和更新 |
| 是否只修改 Codex home 下的用户文件 | 是 |
| 是否提供自动备份、状态检查和 rollback | 是，已写入实施规范 |
| 是否保持用户主流程简单 | 是：运行脚本、重启、新建任务 |
| 是否把上游源码修改和官方 PR 与社区工具区分 | 是 |

文档中仍包含上游源码、Issue、provider 直连和请求捕获等内容，但这些只属于根因证明、维护者测试和官方长期修复研究，不属于普通用户安装步骤，也不授权实现客户端或服务端修改。

### 31.2 实现完成后的强制复审

在 v0.1.0 交付前，实施任务必须重新检查整个仓库，包括脚本、测试、workflow 和 README，并确认：

1. 生产脚本只写入选定 Codex home 下的 catalog、config、cache backup、state 和 lock 文件。
2. 不下载、覆盖或注入 Codex 可执行文件。
3. 不启动代理、中转、常驻服务或远程修复服务。
4. 不读取 `auth.json`、API Key 或 Authorization。
5. 不要求用户修改 provider、base URL、header 或服务端。
6. 默认路径不要求 `--catalog-file`、`--codex-version` 等高级参数；能自动发现时直接完成。
7. 普通用户文档的首要路径只有下载、运行、重启、新建任务。
8. 任何无法自动安全处理的状态都应零写入退出，并提供 rollback/诊断，而不是要求用户自行适配协议。

只有这八项全部通过，项目才符合核心定位并可以交付。
