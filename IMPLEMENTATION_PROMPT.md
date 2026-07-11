# 仓库实施任务提示词

下面的提示词用于在 `codex-provider-compat` 仓库根目录启动一个新的 Codex 任务。公开仓库是 <https://github.com/Hyacehila/codex-provider-compat>。请从“任务提示词开始”复制到新任务中使用。

---

## 任务提示词开始

你正在当前 `codex-provider-compat` 仓库根目录中开发一个非官方、开源、跨平台的 Codex 自定义 provider 社区兼容工具。不要到仓库外的旧副本或临时目录继续工作，也不要假设之前的诊断或修复实现一定正确。你必须在当前仓库中从环境发现、事实校验、实现、故障注入测试、文档和交付全流程完成任务。

### 一、首先阅读并遵守仓库规格

开始任何实现前，完整阅读：

- `README.md`
- `PROJECT_SPEC.md`
- 本文件 `IMPLEMENTATION_PROMPT.md`

`PROJECT_SPEC.md` 是产品、安全、行为、测试和交付的主要规范。如果实际环境或当前上游源码与规格冲突，必须先收集证据，更新规格中的过时事实，再实施；不能默默按旧假设编码。

### 核心交付边界（不可改变）

这个项目只能交付一个运行在用户本机、通过 Codex home 中的 catalog/config/backup 文件生效的小型外部补丁。

无论调查结果如何，社区工具都不得：

- 修改、重新编译、替换或注入 Codex CLI、Desktop、客户端或 app-server；
- 修改 OpenAI/Codex 服务端；
- 修改或要求修改第三方 provider/代理服务端；
- 实现 API 中转、密钥托管或远程修复服务；
- 要求普通用户研究 provider 协议、抓包、直接调用 API 或手工编辑 JSON/TOML。

上游源码只用于自动发现根因、校验版本和设计测试。可能的官方 PR 是独立长期工作，不属于社区工具的安装或运行方案。

普通用户的目标流程必须保持为：

```text
下载 -> 运行脚本 -> 重启 Codex -> 新建任务
```

脚本自动负责版本发现、完整 catalog 获取与修改、配置备份、原子写入、缓存备份、状态检查和 rollback。如果无法安全完成，保持原系统不变并给出简单错误；不要把协议调查工作推给用户。

### 二、任务目标

实现一个简单、透明、无需第三方运行时的社区工具，用于诊断和修复以下组合中的 Codex Responses Lite 工具兼容问题：

- 模型为 `gpt-5.6-sol`、`gpt-5.6-terra` 或 `gpt-5.6-luna`；
- 模型目录将其标记为 `use_responses_lite = true`；
- 用户使用普通自定义 OpenAI-compatible provider；
- provider 支持标准 Responses 顶层工具定义，但不实现 Codex 内部 Responses Lite `additional_tools` 协议；
- Codex 发送的顶层 `tools` 为 `null`，造成 exec/code mode、函数/MCP、namespace、扩展工具或 hosted 工具中的一个或多个能力不可见；
- 对 Web Search 而言，hosted `web_search` 被跳过，而独立 `web/run` 又因 provider 身份限制不注册。

工具的首个补丁 ID 为 `responses-lite-standard-tools`。它需要根据当前 Codex 版本获取完整官方模型目录，仅把三个目标模型的 `use_responses_lite` 改为 `false`，让模型回到标准 Responses 请求形态，然后安全地设置用户级 `model_catalog_json`，备份配置和缓存，并提供诊断、状态检查和精确回滚。

Web Search 是关键验收场景，但不是仓库唯一目标。必须研究并测试 exec/shell/code mode、function/MCP/dynamic tools、collaboration namespace、图片与扩展工具，以及 Lite 模式下 instructions、parallel tool calls、reasoning context、图片 detail 和内部 header 的变化。不要未经测试声称所有能力都已修复。

### 三、必须重新发现和验证问题

不要只相信提示词。实施前必须完成只读调查并记录结果：

1. 检查当前仓库状态、分支和已有文件。
2. 检测本机：
   - 操作系统；
   - `CODEX_HOME`；
   - PATH 中的 `codex --version`；
   - Codex Desktop/app-server 的候选版本；
   - CLI 和 Desktop 是否版本一致。
