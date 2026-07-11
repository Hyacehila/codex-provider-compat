# Codex Provider Compatibility

An unofficial, local, reversible compatibility patch for Codex users whose
custom OpenAI-compatible provider supports standard Responses tools but not
Codex's internal Responses Lite `additional_tools` protocol.

[简体中文](README.zh-CN.md)

> This is a community project. It is not an OpenAI product and is not endorsed
> by OpenAI or by any API provider.

## Is this for you?

Run `doctor` if all or most of these are true:

- the selected model is `gpt-5.6-sol`, `gpt-5.6-terra`, or `gpt-5.6-luna`;
- you use a custom provider with `wire_api = "responses"`;
- ordinary text works, but exec/shell, code mode, function/MCP tools,
  collaboration namespaces, extension tools, or Web Search are absent;
- a non-Lite model works with the same provider;
- the provider accepts the public Responses API's top-level tool definitions.

The user flow is intentionally short:

```text
run the script -> fully restart Codex -> create a new task
```

You do not need to inspect traffic, call an API manually, understand
`additional_tools`, or edit JSON/TOML. If the tool cannot prove that an
operation is safe, it stops without changing your active configuration.

This patch is not applicable when the provider requires Responses Lite, does
not support the relevant standard Responses tools, the selected model is not
one of the three targets, or the official catalog already contains the fix.

## What is happening?

As verified against Codex `0.144.1`, the official catalog marks the three
target models as `use_responses_lite = true`. In Lite mode Codex serializes
client tools into an internal `additional_tools` input item, omits standard
top-level `tools` and `instructions`, changes parallel/reasoning/image request
details, and skips hosted Responses tools during planning. A normal compatible
provider may implement the public Responses shape without implementing this
Codex-internal protocol.

Web Search has an additional two-path failure. Lite planning skips hosted
`web_search`, while the standalone `web/run` extension is restricted to the
official OpenAI provider or an OpenAI Actor Authorization provider. Web Search
is therefore an important acceptance case, but this project addresses the
provider/Responses request shape as a whole rather than one search toggle.

Non-Lite models normally work because Codex sends standard top-level tools.
Official OpenAI/ChatGPT paths are different because their backend and
authorized extensions understand the Lite protocol expected by Codex.

## What the patch does

Patch ID: `responses-lite-standard-tools`

The script:

1. discovers Codex home and CLI/Desktop/app-server versions;
2. stops on ambiguous versions unless `--codex-version` is explicit;
3. loads a complete catalog from an exact official `rust-v<version>` tag or a
   reviewed offline file;
4. requires at least 8 unique models, including at least 5 non-target models,
   and validates every target and boolean type;
5. changes only the three target `use_responses_lite` values to `false`, then
   recursively verifies the parsed and re-serialized semantic diff;
6. atomically writes
   `model-catalogs/models-<version>.standard-responses-compat.json`;
7. backs up and edits only user-level `model_catalog_json` and, only when
   requested, `web_search = "live"`;
8. renames rather than deletes `models_cache.json`;
9. records hashes and ownership in a small state file for `status`/`rollback`;
10. journals every mutating phase so an interrupted apply or rollback can be
    restored before the next write command.

All write targets are reconstructed under the selected Codex home. Existing
Windows reparse-point/junction components are rejected. On macOS, the standard
Apple `/var`, `/tmp`, and `/etc` aliases are canonicalized to `/private/...`;
other symlink components are rejected. Rollback validates state paths and
strict backup/archive names rather than treating the state file as an
arbitrary file-operation list.

The TOML editor is lexical rather than line-regex based. It distinguishes
comments, tables, arrays, inline tables, quoted keys, and all four TOML string
forms, while preserving BOM, LF/CRLF, trailing newline, comments, section
order, unrelated text, and file permissions. Ambiguous, dotted, duplicate, or
otherwise non-lossless owned keys fail closed.

The tool never modifies or replaces Codex binaries, source, Desktop packages,
app-server, OpenAI services, or a provider server. It does not run a proxy,
hold keys, read `auth.json`, contact your provider API, upload configuration,
or collect telemetry.

## Current source-only installation

This repository does not yet publish a tag or GitHub Release. Do not follow an
instruction that claims a release archive or `SHA256SUMS` already exists.

Source repository: <https://github.com/Hyacehila/codex-provider-compat>

For the current source-only delivery:

1. Open the repository and select a specific commit whose GitHub Actions run is
   green.
