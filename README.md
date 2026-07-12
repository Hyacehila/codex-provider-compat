# Codex Provider Compatibility

A local, reversible compatibility patch for Codex users whose custom provider supports standard OpenAI Responses tools but not Codex's internal Responses Lite tool format.

[简体中文](README.zh-CN.md) · [Automated tests](https://github.com/Hyacehila/codex-provider-compat/actions/workflows/test.yml)

> This is an unofficial community project. It is not an OpenAI product and is not endorsed by OpenAI or by any API provider.

Shortest path: `download and verify -> doctor -> apply -> fully restart Codex -> create a new task`.

## How to use

### Check whether it applies

Run `doctor` if all or most of these are true:

- the selected model is `gpt-5.6-sol`, `gpt-5.6-terra`, or `gpt-5.6-luna`;
- you use a custom provider with `wire_api = "responses"`;
- ordinary text works, but exec/shell, code mode, function/MCP tools, collaboration namespaces, extension tools, or Web Search are missing;
- a non-Lite model works with the same provider;
- the provider supports standard top-level tool definitions from the public Responses API.

Do not apply the patch if the provider requires Responses Lite, does not support the standard Responses tools you need, or the selected model is not one of the three targets. `doctor` is read-only. If the tool cannot prove that an operation is safe, it stops without changing the active configuration.

You do not need to inspect traffic, call an API manually, study the provider protocol, or edit JSON/TOML.

### Download and verify v0.1.0

From the [v0.1.0 Release page](https://github.com/Hyacehila/codex-provider-compat/releases/tag/v0.1.0), download the ZIP for your platform and `SHA256SUMS.txt`:

- Windows: `codex-provider-compat-v0.1.0-windows.zip`
- macOS: `codex-provider-compat-v0.1.0-macos.zip`

The Release also provides standalone scripts for easier review:

- `codex-provider-compat.ps1`
- `codex-provider-compat.sh`

Verify on Windows:

```powershell
(Get-FileHash .\codex-provider-compat-v0.1.0-windows.zip -Algorithm SHA256).Hash.ToLowerInvariant()
Get-Content .\SHA256SUMS.txt
```

Verify on macOS:

```sh
shasum -a 256 ./codex-provider-compat-v0.1.0-macos.zip
cat ./SHA256SUMS.txt
```

The computed value must match the entry in `SHA256SUMS.txt`. Then extract the ZIP and inspect the script before running it. Do not use an opaque `curl | sh` or `irm | iex` pipeline.

### Windows

Windows PowerShell 5.1 and PowerShell 7.5 or later are supported. Python, Node, `jq`, Chocolatey, and Scoop are not required.

From the extracted directory:

```powershell
Get-Content .\codex-provider-compat.ps1
.\codex-provider-compat.ps1 doctor
.\codex-provider-compat.ps1 apply
```

If Windows PowerShell blocks the downloaded script after you have verified its checksum and reviewed it, use a process-only execution-policy override:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\codex-provider-compat.ps1 doctor
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\codex-provider-compat.ps1 apply
```

### macOS

The script uses only the shell and system tools included with macOS, including `curl`, `awk`, `shasum`, and `osascript -l JavaScript`. Homebrew, Python, Node, and `jq` are not required.

From the extracted directory:

```sh
less ./codex-provider-compat.sh
chmod +x ./codex-provider-compat.sh
./codex-provider-compat.sh doctor
./codex-provider-compat.sh apply
```

### After apply

```text
Fully quit and restart Codex, then create a new task.
Existing tasks keep the model and tool snapshot captured when they started.
```

To also enable hosted Web Search, explicitly request it only after confirming that the provider supports the standard Responses `web_search` tool:

```powershell
.\codex-provider-compat.ps1 apply --enable-web-search
```

```sh
./codex-provider-compat.sh apply --enable-web-search
```

Search may be billable. A working Web Search request does not prove that exec, MCP, code mode, or image tools are also supported.

### Check and roll back

Check the installed state:

```powershell
.\codex-provider-compat.ps1 status
```

```sh
./codex-provider-compat.sh status
```

Roll back:

```powershell
.\codex-provider-compat.ps1 rollback
```

```sh
./codex-provider-compat.sh rollback
```

Rollback restores only keys owned by this tool and preserves unrelated configuration changes made after apply. It removes the generated catalog only when its content and recorded ownership match, and it never overwrites a new file at the original cache path.

After rollback, fully quit and restart Codex and create a new task.

If `doctor` or `status` reports `recovery-required`, do not manually remove transaction, lock, or pending files. Run the intended `apply` or `rollback` again. The tool first restores the interrupted transaction. Unsafe paths or state cause an exit code 3 failure.

### Commands, options, and exit codes

| Command | Purpose |
|---|---|
| `doctor` | Read-only environment, version, configuration, and applicability check |
| `apply` | Validate, back up, and apply the patch |
| `status` | Verify catalog, configuration, version, and transaction state |
| `rollback` | Precisely undo changes owned by this tool |

Both scripts accept the same common options:

```text
--yes
--dry-run
--codex-home <absolute-path>
--codex-version <version>
--catalog-file <absolute-path>
--enable-web-search
```

You normally do not need to specify Codex home or version. The tool checks `--codex-home`, then `CODEX_HOME`, then `~/.codex`, and discovers installed Codex versions. Conflicting versions stop apply until you review and explicitly select one with `--codex-version`. `--catalog-file` is a reviewed, read-only complete catalog input and never becomes a write target.

| Code | Meaning |
|---:|---|
| 0 | Success or healthy state |
| 1 | General usage or operation error |
| 2 | Not applicable, not installed, or already fixed upstream |
| 3 | Unsafe, ambiguous, corrupt, drifted, or recovery-required state |
| 4 | Patch or catalog schema is stale for this version |
| 5 | Official catalog network, HTTP, timeout, or size failure |

Automation should use the exit code instead of parsing prose.

### Files, updates, and common problems

All persistent Codex changes stay inside the selected Codex home. The macOS script also uses a private mode-0700 system temporary workspace for downloads and analysis, then removes it on exit. Persistent Codex-home paths are:

```text
config.toml
config.toml.bak-provider-compat-YYYYMMDD-HHMMSS[.N]
model-catalogs/models-<version>.standard-responses-compat.json
models_cache.json.bak-provider-compat-YYYYMMDD-HHMMSS[.N]
provider-compat-state.json
provider-compat-state.json.rolled-back-YYYYMMDD-HHMMSS[.N]
provider-compat-transaction.json                 # only while writing/recovering
provider-compat.lock or provider-compat.lock.d/ # only while writing
```

The tool never deletes a config that existed before apply, and it never deletes cache data. If config did not exist before apply and still contains no unrelated user content, rollback removes the config created by this tool to restore the original absent-file state. The full config backup is an emergency manual copy; normal rollback uses state metadata to edit only owned keys. If a path, file ownership, or configuration form cannot be proven safe, the operation stops with no persistent Codex changes.

After a Codex update, run `status` and `doctor`. The override is a complete catalog, so a stale copy can hide new models or preserve outdated capability metadata. Roll back the old patch before applying a catalog for a reviewed new version. If the official catalog already marks all three targets as non-Lite, `apply` exits 2 without creating another override.

`status = healthy` proves only that the user-level files owned by the tool are internally consistent. A selected `$CODEX_HOME/<profile>.config.toml`, project configuration, or CLI/session override can still change the effective configuration of a particular task.

If the patch is healthy but a tool still fails, the provider probably does not implement that standard Responses tool. Roll back; users are not expected to change the provider, base URL, headers, or server.

## How it works

### Root cause

Verification against Codex `0.144.1` found the three target models marked as `use_responses_lite = true`:

```text
Lite catalog flag
    -> Codex uses internal additional_tools
    -> standard top-level tools are absent or null
    -> a normal OpenAI-compatible provider cannot see standard tool definitions

This patch makes the three target models non-Lite
    -> Codex restores standard Responses top-level tools
    -> the provider can handle the tools it actually supports
```

Lite mode also changes top-level `instructions`, parallel tool calls, reasoning context, image detail, and internal headers/metadata. Disabling Lite changes the whole request shape, not only Web Search.

Web Search has an additional two-path problem: Lite planning skips hosted `web_search`, while the standalone `web/run` extension is restricted by provider identity. Search is therefore an important acceptance case, but this project addresses provider/Responses request compatibility as a whole.

Non-Lite models normally work because Codex sends standard top-level tool definitions. Official OpenAI/ChatGPT paths are usually different because their backend and authorized extensions understand the Lite protocol used by Codex.

### What the patch changes

The first patch ID is `responses-lite-standard-tools`. The scripts:

1. discover Codex home and CLI, Desktop, and app-server versions, stopping safely on conflicts;
2. download a complete catalog from the exact official `rust-v<version>` tag, or read a reviewed complete offline catalog;
3. change only `use_responses_lite` for `gpt-5.6-sol`, `gpt-5.6-terra`, and `gpt-5.6-luna` to `false`, then verify that no other semantic difference exists;
4. atomically write the generated catalog, point user-level `model_catalog_json` to it, back up config and cache, and record the minimum state needed for `status`, recovery, and rollback.

Only an explicit `--enable-web-search` also sets user-level `web_search = "live"`. The tool does not change `model`, `model_provider`, provider tables, or unrelated settings.

### Safety boundary

- The catalog must be complete, structurally valid, and have unique slugs. Online downloads are accepted only from the exact official Codex tag; an offline file is treated as reviewed, read-only input. Download, schema, or target validation failure leaves config and cache untouched.
- Recursive semantic comparison is performed before and after serialization. Only the three fixed boolean changes are allowed.
- The TOML editor preserves comments, sections, BOM, LF/CRLF, trailing newline, unrelated text, and permissions. Duplicate, dotted, or non-lossless owned keys fail closed.
- Mutating commands use a lock, same-directory atomic replacement, and a transaction journal so failed or interrupted apply/rollback operations can recover.
- Write paths are reconstructed from Codex home and fixed naming rules. Windows junction/reparse-point and macOS non-system symlink escapes are rejected.
- `doctor` and `status` remain read-only.

The tool does not modify, replace, or inject Codex CLI, Desktop, app-server, binaries, or source. It does not modify OpenAI/Codex services or a third-party provider, and it does not run an API proxy, remote repair service, or key-hosting service.

### Capability and validation limits

The patch restores standard tool definitions. It cannot make a provider implement exec, MCP, hosted search, image handling, or billing behavior that it does not support. A provider that accepts only Responses Lite may fail after the patch.

Automated tests cover Windows PowerShell 5.1/7 lifecycles, macOS shell/JXA file semantics, complete-catalog validation, TOML preservation, path escapes, fault recovery, and Lite/standard request shapes from a pinned Codex CLI to a localhost mock Responses server. They do not read real credentials or send billable requests to a real provider.

The localhost mock proves request shape, not universal provider compatibility. The following remain explicitly `not-run` for v0.1.0: macOS Codex CLI/Desktop integration; real-provider execution of hosted Web Search, exec/shell, function/collaboration, code mode, MCP/dynamic tools, and image tools; multi-turn history; and image-input detail. The [GitHub Actions workflow](https://github.com/Hyacehila/codex-provider-compat/actions/workflows/test.yml) is the source of automated results for each release commit.

### Privacy and license

The tool does not read `auth.json` or API keys, contact provider APIs, upload configuration, logs, or diagnostics, or collect telemetry. State and transaction files contain only the minimum patch, path, hash, phase, and owned-key metadata needed for recovery, never the complete configuration, credentials, or API requests.

The scripts use the [MIT License](LICENSE). The official complete catalog downloaded at runtime comes from the Apache-2.0 [`openai/codex`](https://github.com/openai/codex) repository; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