3. 使用 `openai-docs` skill，并只依赖当前官方 OpenAI/Codex 文档和 `openai/codex` 官方仓库确认：
   - 用户级 `config.toml` 的位置；
   - `model_catalog_json` 是启动时加载的完整模型目录；
   - CLI、project config、选中的独立 profile 文件和用户配置的真实结构与优先级；
   - 内置/default provider ID，以及 `openai_base_url` 或自定义 provider 定义覆盖该 ID 时为何不能仅凭名称断定请求进入官方后端；
   - 当前目标模型的 `use_responses_lite`；
   - Lite 请求的 `additional_tools` 和顶层 `tools` 行为；
   - exec/code mode、function/MCP、namespace 与 hosted 工具在 Lite 下的规划和序列化；
   - hosted Web Search 在 Lite 下的特殊双路径行为；
   - `web/run` 扩展的 provider 限制；
   - Issue `#31894` 的当前状态；
   - Issues `#31875`、`#31870`、`#31882`、`#31864`、`#32086`、`#32101` 及其他直接相关官方 Issue 的当前状态；
   - 历史提示中曾引用的 `#31853`、`#31872` 是否仍为相关 Issue；若编号已对应无关内容，必须明确纠错；
   - 当前最新 Codex release 和 main 是否已经官方修复。
4. 对检测到的 Codex 版本下载官方完整 `models.json`，只读验证：
   - 模型数量；
   - 三个目标 slug 是否存在；
   - 它们当前的 Lite 状态；
   - catalog 中是否出现其他新的 Lite 模型；这些模型只报告，不得未经验证自动加入补丁。
5. 如果官方已经彻底修复，不能继续盲目开发 apply 行为。应把工具调整为 doctor/rollback/历史兼容用途，并在 README 中说明。

调查期间不要修改用户真实 `config.toml`、真实 catalog、真实缓存或真实 API provider。

### 四、实现范围

保持仓库简单，实施以下文件：

```text
README.md
README.zh-CN.md
PROJECT_SPEC.md
IMPLEMENTATION_PROMPT.md
codex-provider-compat.ps1
codex-provider-compat.sh
LICENSE
THIRD_PARTY_NOTICES.md
tests/fixtures/*
tests/test-windows.ps1
tests/test-macos.sh
.github/workflows/test.yml
```

除非经过证据证明绝对必要，不要引入 Python package、Node package、Go module、Rust crate、Docker、数据库、Web UI 或服务端。

### 五、平台要求

Windows：

- 使用一个 PowerShell 脚本。
- 只依赖 PowerShell/.NET 内置能力。
- 不要求 Python、Node、`jq`、Chocolatey 或 Scoop。

macOS：

- 使用一个 shell 脚本。
- 只依赖系统自带 shell、`curl`、`awk`、`shasum` 和 `osascript -l JavaScript`。
- 不假设 Python 3、Node、Homebrew、`jq` 或 GNU 工具存在。

两个脚本必须拥有相同的状态文件 schema、相同的命令、相同的核心安全语义和尽可能一致的输出。

### 六、公共命令

必须实现：

```text
doctor
apply
status
rollback
```

公共参数至少包括：

```text
--yes
--dry-run
--codex-home <absolute-path>
--codex-version <version>
--catalog-file <absolute-path>
--enable-web-search
```

允许根据平台语法做最小差异，但 README 必须清楚展示。

定义并记录稳定退出码，例如：

- `0`：成功或状态健康；
- `1`：一般错误；
- `2`：不适用；
- `3`：检测到不安全或歧义状态；
- `4`：补丁过期；
- `5`：网络或上游 catalog 获取失败。

不要让用户解析自然语言来判断自动化结果。

### 七、实现算法

#### 1. Codex home

优先使用显式参数，其次 `CODEX_HOME`，最后默认 `~/.codex`。将路径规范化为绝对路径，并在任何写入前验证目标位于该 Codex home 内。禁止对根目录、空路径或 Codex home 外部执行递归移动、删除或覆盖。

所有写路径还必须拒绝 Windows junction/reparse point。macOS 只允许先把 Apple 固定的 `/var`、`/tmp`、`/etc` 系统别名规范化到 `/private/...`，随后拒绝其他 symlink 组件和 symlink leaf。rollback 不得信任状态文件给出的任意路径，而要按 Codex home、版本和固定命名规则重建预期路径，并严格校验 backup/archive/pending 文件名。`--catalog-file` 可以是 home 外只读输入，但永远不能成为写入、移动或删除目标。

#### 2. 版本发现

探测 PATH CLI、运行中 app-server、Codex home 用户态 app-server 副本和平台常见 Desktop 路径。不要硬编码 Windows Store 的具体包版本。如果发现多个不同版本，默认停止 apply，并要求显式 `--codex-version`。

