# Third-party notices

This unofficial tool can download the complete model catalog from the official
[`openai/codex`](https://github.com/openai/codex) repository at the tag that
exactly matches the detected Codex version. The pinned integration-test fixture
`tests/fixtures/models-0.144.1-official.json` is an unmodified copy of that
catalog from tag `rust-v0.144.1`.

OpenAI Codex is licensed under the Apache License 2.0. A copy is provided in
[`LICENSES/Apache-2.0.txt`](LICENSES/Apache-2.0.txt), and the upstream notice
applicable to the fixture is retained in
[`LICENSES/OpenAI-Codex-NOTICE.txt`](LICENSES/OpenAI-Codex-NOTICE.txt).

At runtime, the tool changes three `use_responses_lite` boolean values locally
and records the source and generated SHA-256 hashes.

The project does not redistribute a modified catalog in source control or in
its normal platform release archives. If a future release bundles one, that
release must also include the applicable upstream license, notices, source
version, and a clear modification statement.

OpenAI, Codex, GPT, and related names may be trademarks of OpenAI. This project
is independent and is not endorsed by OpenAI or by any API provider.