2. Download the ZIP for that exact commit, or clone the repository and check
   out that commit rather than relying on a moving branch name.
3. Compute and save the platform script's SHA-256.
4. Open and review the script before running it.
5. Run `doctor`, then `apply`.

For example:

```text
git clone https://github.com/Hyacehila/codex-provider-compat.git
cd codex-provider-compat
git checkout <reviewed-commit>
git rev-parse HEAD
```

Do not use an opaque `curl | sh` or `irm | iex` pipeline.

Windows review:

```powershell
Get-FileHash .\codex-provider-compat.ps1 -Algorithm SHA256
Get-Content .\codex-provider-compat.ps1
```

macOS review:

```sh
shasum -a 256 ./codex-provider-compat.sh
less ./codex-provider-compat.sh
chmod +x ./codex-provider-compat.sh
```

A future GitHub Release must publish stable artifacts and checksums before the
README switches its primary installation path to Releases.

## Windows

Windows PowerShell 5.1 and PowerShell 7.5 or later are supported. Python,
Node, `jq`, Chocolatey, and Scoop are not user dependencies.

```powershell
.\codex-provider-compat.ps1 doctor
.\codex-provider-compat.ps1 apply
```

If Windows PowerShell blocks downloaded scripts even after you verified and
reviewed the file, use a process-only execution-policy override. It does not
change the machine or user policy:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\codex-provider-compat.ps1 doctor
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\codex-provider-compat.ps1 apply
```

For a reviewed, non-interactive run:

```powershell
.\codex-provider-compat.ps1 apply --yes
```

## macOS

The script uses only the system shell, `curl`, `awk`, `shasum`, and
`osascript -l JavaScript`.

```sh
./codex-provider-compat.sh doctor
./codex-provider-compat.sh apply
```

For a reviewed, non-interactive run:

```sh
./codex-provider-compat.sh apply --yes
```

After apply on either platform, fully quit every Codex CLI/Desktop/app-server
process, restart Codex, and create a new task. Existing tasks keep the model
and tool snapshot captured when they started.

## Commands, options, and exit codes

Both scripts expose the same commands:

- `doctor`: read-only environment, version, config, catalog, profile, and risk
  diagnosis; it does not write to Codex home;
- `apply`: validate, confirm, back up, atomically patch, and write state;
- `status`: reparse and verify the catalog, hashes, config pointer, optional
  Web Search setting, version drift, and recovery state;
- `rollback`: transactionally restore only tool-owned keys and safely restore
  or preserve cache.

Common options:

```text
--yes
--dry-run
--codex-home <absolute-path>
--codex-version <version>
--catalog-file <absolute-path>
--enable-web-search
```

`--catalog-file` is a read-only offline input and may be outside Codex home. It
must still be a complete catalog. `--enable-web-search` may enable billable
search calls; the provider must support the corresponding standard Responses
hosted tool.

| Code | Meaning |
|---:|---|
| 0 | Success or healthy state |
| 1 | General usage or operation error |
| 2 | Not applicable / not installed / official fix already present |
| 3 | Unsafe, ambiguous, corrupt, drifted, or recovery-required state |
| 4 | Patch/catalog schema is stale for this Codex version |
| 5 | Official catalog network, HTTP, timeout, or size failure |

Automation should use the exit code, not parse prose.

## Files changed

All writes remain inside the selected Codex home (explicit `--codex-home`, then
`CODEX_HOME`, then `~/.codex`):

```text
config.toml
config.toml.bak-provider-compat-YYYYMMDD-HHMMSS[.N]
model-catalogs/models-<version>.standard-responses-compat.json
models_cache.json.bak-provider-compat-YYYYMMDD-HHMMSS[.N]
provider-compat-state.json
provider-compat-state.json.rolled-back-YYYYMMDD-HHMMSS[.N]
provider-compat-transaction.json                  # only while recovering/writing
provider-compat.lock or provider-compat.lock.d/  # only while writing
```

Nonce-bound temporary/pending files can exist after a hard process kill. Their
exact names and paths are reconstructed from the fixed destinations and nonce
recorded in the transaction. The next `apply` or `rollback` recovers them;
`doctor` and `status` remain read-only and report `recovery-required`.

The full config backup is an emergency/manual artifact. Normal rollback edits
only `model_catalog_json` and, if this tool owned the change, `web_search`, so
unrelated changes made after apply are preserved. If config did not exist
before apply, rollback restores the absent-file state.

## Important risks

- `model_catalog_json` replaces the full catalog for a new Codex process. A
  stale catalog can hide new models or stale capabilities.
- Disabling Lite changes the entire request protocol, not only Web Search:
  instructions, top-level tools, parallel calls, reasoning context, image
  detail, internal headers/metadata, and history representation can differ.
- A provider that accepts only Responses Lite can fail after this patch.
- The patch exposes standard tool definitions; it cannot make a provider
  implement tools, hosted search, image handling, or billing behavior that it
  does not support.
- A selected `$CODEX_HOME/<profile>.config.toml`, project layer, or CLI/session
  override can supersede the user-level catalog path. `doctor` reports known
  profile files but cannot infer every runtime choice. A healthy `status`
  result proves that the tool-owned user-level files are internally
  consistent; it does not prove that a higher-precedence runtime layer selected
  that catalog for a particular task.
- `model_provider = "openai"` normally selects the built-in OpenAI provider,
  but `openai_base_url` or a custom provider definition can redirect that id.
  In that configuration, the id alone does not prove that the backend supports
  Responses Lite, so judge applicability from the actual override and symptoms.
- One user catalog can affect several Codex surfaces. If discovered CLI and
  Desktop/app-server versions differ, apply stops unless the version is
  explicitly reviewed.
- Old tasks do not hot-reload the catalog. Restart and create a new task.

After a Codex update, run `status` and `doctor`. Roll back the old override
before applying a catalog for a newly reviewed version. If the official
catalog already marks all targets non-Lite, apply exits 2 without creating a
new override. After an official fix, run rollback, restart, and create a task.

## Rollback and interrupted operations

```powershell
.\codex-provider-compat.ps1 rollback --yes
```

```sh
./codex-provider-compat.sh rollback --yes
```

Rollback refuses to overwrite a tool-owned key changed after apply. It removes
the generated catalog only when its content and state ownership match, and it
never overwrites a new cache at the original cache path.

If `doctor` or `status` reports `recovery-required`, do not delete the journal
or move files manually. Run the intended `apply` or `rollback`; after acquiring
the lock, it first restores the interrupted transaction and then starts a new
operation. A tampered or path-unsafe journal fails closed with exit 3.

## Troubleshooting

- Exit 3 with multiple versions: update CLI/Desktop to the same version, or
  pass a reviewed `--codex-version`.
- Exit 3 for an owned key: remove the ambiguity only if you understand the
  config; the tool will not guess between duplicate/dotted/complex TOML keys.
- Exit 4: this patch no longer matches the official catalog schema or targets.
  Do not force it with a hand-made minimal catalog.
- Exit 5: the exact official tag/catalog could not be fetched safely. Retry,
  or download and inspect that tag's complete `models.json`, then use
  `--catalog-file`.
- Applied but tools still fail: the provider may not support that standard
  Responses tool. Roll back; users are not expected to modify the provider or
  investigate its protocol.
- Search works but another capability does not: capabilities are independent.
  A Web Search pass does not prove exec, MCP, code mode, or image support.

## Test and capability status

All mutating test suites are designed to use temporary Codex homes and compare
the real home before and after. The workflow runs the Windows lifecycle suite
under both Windows PowerShell 5.1 and PowerShell 7.5 or later, runs a fixed Codex
request-shape gate, and uses `macos-latest` for the full shell/JXA lifecycle.
On Windows, local macOS validation is limited to `sh -n`; JXA and macOS file
semantics are not claimed locally. Published GitHub Actions results for the
exact commit are the authoritative pass/fail record.

The macOS job validates only the script, JXA, and filesystem semantics. It does
not launch or exercise Codex Desktop; macOS Desktop integration remains
`not-run` and requires a separate controlled manual test.

The request-shape job installs Codex CLI `0.144.1` in CI and routes the
configured model requests to a localhost mock Responses server. It clears the
OpenAI/Codex/ChatGPT/Azure OpenAI credential and proxy variables used by that
child process. This proves the captured model-request shape and rejected local
paths; it is not an operating-system network monitor and does not prove the
absence of every possible silent outbound socket. Node is used only in CI to
install the pinned CLI and is not a user dependency.

The request-shape gate verifies the Lite and patched requests rather than a
real provider's behavior. It does not make a paid request and does not prove
provider-specific execution.

| Capability | Result | Evidence |
|---|---|---|
| Complete catalog and three-target-only mutation | passed | Windows fixtures, recursive semantic diff, official-catalog cycle |
| Config comments/sections/BOM/newlines/unrelated bytes | passed | Windows lexical-editor fixtures; macOS behavior is checked in CI |
| Path ownership, junction escape, transaction recovery | passed | Windows fault/termination injection; macOS symlink/signal behavior is checked in CI |
| apply/status/rollback lifecycle | passed | Temporary homes and official-catalog fixtures |
| macOS shell/JXA lifecycle | passed | CI: `macos-latest`; Windows local: `sh -n` only, JXA/file semantics not-run |
| macOS Desktop integration | not-run | `macos-latest` validates script/JXA/file semantics only; it does not launch Codex Desktop |
| hosted Web Search definition | passed | Mock: localhost request-shape capture; real provider: not-run |
| exec/shell definition | passed | Mock: localhost request-shape capture; real provider execution: not-run |
| generic function definitions | passed | Mock: localhost request-shape capture; real execution: not-run |
| collaboration namespace | passed | Mock: localhost request-shape capture; real execution: not-run |
| Lite header, instructions, parallel, reasoning context | passed | Mock: Lite vs standard localhost request assertions |
| code-mode execution | not-run | No independent code-mode fixture or real-provider execution |
| MCP and dynamic-tool execution | not-run | no real MCP/provider execution in v0.1 |
| image generation/extension tools | not-run | no real provider execution in v0.1 |
| ordinary text response | passed | Mock: Codex consumes a localhost Responses completion |
| multi-turn history | not-run | requires a separate controlled conversation fixture |
| image input/detail semantics | not-run | source difference known; request fixture not implemented |

Published CI results are the source of truth for a commit. Do not interpret a
fixture or mock pass as a universal provider compatibility guarantee.

## Upstream status

Upstream facts are a dated checkpoint, not a promise about future `main`.
Checked at July 11, 2026 21:22:20 UTC (July 12, 2026 05:22:20
Asia/Shanghai): the latest release was `rust-v0.144.1` (published July 9), and
the checked main commit was `9e552e9d15ba52bed7077d5357f3e18e330f8f38`
(committed July 11 at 21:03:12 UTC). Both still contained the three Lite flags
and the relevant Lite request behavior. The checked main catalog contained 8
models; only the three patch targets were Lite. At that checkpoint, the
directly related issues were open:

- [#31894](https://github.com/openai/codex/issues/31894)
- [#31875](https://github.com/openai/codex/issues/31875)
- [#31870](https://github.com/openai/codex/issues/31870)
- [#31882](https://github.com/openai/codex/issues/31882)
- [#31864](https://github.com/openai/codex/issues/31864)
- [#32086](https://github.com/openai/codex/issues/32086)
- [#32101](https://github.com/openai/codex/issues/32101)

At that checkpoint, issue `#32119` was closed but concerned custom-provider
remote model refresh, not the Lite tool protocol. Historical references to
`#31853` and `#31872` were incorrect: they are unrelated items and are not used
as evidence here.