#### 3. Catalog 获取

优先使用用户提供的 `--catalog-file`。否则从与版本严格匹配的官方 tag 获取：

```text
https://raw.githubusercontent.com/openai/codex/rust-v<version>/codex-rs/models-manager/models.json
```

默认禁止从第三方域名下载。设置超时和大小限制。下载到临时文件，下载或校验失败时不得触碰 config 和 cache。

下载必须禁用重定向，只接受严格构造的 HTTPS 官方 URL。Windows PowerShell 5.1 显式加载 `System.Net.Http`，使用总超时、取消 token、`Content-Length` 和流式大小上限；macOS curl 禁止 `-L`、限制 HTTPS、连接/总超时和响应大小。网络/HTTP/空响应/超大响应返回 5，官方 schema 或目标过期返回 4，本地 catalog 无效返回 3。

#### 4. Catalog 校验

确认输入是完整模型目录，不是只包含三个模型的最小 JSON：至少包含 8 个模型和至少 5 个非目标模型。确认所有 slug 唯一，三个目标模型各存在一次，`use_responses_lite` 是布尔值。对原对象、修改对象和序列化后重新解析对象执行递归语义深比较，确保除三个目标布尔值之外没有其他差异。

目标模型：

```text
gpt-5.6-sol
gpt-5.6-terra
gpt-5.6-luna
```

输出路径：

```text
$CODEX_HOME/model-catalogs/models-<version>.standard-responses-compat.json
```

通过同目录临时文件、重新读取校验、SHA-256 和原子重命名完成写入。

#### 5. Config 修改

修改用户级 `$CODEX_HOME/config.toml`。写前生成：

```text
config.toml.bak-provider-compat-YYYYMMDD-HHMMSS
```

基础补丁只修改或插入顶层：

```toml
model_catalog_json = "<absolute-generated-catalog-path>"
```

只有显式传入 `--enable-web-search` 时才允许额外设置：

```toml
web_search = "live"
```

不要修改 `model`、`model_provider`、任何 provider table 或其他配置。保留注释、section、换行风格和用户格式。检测重复顶层键时停止，不猜测。路径写入 TOML 时处理 Windows 转义，优先使用正斜杠。

必须使用词法扫描器而不是逐行正则，正确跟踪四种 TOML 字符串、注释、数组、inline table、table/array-table 和 quoted key。复杂、dotted、重复或无法无损编辑的 owned key 必须 fail closed。保留 BOM、LF/CRLF、尾随换行和权限；原 config 不存在时 rollback 恢复为不存在。确认后重新读取 config 并比较 SHA-256，发现 TOCTOU 时最多重新规划和确认一次。

#### 6. Cache

如果存在 `$CODEX_HOME/models_cache.json`，只改名为带时间戳的备份，不永久删除。

#### 7. 状态文件

写入 `$CODEX_HOME/provider-compat-state.json`，记录 `patch_id = responses-lite-standard-tools`、补丁版本、Codex 版本、catalog 来源与哈希、生成文件哈希、config 原值和备份、cache 备份及时间。禁止记录 secret、完整 config 或 API 请求。

另写 schema 1 的 `$CODEX_HOME/provider-compat-transaction.json`。apply/rollback 在第一次状态变更前记录 operation、phase、nonce、固定路径和必要哈希；每个阶段原子推进。失败或 SIGINT/SIGTERM 时恢复，SIGKILL/断电遗留由 doctor/status 只读报告为 `recovery-required`，下一次 mutating command 加锁后自动恢复。日志不得包含完整 config 或秘密。

#### 8. 幂等

第二次 apply 在状态完全一致时返回成功并报告 already-applied，不重复写键或制造备份。版本变化、catalog 漂移、config 漂移必须被 status 检测。

#### 9. Rollback

rollback 只恢复工具拥有的顶层键，保留用户之后的其他配置修改。只有生成 catalog 哈希与状态一致时才删除它。cache 原路径已有新文件时不得覆盖。完整 config 备份只作为人工恢复手段。

rollback 自身必须是事务：先保存当前 config，把 catalog 改名为 nonce 绑定的 pending 文件，再执行可逆的 cache/config/state 操作；全部验证后才永久清理 pending。任一阶段失败时恢复到 rollback 前状态。

#### 10. 重启提示

apply 和 rollback 最后必须明确输出：

