# Codex Provider Compatibility

Restore missing Codex tools when GPT-5.6 Sol, Terra, or Luna is used through a custom OpenAI-compatible provider.

[简体中文](README.zh-CN.md) · [Download v0.2.0](https://github.com/Hyacehila/codex-provider-compat/releases/tag/v0.2.0) · [Automated tests](https://github.com/Hyacehila/codex-provider-compat/actions/workflows/test.yml)

You may need this tool if Codex can still chat, but after selecting one of those models it no longer:

- runs shell/exec commands or code mode;
- calls functions, MCP servers, collaboration, or extension tools;
- exposes another tool that used to be available, such as Web Search.

Codex may describe what it would do but return only text. If the same tools work after switching to another model, and you configured a custom provider, run `doctor` to check this compatibility issue.

You do not need to inspect traffic, learn a provider protocol, call an API by hand, or edit JSON/TOML. The normal path is:

```text
download and verify -> doctor -> apply -> fully restart Codex -> create a new task
```

> This is an unofficial community project. It is not an OpenAI product and is not endorsed by OpenAI or by any API provider.

## How to use

### Check whether it applies

The patch targets only GPT-5.6 Sol (`gpt-5.6-sol`), Terra (`gpt-5.6-terra`), and Luna (`gpt-5.6-luna`) when used with a custom provider. It is not intended for other models or Codex's built-in OpenAI connection.

Always run `doctor` first. It checks local versions, configuration, and safety without writing files. If the script cannot prove that a change is safe, it stops and leaves the active configuration alone.

### Download and verify v0.2.0

Open the [v0.2.0 Release page](https://github.com/Hyacehila/codex-provider-compat/releases/tag/v0.2.0), then download `SHA256SUMS.txt` and the ZIP for your platform:

| Platform | File |
|---|---|
| Windows | `codex-provider-compat-v0.2.0-windows.zip` |
| macOS | `codex-provider-compat-v0.2.0-macos.zip` |

Verify the Windows ZIP:

```powershell
(Get-FileHash .\codex-provider-compat-v0.2.0-windows.zip -Algorithm SHA256).Hash.ToLowerInvariant()
Get-Content .\SHA256SUMS.txt
```

Verify the macOS ZIP:

```sh
shasum -a 256 ./codex-provider-compat-v0.2.0-macos.zip
cat ./SHA256SUMS.txt
```

The computed value must match the ZIP's entry in `SHA256SUMS.txt`. Extract the package and inspect its README and script before running it. Standalone `.ps1` and `.sh` assets are also provided. This project does not recommend opaque `curl | sh` or `irm | iex` commands.

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

This tool does not enable, disable, or otherwise manage individual tools.

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

If `doctor` or `status` reports `recovery-required`, do not delete lock, transaction, or pending files. Run the intended `apply` or `rollback` again so it can recover the interrupted operation. A healthy user-level patch can still be superseded by a selected profile, project configuration, or CLI override.

After a Codex update, run `status` and `doctor` again. Do not keep an old catalog override across an unreviewed version change.

If you used the removed v0.1.1 `--enable-web-search` option and want the tool to stop owning that legacy change, use v0.2.0 to run `rollback`, restart Codex, then run a normal `apply` and restart into a new task. The new version does not alter your search setting.

### Commands and automation

| Command | Purpose |
|---|---|
| `doctor` | Read-only applicability and safety check |
| `apply` | Validate, back up, and install the patch |
| `status` | Check the installed patch and version |
| `rollback` | Undo only changes owned by this tool |

Both scripts accept `--yes`, `--dry-run`, `--codex-home <absolute-path>`, `--codex-version <version>`, and `--catalog-file <absolute-path>`. Most users need none of these. Codex home and version are discovered automatically; a version conflict stops `apply`.

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

Codex's model catalog marks the three target models to use an internal request format called Responses Lite. In this mode, Codex describes client tools through `additional_tools` instead of the standard top-level `tools` field used by the public Responses API.

The built-in OpenAI path understands this format. Many custom OpenAI-compatible providers implement the public Responses format but not Codex's extra Lite format. They receive no standard tool definitions, so text can still work while terminal, function, MCP, collaboration, extension, or hosted tools disappear.

```text
target model uses Responses Lite
    -> Codex sends internal additional_tools
    -> standard top-level tools are absent or null

this patch disables Lite for the three target models
    -> Codex sends standard Responses tools again
    -> the provider can expose the tools it supports
```

Lite also changes instructions, parallel tool calls, reasoning context, image detail, and internal headers or metadata. Search is one possible affected tool, but the patch does not configure search or guarantee that a provider implements it.

### What the patch does

The patch ID is `responses-lite-standard-tools`. The script detects the Codex version, obtains the complete model catalog from its matching official `openai/codex` tag, and changes only `use_responses_lite` from `true` to `false` for Sol, Terra, and Luna. Any missing target, incomplete catalog, duplicate model, wrong field type, or other semantic change stops the operation.

It writes the generated catalog inside the selected Codex home, backs up configuration and model cache files, updates only the user-level `model_catalog_json`, and records the minimum state needed for `status`, recovery, and rollback. It does not change the selected model, provider, provider table, individual tool settings, or unrelated configuration.

### Safety and limits

Persistent Codex changes stay inside the selected Codex home. The scripts validate paths and ownership, reject Windows junction/reparse-point and macOS symlink escapes, preserve unrelated TOML content and permissions, and use locks, backups, atomic replacement, and a transaction journal. Ambiguous or unsafe state fails closed.

The production tool does not read `auth.json` or API keys, call provider APIs, upload data, collect telemetry, host secrets, modify Codex binaries/source, modify any server, or proxy API traffic.

The patch restores standard tool definitions; it cannot make a provider implement a tool it does not support. Automated tests cover Windows PowerShell 5.1/7, macOS shell/JXA behavior, catalog and TOML integrity, path safety, failure recovery, release packages, and Lite-versus-standard request shapes against localhost.

A maintainer test on one anonymous real Responses provider used only a temporary Windows Codex home. In the recorded acceptance runs, standard mode completed text and multi-turn checks on all three models, shell/exec on Sol and Terra, collaboration on all three, and a local MCP round trip on Sol. Image input failed on that provider. Code-mode proof, app-server dynamic functions, explicit original image detail, and image generation remain `not-run` because the available client path could not isolate credentials or provide deterministic evidence. Credentials, endpoint details, raw requests, and raw responses were not published, and the real Codex home remained unchanged.

Real macOS Codex Desktop behavior also remains `not-run` because this project does not currently have a Mac Desktop test environment. Results from one provider must not be generalized to every OpenAI-compatible service.

The project uses the [MIT License](LICENSE). The catalog downloaded at runtime comes from the Apache-2.0 [`openai/codex`](https://github.com/openai/codex) repository; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