The official [configuration reference](https://learn.chatgpt.com/docs/config-file/config-reference#configtoml)
documents user config at `~/.codex/config.toml`, startup loading of
`model_catalog_json`, and profile overrides. Upstream source and issues are
research/test evidence only; this community tool never patches or rebuilds
Codex.

## Contributing

Issues and pull requests are welcome. Before reporting a problem, run
`doctor` and include only the operating system, Codex version sources, command,
exit code, and redacted diagnostic conclusion. Do not post `auth.json`, API
keys, Authorization headers, complete config files, or provider URLs that may
contain secrets. Changes must preserve the local-only patch boundary, keep the
four public commands compatible across both platforms, and add focused tests
for every changed safety or rollback behavior.

## Privacy, license, and project boundary

No secrets, provider requests, config contents, or diagnostics are uploaded by
the tool. State and transaction files keep only the minimum patch and rollback
metadata needed for recovery, such as validated owned paths, hashes, phases,
nonces, versions, timestamps, flags, and prior values of the tool-owned keys.
They do not contain credentials, API requests, or the full configuration.

The scripts are MIT licensed. The official catalog is fetched from the
Apache-2.0 `openai/codex` repository; see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Future patches must stay local, narrowly detected, exhaustively validated, and
reversible. This repository is not a Codex fork, binary patch, general plugin
framework, provider proxy, remote repair service, or key-hosting service.