```text
完全退出并重新启动 Codex，然后新建任务/新 thread。
旧任务保留启动时的模型与工具快照，不会自动应用本次更改。
```

### 八、安全与隐私硬约束

- 不读取 `auth.json`。
- 不读取或打印 API Key 环境变量。
- 不访问用户 provider API，除非未来用户显式运行独立、明确可计费的测试命令；v0.1 不需要该命令。
- 不上传 config、日志或诊断数据。
- 不实现遥测。
- 不修改系统全局文件、Codex 二进制或应用包。
- 不修改 Codex 客户端源码、app-server 或任何服务端。
- 不要求用户或 provider 做额外协议适配。
- 不直接删除 config、cache 或用户 catalog。
- 不执行递归删除。
- 不输出完整 provider URL 中可能包含的 query secret。
- 所有异常路径都应保持原配置可用。

### 九、极致完整的测试要求

在写实现前先根据 `PROJECT_SPEC.md` 建立测试清单。实现过程中增量运行，不能最后一次性补测试。

所有写操作测试必须使用临时 `CODEX_HOME`。在测试前后记录真实 Codex home 的关键文件哈希或状态，确认测试未碰真实环境。

至少覆盖：

#### Catalog

- 完整有效输入；
- 三个目标模型修改；
- 发现并报告其他 Lite 模型，但不修改；
- 状态文件包含正确的 `patch_id`；
- 其他模型与字段不变；
- 已经为 false；
- 缺少目标；
- 重复 slug；
- 空模型数组；
- 非法和截断 JSON；
- 错误字段类型；
- 伪最小 catalog；
- 网络 404/500/超时/空响应/超大响应；
- 不存在的 Codex tag。

#### Config

- 文件不存在、空文件、简单配置、复杂 provider sections；
- 注释、空行、CRLF、LF、BOM；
- 已有 catalog；
- 已有 live/cached/indexed/disabled；
- section 或注释中出现相似文本；
- 重复顶层键；
- 路径含空格和中文；
- 所有无关配置保持不变。

#### 文件安全

- 备份唯一；
- 原子写入；
- 写入中断；
- 权限失败；
- 目录不存在；
- 锁竞争；
- 失效锁；
- config 更新失败时不留下指向无效 catalog 的状态。

#### Cache

- 不存在；
- 正常备份；
- 备份冲突；
- rollback；
- 原路径有新 cache 时不覆盖。

#### 状态和回滚

- 首次 apply；
- 重复 apply；
- status 健康；
- catalog/config 漂移；
- Codex 升级后 stale；
- 状态文件损坏；
- 用户 apply 后修改其他配置，rollback 保留修改；
- dry-run 零写入。

#### 版本发现

- CLI only、Desktop only、相同版本、冲突版本、显式版本、异常输出、无法检测。

#### 平台

- Windows 本机完整运行 PowerShell 测试。
- macOS 行为由 `macos-latest` GitHub Actions 验证。
- 当前非 macOS 环境无法真实运行 JXA 和 macOS 文件语义时，本地只能声称实际执行过的 shell 语法检查；不得把 JXA 或 macOS 生命周期写成已本地通过。应明确区分本地静态检查、CI 配置和实际 Actions 结果。

#### 可选请求形态集成测试

研究是否能在临时 Codex CLI 和本地 mock Responses server 中可靠重现：

- 补丁前顶层 `tools` 缺失；
- 补丁后新任务恢复标准顶层工具定义，并分别检查 exec/code mode、function/MCP/namespace 和 hosted `web_search`。

只有在不显著复杂化仓库、且不会使用真实凭据时才实施。mock 只能证明实际捕获到并指向 localhost 的模型请求形态；除非另有操作系统级网络监控证据，不得声称它能发现所有静默远程 socket。没有独立 code-mode fixture 时，不能把普通 exec/shell 工具暴露写成 code mode 已通过。若不实施某项能力，在测试报告中明确剩余风险和人工验收步骤。

#### 能力回归矩阵

分别建立测试或明确的人工验收步骤，记录以下能力的结果，不能用单一 Web Search 用例代替：

- hosted Web Search；
- exec/shell；
- code mode namespace；
- 普通 function calling；
- MCP 和 dynamic tools；
- collaboration/multi-agent namespace；
- image generation/extension tools；
- 普通无工具文本；
- 多轮历史；
- 图片 detail；
- reasoning context；
- parallel tool calls；
- Lite header/metadata 是否按预期消失或变化。

