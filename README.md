# Codex Provider Compatibility

Restore missing Codex tools when GPT-5.6 Sol, Terra, or Luna is used through a custom OpenAI-compatible API/provider.

[简体中文](README.zh-CN.md) · [Download v0.1.1](https://github.com/Hyacehila/codex-provider-compat/releases/tag/v0.1.1) · [Automated tests](https://github.com/Hyacehila/codex-provider-compat/actions/workflows/test.yml)

You may need this tool if Codex can still chat, but after selecting one of those models it no longer:

- searches the web or runs terminal commands;
- calls functions, MCP servers, or extension tools;
- uses code mode or collaboration/multi-agent tools.

Codex may describe what it would do but return only text. If the same features work after switching to another model, and you configured a custom API/provider, this compatibility issue is a likely cause.

You do not need to inspect traffic, learn a protocol, call an API by hand, or edit JSON/TOML. The normal path is:

```text
download and verify -> doctor -> apply -> fully restart Codex -> create a new task
```

> This is an unofficial community project. It is not an OpenAI product and is not endorsed by OpenAI or by any API provider.

## How to use

### Check whether it applies

The patch targets only GPT-5.6 Sol (`gpt-5.6-sol`), Terra (`gpt-5.6-terra`), and Luna (`gpt-5.6-luna`) when used with a custom provider. It is not intended for other models or Codex's built-in OpenAI connection.

Always run `doctor` first. It checks local versions, configuration, and safety without writing any files. If the script cannot prove that a change is safe, it stops and leaves the active configuration alone.

### Download and verify v0.1.1

Open the [v0.1.1 Release page](https://github.com/Hyacehila/codex-provider-compat/releases/tag/v0.1.1), then download `SHA256SUMS.txt` and the ZIP for your platform:

| Platform | File |
|---|---|
| Windows | `codex-provider-compat-v0.1.1-windows.zip` |
| macOS | `codex-provider-compat-v0.1.1-macos.zip` |

Verify the Windows ZIP:

```powershell
(Get-FileHash .\codex-provider-compat-v0.1.1-windows.zip -Algorithm SHA256).Hash.ToLowerInvariant()
Get-Content .\SHA256SUMS.txt
```

Verify the macOS ZIP:

```sh
shasum -a 256 ./codex-provider-compat-v0.1.1-macos.zip
cat ./SHA256SUMS.txt
```

The computed value must match the ZIP's entry in `SHA256SUMS.txt`. Extract the package and read its included README and script before running it. Standalone `.ps1` and `.sh` files are also available on the Release page for review. This project does not recommend opaque `curl | sh` or `irm | iex` commands.

### Windows

Windows PowerShell 5.1 and PowerShell 7.5 or later are supported. No extra runtime is required.

```powershell
Get-Content .\codex-provider-compat.ps1
.\codex-provider-compat.ps1 doctor
.\codex-provider-compat.ps1 apply
```

If Windows blocks the verified script, use a process-only execution-policy override:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\codex-provider-compat.ps1 doctor
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\codex-provider-compat.ps1 apply
```

### macOS

The script uses only tools included with macOS; Homebrew, Python, Node, and `jq` are not required.

```sh
less ./codex-provider-compat.sh
chmod +x ./codex-provider-compat.sh
./codex-provider-compat.sh doctor
./codex-provider-compat.sh apply
```

### Restart and create a new task

After `apply` succeeds, fully quit and restart Codex, then create a new task. Old tasks keep the model and tool snapshot captured when they started, so reopening one is not enough.

Web Search is opt-in. If your provider supports the standard Responses `web_search` tool and you want live search, use the following command **instead of** the plain `apply` on your first installation:

```powershell
.\codex-provider-compat.ps1 apply --enable-web-search
```

```sh
./codex-provider-compat.sh apply --enable-web-search
```

If the base patch is already applied, run `rollback` first, restart Codex, and then apply again with `--enable-web-search`. Search may be billable. Working search does not prove that shell, MCP, code mode, or image tools are supported.

### Check or undo the patch

```powershell
.\codex-provider-compat.ps1 status
.\codex-provider-compat.ps1 rollback
```

```sh
./codex-provider-compat.sh status
./codex-provider-compat.sh rollback
```

Rollback removes only changes owned by this tool and preserves unrelated edits made after `apply`. Restart Codex and create a new task after rollback.

If `doctor` or `status` reports `recovery-required`, do not delete lock, transaction, or pending files. Run the intended `apply` or `rollback` command again so it can recover the interrupted operation. A healthy `status` verifies the tool-owned user-level patch, but a selected profile, project configuration, or CLI override can still change what a new task uses. Run `doctor` the same way you launch Codex; if it reports no override and the feature still fails, the provider probably does not implement that feature. Roll back instead of changing provider URLs, headers, or servers for this project.

After a Codex update, run `status` and `doctor` again. Do not keep an old catalog override across an unreviewed version change.

### Commands and automation

| Command | Purpose |
|---|---|
| `doctor` | Read-only applicability and safety check |
| `apply` | Validate, back up, and install the patch |
| `status` | Check the installed patch and version |
| `rollback` | Undo only changes owned by this tool |

Both scripts accept `--yes`, `--dry-run`, `--codex-home <absolute-path>`, `--codex-version <version>`, `--catalog-file <absolute-path>`, and `--enable-web-search`. Most users need none of these. Codex home and version are discovered automatically; a version conflict stops `apply`.

| Exit | Meaning |
|---:|---|
| 0 | Success or healthy state |
| 1 | General usage or operation error |
| 2 | Not applicable, not installed, or already fixed upstream |
| 3 | Unsafe, ambiguous, corrupt, drifted, or recovery-required state |
| 4 | Patch or official catalog format is no longer compatible |
| 5 | Official catalog download, HTTP, timeout, or size failure |

## Want to know why?

### Why the tools disappear

Codex's model catalog currently marks the three target models to use an internal request format called Responses Lite. In this mode, Codex describes client tools through `additional_tools` instead of the standard top-level `tools` field used by the public Responses API.

The built-in OpenAI path understands this format. Many custom OpenAI-compatible providers implement the public Responses format but not Codex's extra Lite format. They receive no standard tool definitions, so text still works while terminal, function, MCP, collaboration, extension, or hosted tools disappear.

```text
target model uses Responses Lite
    -> Codex sends internal additional_tools
    -> standard top-level tools are absent or null

this patch disables Lite for the three target models
    -> Codex sends standard Responses tools again
    -> the provider can expose the tools it supports
```

This is why a non-Lite model often works with the same provider. Web Search has an extra complication: Lite can skip hosted `web_search`, while the separate `web/run` extension is restricted by provider identity. Lite also changes instructions, parallel tool calls, reasoning context, image detail, and internal headers or metadata, so the patch changes the overall request shape rather than only search.

### What the patch does

The patch ID is `responses-lite-standard-tools`. The script detects the Codex version, obtains the complete model catalog from its matching official `openai/codex` tag, and changes only `use_responses_lite` from `true` to `false` for Sol, Terra, and Luna. Any missing target, incomplete catalog, duplicate model, wrong field type, or other semantic change stops the operation.

It writes the generated catalog inside the selected Codex home, backs up configuration and model cache files, updates the user-level `model_catalog_json`, and records the minimum state needed for `status`, recovery, and rollback. Only `--enable-web-search` also adds `web_search = "live"`. The scripts do not change the selected model, provider, provider table, or unrelated settings.

### Safety and limits

Persistent Codex changes stay inside the selected Codex home. The scripts validate paths and ownership, reject Windows junction/reparse-point and macOS symlink escapes, preserve unrelated TOML content and permissions, and use locks, backups, atomic replacement, and a transaction journal. Ambiguous or unsafe state fails closed.

The tool does not read `auth.json` or API keys, call provider APIs, upload data, collect telemetry, host secrets, modify Codex binaries/source, modify any server, or proxy API traffic.

The patch restores standard tool definitions; it cannot make a provider implement a tool it does not support. Automated tests cover Windows PowerShell 5.1/7, macOS shell/JXA file behavior, catalog and TOML integrity, path safety, failure recovery, release packages, and Lite-versus-standard request shapes against a localhost mock server.

Real-provider execution of Web Search, shell, functions, collaboration, code mode, MCP/dynamic tools, image tools, multi-turn history, and image detail remains `not-run` for v0.1.1; macOS Codex CLI/Desktop integration is also `not-run`. No real credentials or billable requests were used. See the [test workflow](https://github.com/Hyacehila/codex-provider-compat/actions/workflows/test.yml) for automated results.

The project uses the [MIT License](LICENSE). The catalog downloaded at runtime comes from the Apache-2.0 [`openai/codex`](https://github.com/openai/codex) repository; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
