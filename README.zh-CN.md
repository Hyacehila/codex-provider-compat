# Codex Provider Compatibility

在自定义 OpenAI-compatible provider 中使用 GPT-5.6 Sol、Terra 或 Luna 时，恢复突然消失的 Codex 工具。

[English](README.md) · [下载 v0.2.0](https://github.com/Hyacehila/codex-provider-compat/releases/tag/v0.2.0) · [自动测试](https://github.com/Hyacehila/codex-provider-compat/actions/workflows/test.yml)

如果 Codex 还能正常聊天，但换到这些模型后突然出现下面一种或多种情况，你可能遇到了这个兼容问题：

- shell/exec、终端命令或 code mode 不再执行；
- 函数、MCP、协作或扩展工具消失；
- 其他原本可用的工具失效，例如 Web Search。

有时 Codex 会用文字描述它准备做什么，却始终不真正调用工具。如果换回其他模型后功能恢复，而且你配置了自定义 provider，可以先运行 `doctor` 检查。

你不需要抓包、研究 provider 协议、手工调用 API，也不用自己编辑 JSON 或 TOML。正常流程只有：

```text
下载并校验 -> doctor -> apply -> 完全退出并重启 Codex -> 新建任务
```

> 这是一个非官方社区项目，不是 OpenAI 产品，也不代表 OpenAI 或任何 API provider。

## 如何使用

### 让 AI 帮你处理

如果你的本地 AI 助手能够操作终端、访问本地文件并下载文件，可以把下面的提示词直接发给它。AI 会替你检查并运行工具；真正安装补丁前，你只需要确认一次。

```text
请帮我在这台电脑上安全地检查并安装 Codex Provider Compatibility；如果不适用，就保持现状并告诉我原因。

必须遵守以下规则：
1. 只使用官方 GitHub 仓库 https://github.com/Hyacehila/codex-provider-compat 及其最新的稳定版、非 prerelease Release。不要优先克隆源码仓库，也不要使用 curl | sh、irm | iex 等无法预先审阅的不透明管道命令。
2. 自动判断当前电脑是 Windows 还是 macOS，下载对应平台的 Release ZIP 和 SHA256SUMS.txt，按照发布记录校验 ZIP 的 SHA-256。校验成功后解压到临时目录，并先检查包内 README 和脚本，再运行任何命令。
3. 首先运行 doctor，它必须保持只读。如果哈希不匹配、Release 不适用、doctor 判断无需补丁、版本存在冲突、需要事务恢复，或者状态不安全、有歧义，立即停止，不执行 apply，并用简单的话向我说明结果。
4. 只有 doctor 明确确认适合 apply 时，才向我说明脚本将修改和备份哪些文件，并向我请求一次明确确认。得到确认前不得执行 apply；确认后使用 --yes 执行，避免再次询问。
5. apply 成功后运行 status，报告补丁是否健康，并列出脚本报告的生成 catalog、config 备份、cache 备份和状态文件位置。
6. 不得读取 auth.json、API Key、token 或 provider 凭据；不得调用真实 provider，也不得产生模型调用或搜索费用；不得打印或上传私人配置与诊断信息。
7. 不得修改 Codex 二进制、应用包、源码、服务端或 provider 配置；不得手工编辑 JSON/TOML、绕过脚本的安全检查，也不要使用已经移除的 --enable-web-search 参数。
8. 如果你没有终端、本地文件或下载权限，立即停止，并引导我阅读仓库 README 后面的手动操作方法。没有完成校验和操作时，不得声称已经成功。
9. 全部完成后，提醒我完全退出并重新启动 Codex，然后新建任务；重新打开旧任务并不能应用这次更改。
```

AI 必须能够访问安装 Codex 的这台电脑。只能聊天、不能操作本地环境的 AI 无法完成这些步骤，请改用下面的手动方法。

### 希望手动操作？

下面保留了完整的手动操作流程。

#### 先检查是否适用

补丁只针对自定义 provider 中的 GPT-5.6 Sol（`gpt-5.6-sol`）、Terra（`gpt-5.6-terra`）和 Luna（`gpt-5.6-luna`）。其他模型以及 Codex 内置 OpenAI 连接不适用。

每次都先运行 `doctor`。它只读检查本机版本、配置和安全状态，不会写入文件。只要脚本无法确认操作安全，就会停止并保持现有配置不变。

#### 下载并校验 v0.2.0

打开 [v0.2.0 Release 页面](https://github.com/Hyacehila/codex-provider-compat/releases/tag/v0.2.0)，下载 `SHA256SUMS.txt` 和对应平台的压缩包：

| 平台 | 文件 |
|---|---|
| Windows | `codex-provider-compat-v0.2.0-windows.zip` |
| macOS | `codex-provider-compat-v0.2.0-macos.zip` |

Windows 校验：

```powershell
(Get-FileHash .\codex-provider-compat-v0.2.0-windows.zip -Algorithm SHA256).Hash.ToLowerInvariant()
Get-Content .\SHA256SUMS.txt
```

macOS 校验：

```sh
shasum -a 256 ./codex-provider-compat-v0.2.0-macos.zip
cat ./SHA256SUMS.txt
```

计算结果必须与 `SHA256SUMS.txt` 中对应压缩包的记录一致。然后解压，阅读包内 README 和脚本，再运行。Release 页面也提供独立的 `.ps1` 和 `.sh` 文件供审阅。项目不会推荐无法预先查看内容的 `curl | sh` 或 `irm | iex` 管道命令。

#### Windows

支持 Windows PowerShell 5.1 和 PowerShell 7.5 及以上版本，不需要额外运行时。

```powershell
Get-Content .\codex-provider-compat.ps1
.\codex-provider-compat.ps1 doctor
.\codex-provider-compat.ps1 apply
```

如果 Windows 阻止已经校验过的脚本，可以只为当前进程临时放行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\codex-provider-compat.ps1 doctor
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\codex-provider-compat.ps1 apply
```

#### macOS

脚本只使用 macOS 自带工具，不需要 Homebrew、Python、Node 或 `jq`。

```sh
less ./codex-provider-compat.sh
chmod +x ./codex-provider-compat.sh
./codex-provider-compat.sh doctor
./codex-provider-compat.sh apply
```

#### 重启并新建任务

`apply` 成功后，完全退出并重新启动 Codex，然后新建任务。旧任务保留启动时的模型与工具快照，只重启应用再继续旧任务是不够的。

本工具不会开启、关闭或管理任何单项工具。

#### 检查或撤销补丁

```powershell
.\codex-provider-compat.ps1 status
.\codex-provider-compat.ps1 rollback
```

```sh
./codex-provider-compat.sh status
./codex-provider-compat.sh rollback
```

rollback 只撤销本工具写入的内容，保留 `apply` 之后用户对其他配置的修改。回滚后也要重启 Codex 并新建任务。

如果 `doctor` 或 `status` 显示 `recovery-required`，不要手工删除 lock、transaction 或 pending 文件。再次运行原本要执行的 `apply` 或 `rollback`，脚本会先恢复被中断的操作。已选 profile、项目配置或 CLI 参数仍可能覆盖健康的用户级补丁。

Codex 更新后重新运行 `status` 和 `doctor`。不要在未检查的情况下继续使用旧 catalog 覆盖。

如果你在 v0.1.1 中使用过现已移除的 `--enable-web-search`，并希望工具不再拥有该旧修改，请使用 v0.2.0 运行 `rollback`，重启 Codex，再执行普通 `apply` 并重新启动到新任务。新版本不会改变你的搜索设置。

#### 命令和自动化

| 命令 | 作用 |
|---|---|
| `doctor` | 只读检查适用性和安全状态 |
| `apply` | 校验、备份并安装补丁 |
| `status` | 检查已安装的补丁和版本 |
| `rollback` | 只撤销本工具拥有的修改 |

两个脚本都接受 `--yes`、`--dry-run`、`--codex-home <absolute-path>`、`--codex-version <version>` 和 `--catalog-file <absolute-path>`。大多数用户不需要这些参数。脚本会自动寻找 Codex home 和版本；发现版本冲突时，`apply` 会停止。

| 退出码 | 含义 |
|---:|---|
| 0 | 成功或状态健康 |
| 1 | 一般用法或操作错误 |
| 2 | 不适用、未安装或官方已经修复 |
| 3 | 状态不安全、有歧义、损坏、漂移或需要恢复 |
| 4 | 补丁或官方 catalog 格式已不再兼容 |
| 5 | 官方 catalog 下载、HTTP、超时或大小错误 |

## 想了解原因

### 工具为什么会消失

Codex 模型目录把三个目标模型标记为使用一种内部请求格式：Responses Lite。在这个模式下，Codex 通过 `additional_tools` 描述客户端工具，而不是公开 Responses API 常见的顶层 `tools` 字段。

Codex 内置的 OpenAI 链路能理解这种格式。许多自定义 OpenAI-compatible provider 只实现了公开 Responses 格式，没有实现 Codex 额外使用的 Lite 格式。它们收不到标准工具定义，于是文字回复仍然正常，终端、函数、MCP、协作、扩展或 hosted 工具却消失了。

```text
目标模型使用 Responses Lite
    -> Codex 发送内部 additional_tools
    -> 标准顶层 tools 缺失或为 null

补丁为三个目标模型禁用 Lite
    -> Codex 重新发送标准 Responses tools
    -> provider 可以暴露它真正支持的工具
```

Lite 还会影响 instructions、并行工具调用、reasoning context、图片 detail 和内部 header/metadata。搜索只是可能受影响的工具之一；补丁不会配置搜索，也不能保证 provider 实现搜索。

### 补丁具体做什么

补丁 ID 是 `responses-lite-standard-tools`。脚本检测 Codex 版本，从对应的 `openai/codex` 官方 tag 获取完整模型目录，只把 Sol、Terra 和 Luna 的 `use_responses_lite` 从 `true` 改为 `false`。目标缺失、目录不完整、模型重复、字段类型错误或出现其他语义变化时，操作都会停止。

脚本把生成的目录写入选定的 Codex home，备份 config 和模型 cache，只更新用户级 `model_catalog_json`，并记录 `status`、恢复和 rollback 所需的最少状态。它不会修改当前模型、provider、provider table、单项工具设置或其他无关配置。

### 安全和能力边界

对 Codex 的持久修改都限制在选定的 Codex home 内。脚本会校验路径和文件所有权，拒绝 Windows junction/reparse point 与 macOS symlink 路径逃逸，保留无关 TOML 内容和权限，并使用锁、备份、原子替换和事务记录。状态有歧义或不安全时直接停止。

生产工具不会读取 `auth.json` 或 API Key，不会访问 provider API、上传数据、收集遥测、托管密钥、修改 Codex 二进制或源码、修改任何服务端，也不是 API 中转服务。

补丁只能恢复标准工具定义，不能替 provider 实现它没有的能力。自动测试覆盖 Windows PowerShell 5.1/7、macOS shell/JXA、catalog 与 TOML 完整性、路径安全、失败恢复、Release 压缩包，以及固定 Codex CLI 到 localhost 的 Lite/标准请求形态。

维护者还在 Windows 临时 Codex home 中测试了一个匿名真实 Responses provider。已记录的验收结果中，三个模型都通过了普通文本和多轮测试；Sol、Terra 通过了 shell/exec；三个模型都通过了协作测试；Sol 完成了本地 MCP 调用和结果回传。该 provider 的图片输入失败。code mode 的可观测证据、app-server dynamic function、显式 original 图片 detail 和图片生成仍是 `not-run`，原因是现有客户端路径无法同时满足凭据隔离或确定性取证要求。测试没有公开凭据、端点、原始请求或原始响应，真实 Codex home 前后也没有变化。

目前没有可用的真实 Mac Desktop 环境，因此 macOS Codex Desktop 行为同样标记为 `not-run`。一个 provider 的结果不能代表所有 OpenAI-compatible 服务。

项目使用 [MIT License](LICENSE)。运行时下载的完整模型目录来自 Apache-2.0 的 [`openai/codex`](https://github.com/openai/codex) 仓库，详见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