每项结果使用 `passed`、`failed`、`not-supported` 或 `not-run`，并标明是 fixture、mock、CI 还是真实 provider 测试。

### 十、文档要求

完成中英文 README，面向普通用户而不是只面向开发者。必须详细解释：

- 症状；
- 根因；
- 为什么非 Lite 模型正常；
- 为什么官方 provider 通常不同；
- 工具做什么；
- 工具不做什么；
- 普通用户只需运行脚本、重启并新建任务；
- 用户无需研究 provider、抓包、调用 API 或手工替换文件；
- 为什么仓库定位是 provider/Responses 兼容，而不是 Web Search 单点修复；
- 首个补丁 ID 和未来补丁扩展边界；
- 适用与不适用条件；
- Windows 和 macOS 步骤；
- 所有修改文件；
- 备份和 rollback；
- Codex 更新后的 catalog 过期风险；
- 禁用 Lite 会改变整个请求协议形态，不只是 Web Search；
- provider 必须支持所测试能力对应的标准 Responses 工具定义；
- 搜索可能收费；
- 必须重启并新建任务；
- 官方修复后的卸载方法；
- 非官方声明、隐私和许可证。

首次公开源码交付的主要安装路径应指向 <https://github.com/Hyacehila/codex-provider-compat>，让用户选择经 Actions 验证的固定 commit，下载该 commit 的 ZIP 或 clone 后 checkout 到它，验证脚本 SHA-256、查看脚本后再执行。只有未来真正发布带稳定产物和校验和的 GitHub Release 后，README 才可把 Release 改为主要安装入口。不要只提供不透明的一键管道命令。

### 十一、GitHub Actions 和发布准备

建立最小 workflow：

- Windows job 运行 PowerShell 测试。
- macOS job 运行 shell/JXA 测试。
- 检查脚本语法。
- 所有测试使用临时 home。

不要推送远程、创建公开仓库、发布 Release 或提交上游 Issue/PR，除非用户在该任务中明确授权。可以准备 Release checklist 和建议命令。

### 十二、工作方式

- 先调查，再实现。
- 在重要阶段向用户简短报告正在验证什么、发现了什么。
- 实现前说明即将编辑哪些文件。
- 使用现有仓库，不创建无关子项目。
- 保持代码小而清楚，避免过度抽象。
- 不因为仓库目标简单而降低测试强度。
- 不停止在建议或半成品；在当前环境允许的范围内完成实现、测试和文档。
- 遇到当前环境无法执行的 macOS 或远程 CI 项目，完成可验证的本地部分，并明确列出未实际运行的内容。
- 不修改当前仓库外的其他项目、旧副本或临时目录中的文件。
- 不把当前用户真实修复文件当作测试沙箱；可以只读参考，但不得破坏。

### 十三、最终交付标准

最终回答前必须完成：

1. 展示最终仓库文件清单。
2. 展示 Git diff 和工作树状态。
3. 运行并报告所有可运行测试。
4. 用临时 `CODEX_HOME` 完成至少一次 apply/status/rollback 完整周期。
5. 确认真实 Codex home 未被测试修改。
6. 确认三个目标模型的修改和完整目录保护都有自动测试。
7. 确认 config 的注释、sections 和无关键保护有自动测试。
8. 确认失败注入不会留下半写文件。
9. 确认 README 中英文版包含全部风险和重启说明。
10. 明确列出未执行的测试、剩余风险和需要 GitHub Actions 验证的项目。
11. 执行一次核心宗旨审计：搜索仓库是否包含修改 Codex 二进制/源码、修改服务端、代理 API、托管密钥或要求用户适配 provider 的实现与说明；发现任何此类交付路径都必须删除或改为纯研究背景。
12. 确认普通用户主流程可以浓缩为“运行脚本、重启 Codex、新建任务”，且 apply/rollback 不要求手工编辑文件。
13. README 中的测试结论只引用最终 commit 实际执行过的证据；不得保留固定 case 数、旧脚本的连续通过次数或未经本轮 Actions 验证的 macOS/JXA 断言。
14. 明确说明 `status = healthy` 只验证工具拥有的用户级文件；选中的 profile、project config 和 CLI/session override 仍可能改变某个任务的有效配置。
15. state/transaction 文档只描述恢复所需的最小补丁与回滚元数据，不得虚构为一个永远不变的排他字段清单。

交付结果必须是一个普通用户能够理解、开发者能够审阅、失败后能够回退的最小社区工具仓库，而不是仅供当前机器使用的一次性脚本。

## 任务提示词结束
