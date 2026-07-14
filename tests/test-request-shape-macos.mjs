#!/usr/bin/env node
// CI-only macOS integration test. It never reads credentials or contacts a provider.

import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const EXPECTED_VERSION = '0.144.3';
const EXPECTED_CATALOG_SHA256 = 'DCAB00231A5178A9C84B7AEF4CC06A1E1359E37EE0DD7E69D5822C4B1DE723B1';
const TARGET_MODELS = ['gpt-5.6-sol', 'gpt-5.6-terra', 'gpt-5.6-luna'];
const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const toolPath = path.join(repoRoot, 'codex-provider-compat.sh');
const catalogPath = path.join(repoRoot, 'tests', 'fixtures', 'models-0.144.3-official.json');

function hasOwn(value, key) {
  return value !== null && typeof value === 'object' && Object.prototype.hasOwnProperty.call(value, key);
}

function sha256Bytes(bytes) {
  return crypto.createHash('sha256').update(bytes).digest('hex').toUpperCase();
}

async function sha256File(file) {
  return sha256Bytes(await fsp.readFile(file));
}

function canonical(value) {
  if (Array.isArray(value)) return value.map(canonical);
  if (value !== null && typeof value === 'object') {
    const output = {};
    for (const key of Object.keys(value).sort()) output[key] = canonical(value[key]);
    return output;
  }
  return value;
}

function canonicalFragment(value) {
  return JSON.stringify(canonical(value));
}

function tomlString(value) {
  return JSON.stringify(String(value).replaceAll('\\', '/'));
}

async function snapshotPath(target) {
  try {
    const stat = await fsp.lstat(target);
    if (stat.isSymbolicLink()) return `symlink:${await fsp.readlink(target)}`;
    if (stat.isFile()) return `file:${stat.mode & 0o7777}:${await sha256File(target)}`;
    if (!stat.isDirectory()) return `other:${stat.mode & 0o7777}`;
    const entries = await fsp.readdir(target, { withFileTypes: true });
    const parts = [];
    for (const entry of entries.sort((a, b) => a.name.localeCompare(b.name, 'en'))) {
      const child = path.join(target, entry.name);
      if (entry.isSymbolicLink()) parts.push(`${entry.name}=symlink:${await fsp.readlink(child)}`);
      else if (entry.isFile()) parts.push(`${entry.name}=file:${await sha256File(child)}`);
      else parts.push(`${entry.name}=${entry.isDirectory() ? 'directory' : 'other'}`);
    }
    return `directory:${parts.join('|')}`;
  } catch (error) {
    if (error?.code === 'ENOENT') return '<missing>';
    throw error;
  }
}

async function snapshotRealCodexHome() {
  const realHome = process.env.CODEX_HOME
    ? path.resolve(process.env.CODEX_HOME)
    : path.join(process.env.HOME || os.homedir(), '.codex');
  const names = [
    'config.toml',
    'models_cache.json',
    'provider-compat-state.json',
    'provider-compat-transaction.json',
    'provider-compat.lock.d',
    'model-catalogs',
  ];
  const result = {};
  for (const name of names) result[name] = await snapshotPath(path.join(realHome, name));
  return JSON.stringify(result);
}

function isolatedEnvironment({ codexHome, userHome, tempDirectory }) {
  const env = {
    PATH: process.env.PATH || '/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin',
    HOME: userHome,
    CODEX_HOME: codexHome,
    TMPDIR: `${tempDirectory}${path.sep}`,
    NO_PROXY: '127.0.0.1,localhost',
    no_proxy: '127.0.0.1,localhost',
    LANG: process.env.LANG || 'en_US.UTF-8',
  };
  if (process.env.LC_ALL) env.LC_ALL = process.env.LC_ALL;
  return env;
}

async function runProcess(file, args, { cwd, env, timeoutMs = 60000 }) {
  return await new Promise((resolve, reject) => {
    const child = spawn(file, args, {
      cwd,
      env,
      detached: true,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let stdout = '';
    let stderr = '';
    let settled = false;
    const limit = 2 * 1024 * 1024;
    const collect = (kind, chunk) => {
      if (kind === 'stdout') stdout += chunk.toString('utf8');
      else stderr += chunk.toString('utf8');
      if (stdout.length + stderr.length > limit) {
        try { process.kill(-child.pid, 'SIGKILL'); } catch {}
      }
    };
    child.stdout.on('data', (chunk) => collect('stdout', chunk));
    child.stderr.on('data', (chunk) => collect('stderr', chunk));
    child.on('error', reject);
    const timer = setTimeout(() => {
      if (settled) return;
      try { process.kill(-child.pid, 'SIGKILL'); } catch {}
      reject(new Error(`process timed out: ${file} ${args.join(' ')}`));
    }, timeoutMs);
    child.on('close', (code, signal) => {
      settled = true;
      clearTimeout(timer);
      resolve({ code, signal, stdout, stderr });
    });
  });
}

function processDetails(result) {
  const text = `exit=${result.code} signal=${result.signal || ''}\nstdout:\n${result.stdout}\nstderr:\n${result.stderr}`;
  return text.length > 10000 ? `${text.slice(0, 10000)}\n<truncated>` : text;
}

function sseCompletion() {
  const id = 'resp-provider-compat-shape-macos';
  return [
    'event: response.created',
    `data: {"type":"response.created","response":{"id":"${id}"}}`,
    '',
    'event: response.output_item.done',
    'data: {"type":"response.output_item.done","item":{"type":"message","role":"assistant","id":"msg-provider-compat-shape-macos","content":[{"type":"output_text","text":"shape-test-complete"}]}}',
    '',
    'event: response.completed',
    `data: {"type":"response.completed","response":{"id":"${id}","usage":{"input_tokens":0,"input_tokens_details":null,"output_tokens":0,"output_tokens_details":null,"total_tokens":0}}}`,
    '',
    '',
  ].join('\n');
}

async function startMock() {
  const records = [];
  let fatal = null;
  const server = http.createServer((request, response) => {
    const chunks = [];
    let size = 0;
    request.on('data', (chunk) => {
      size += chunk.length;
      if (size > 2 * 1024 * 1024) request.destroy(new Error('request body exceeded 2 MiB'));
      else chunks.push(chunk);
    });
    request.on('error', (error) => { fatal ||= error; });
    request.on('end', () => {
      try {
        const body = Buffer.concat(chunks).toString('utf8');
        records.push({
          method: request.method,
          url: request.url,
          host: request.headers.host || null,
          authorization: hasOwn(request.headers, 'authorization'),
          proxyAuthorization: hasOwn(request.headers, 'proxy-authorization'),
          responsesLiteHeader: request.headers['x-openai-internal-codex-responses-lite'] || null,
          body,
        });
        if (request.method !== 'POST' || request.url !== '/v1/responses') {
          const message = Buffer.from('localhost test endpoint rejected this path', 'utf8');
          response.writeHead(404, { 'content-type': 'text/plain', 'content-length': message.length, connection: 'close' });
          response.end(message);
          return;
        }
        const payload = Buffer.from(sseCompletion(), 'utf8');
        response.writeHead(200, { 'content-type': 'text/event-stream', 'content-length': payload.length, connection: 'close' });
        response.end(payload);
      } catch (error) {
        fatal ||= error;
        response.destroy(error);
      }
    });
  });
  server.on('clientError', (error, socket) => {
    fatal ||= error;
    socket.destroy();
  });
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  const address = server.address();
  assert(address && typeof address === 'object');
  return {
    port: address.port,
    records,
    get fatal() { return fatal; },
    async stop() { await new Promise((resolve) => server.close(resolve)); },
  };
}

function testConfig(port, pinnedCatalog, webSearchMode = null) {
  if (webSearchMode !== null && webSearchMode !== 'live') {
    throw new Error(`unsupported request-shape Web Search fixture mode: ${webSearchMode}`);
  }
  const webSearchLine = webSearchMode === null ? '' : `web_search = ${tomlString(webSearchMode)}\n`;
  return `model = "gpt-5.6-sol"
model_provider = "mock"
model_catalog_json = ${tomlString(pinnedCatalog)}
${webSearchLine}check_for_update_on_startup = false
openai_base_url = "http://127.0.0.1:${port}/v1"
chatgpt_base_url = "http://127.0.0.1:${port}"
approval_policy = "never"
sandbox_mode = "read-only"

[analytics]
enabled = false

[feedback]
enabled = false

[otel]
exporter = "none"
trace_exporter = "none"
metrics_exporter = "none"
log_user_prompt = false

[features]
apps = false
code_mode = true
plugins = false
remote_plugin = false
remote_models = false
remote_compaction_v2 = false
responses_websockets = false
responses_websockets_v2 = false
shell_snapshot = false

[model_providers.mock]
name = "provider-compat-localhost-test"
base_url = "http://127.0.0.1:${port}/v1"
wire_api = "responses"
requires_openai_auth = false
request_max_retries = 0
stream_max_retries = 0
stream_idle_timeout_ms = 10000
`;
}

async function invokeCodex(codexBinary, paths) {
  const result = await runProcess(codexBinary, [
    'exec', '--skip-git-repo-check', '--ephemeral', '--ignore-rules',
    '-C', paths.workspace, 'shape-test',
  ], {
    cwd: paths.workspace,
    env: isolatedEnvironment(paths),
    timeoutMs: 45000,
  });
  assert.equal(result.code, 0, processDetails(result));
  assert(result.stdout.includes('shape-test-complete'), `Codex did not consume the mock completion: ${processDetails(result)}`);
  const outsideUrl = `${result.stdout}\n${result.stderr}`.match(/https?:\/\/(?!127\.0\.0\.1(?::\d+)?(?:\/|\b))\S+/i);
  assert.equal(outsideUrl, null, `Codex reported a non-local target: ${outsideUrl?.[0]}`);
}

async function invokeTool(paths, args) {
  return await runProcess('/bin/sh', [toolPath, ...args], {
    cwd: paths.workspace,
    env: isolatedEnvironment(paths),
  });
}

function singleRecord(mock) {
  assert.equal(mock.fatal, null, `localhost mock failed: ${mock.fatal}`);
  assert.equal(mock.records.length, 1, `Codex made ${mock.records.length} HTTP requests`);
  const record = mock.records[0];
  assert.equal(record.method, 'POST');
  assert.equal(record.url, '/v1/responses');
  assert.equal(record.host, `127.0.0.1:${mock.port}`);
  assert.equal(record.authorization, false);
  assert.equal(record.proxyAuthorization, false);
  assert(record.body.length > 0, 'Responses request body is empty');
  return record;
}

function assertLite(record) {
  assert.equal(record.responsesLiteHeader, 'true');
  const body = JSON.parse(record.body);
  assert.equal(body.model, 'gpt-5.6-sol');
  assert.equal(hasOwn(body, 'tools'), false, 'Lite request must omit top-level tools');
  assert.equal(hasOwn(body, 'instructions'), false, 'Lite request must omit instructions');
  assert.equal(body.parallel_tool_calls, false);
  assert.equal(body.reasoning.context, 'all_turns');
  assert(Array.isArray(body.input) && body.input.length > 0);
  assert.equal(body.input[0].type, 'additional_tools');
  const tools = body.input[0].tools;
  assert(Array.isArray(tools) && tools.length > 0);
  assert.equal(tools.filter((tool) => tool.type === 'web_search').length, 0);
  assert.equal(tools.filter((tool) => tool.type === 'namespace' && tool.name === 'web').length, 0);
  return tools;
}

function assertStandard(record, liteTools, expectedHostedWebCount = 0) {
  assert.equal(record.responsesLiteHeader, null, 'standard request must omit the Lite header');
  const body = JSON.parse(record.body);
  assert.equal(body.model, 'gpt-5.6-sol');
  assert(Array.isArray(body.tools) && body.tools.length > 0, 'standard top-level tools are missing');
  assert(typeof body.instructions === 'string' && body.instructions.length > 0, 'standard instructions are missing');
  assert.equal(body.parallel_tool_calls, true);
  assert.equal(hasOwn(body.reasoning, 'context'), false);
  assert.equal(body.input.filter((item) => item.type === 'additional_tools').length, 0);
  const hostedWeb = body.tools.filter((tool) => tool.type === 'web_search');
  assert.equal(hostedWeb.length, expectedHostedWebCount, 'hosted Web Search count does not match the user configuration');
  assert(body.tools.some((tool) => hasOwn(tool, 'name') && ['exec', 'shell'].includes(tool.name)), 'exec/shell capability is missing');
  assert.equal(body.tools.filter((tool) => tool.type === 'custom' && tool.name === 'exec' && String(tool.description).includes('orchestrate/compose tool calls')).length, 1, 'code-mode exec is missing');
  assert(body.tools.some((tool) => tool.type === 'function'), 'ordinary function tools are missing');
  assert.equal(body.tools.filter((tool) => tool.type === 'namespace' && tool.name === 'collaboration').length, 1, 'collaboration namespace is missing');
  assert.equal(body.tools.filter((tool) => tool.type === 'namespace' && tool.name === 'web').length, 0, 'custom provider must not receive web/run');
  const liteCanonical = liteTools.map(canonicalFragment).sort();
  const standardCanonical = body.tools.filter((tool) => tool.type !== 'web_search').map(canonicalFragment).sort();
  assert.deepEqual(standardCanonical, liteCanonical, 'Lite and standard client-tool definitions differ');
}

async function safeRemove(testRoot) {
  const tempBase = await fsp.realpath(os.tmpdir());
  const realRoot = await fsp.realpath(testRoot);
  assert.equal(path.dirname(realRoot), tempBase, `unsafe cleanup parent: ${realRoot}`);
  assert(path.basename(realRoot).startsWith('codex-provider-compat-shape-macos-'), `unsafe cleanup path: ${realRoot}`);
  await fsp.rm(realRoot, { recursive: true, force: true });
}

const realHomeBefore = await snapshotRealCodexHome();
const testRoot = await fsp.mkdtemp(path.join(os.tmpdir(), 'codex-provider-compat-shape-macos-'));
const paths = {
  codexHome: path.join(testRoot, 'Codex home 测试'),
  userHome: path.join(testRoot, 'User home 测试'),
  tempDirectory: path.join(testRoot, 'Process tmp 测试'),
  workspace: path.join(testRoot, 'Workspace 测试'),
};
let mock = null;
let failure = null;

try {
  for (const directory of Object.values(paths)) await fsp.mkdir(directory, { recursive: true, mode: 0o700 });
  const catalogBytes = await fsp.readFile(catalogPath);
  assert.equal(sha256Bytes(catalogBytes), EXPECTED_CATALOG_SHA256);
  const catalog = JSON.parse(catalogBytes.toString('utf8'));
  assert.equal(catalog.models.length, 8);
  assert.equal(new Set(catalog.models.map((model) => model.slug)).size, catalog.models.length);
  for (const target of TARGET_MODELS) {
    const matches = catalog.models.filter((model) => model.slug === target);
    assert.equal(matches.length, 1);
    assert.equal(matches[0].use_responses_lite, true);
  }
  console.log('PASS pinned official 0.144.3 catalog fixture and SHA-256');

  const codexBinary = process.env.CODEX_BIN;
  assert(codexBinary && path.isAbsolute(codexBinary), 'CODEX_BIN must be an absolute path');
  const version = await runProcess(codexBinary, ['--version'], { cwd: paths.workspace, env: isolatedEnvironment(paths), timeoutMs: 15000 });
  assert.equal(version.code, 0, processDetails(version));
  assert.equal(version.stdout.trim(), `codex-cli ${EXPECTED_VERSION}`);
  console.log(`PASS fixed macOS Codex CLI ${EXPECTED_VERSION}`);

  mock = await startMock();
  await fsp.writeFile(path.join(paths.codexHome, 'config.toml'), testConfig(mock.port, catalogPath), { mode: 0o600 });
  await invokeCodex(codexBinary, paths);
  await mock.stop();
  const liteTools = assertLite(singleRecord(mock));
  mock = null;
  console.log('PASS unpatched macOS Responses Lite request shape');

  mock = await startMock();
  const configPath = path.join(paths.codexHome, 'config.toml');
  await fsp.writeFile(configPath, testConfig(mock.port, catalogPath), { mode: 0o600 });
  const configBefore = await fsp.readFile(configPath);
  await fsp.writeFile(path.join(paths.codexHome, 'models_cache.json'), 'request-shape-cache-before-apply', { mode: 0o600 });
  const cacheBefore = await fsp.readFile(path.join(paths.codexHome, 'models_cache.json'));

  const apply = await invokeTool(paths, [
    'apply', '--yes', '--codex-home', paths.codexHome, '--catalog-file', catalogPath,
  ]);
  assert.equal(apply.code, 0, processDetails(apply));
  assert(apply.stdout.includes(`version source: PATH CLI -> ${EXPECTED_VERSION}`), processDetails(apply));
  assert(apply.stdout.includes('result=applied'), processDetails(apply));
  assert.equal(/^web_search\s*=/m.test(await fsp.readFile(configPath, 'utf8')), false);
  const statePath = path.join(paths.codexHome, 'provider-compat-state.json');
  const state = JSON.parse(await fsp.readFile(statePath, 'utf8'));
  assert.equal(state.patch_id, 'responses-lite-standard-tools');
  assert.equal(state.patch_version, '0.2.0');
  assert.equal(state.codex_version, EXPECTED_VERSION);
  assert.equal(state.source_catalog.sha256, EXPECTED_CATALOG_SHA256);
  assert.equal(state.config.web_search_modified, false);
  assert.equal(state.config.previous_web_search_present, false);
  assert.equal(state.config.previous_web_search, null);
  assert.equal(state.config.previous_web_search_literal, null);
  console.log('PASS macOS apply with automatic PATH CLI version discovery');

  const status = await invokeTool(paths, ['status', '--codex-home', paths.codexHome]);
  assert.equal(status.code, 0, processDetails(status));
  assert(status.stdout.includes(`version source: PATH CLI -> ${EXPECTED_VERSION}`), processDetails(status));
  assert(status.stdout.includes('result=healthy'), processDetails(status));
  console.log('PASS macOS status with automatic PATH CLI version discovery');

  await invokeCodex(codexBinary, paths);
  await mock.stop();
  assertStandard(singleRecord(mock), liteTools, 1);
  mock = null;
  console.log('PASS patched macOS standard Responses request shape, core tool set, and default hosted Web Search');

  const generatedCatalog = state.generated_catalog.path;
  const rollback = await invokeTool(paths, ['rollback', '--yes', '--codex-home', paths.codexHome]);
  assert.equal(rollback.code, 0, processDetails(rollback));
  assert(rollback.stdout.includes('result=rolled-back'), processDetails(rollback));
  assert.deepEqual(await fsp.readFile(configPath), configBefore);
  assert.deepEqual(await fsp.readFile(path.join(paths.codexHome, 'models_cache.json')), cacheBefore);
  assert.equal(fs.existsSync(generatedCatalog), false);
  assert.equal(fs.existsSync(statePath), false);
  assert.equal(fs.existsSync(path.join(paths.codexHome, 'provider-compat-transaction.json')), false);
  const archives = (await fsp.readdir(paths.codexHome)).filter((name) => name.startsWith('provider-compat-state.json.rolled-back-'));
  assert.equal(archives.length, 1);
  console.log('PASS macOS rollback restored config, cache, catalog, state, and transaction state');

  mock = await startMock();
  await fsp.writeFile(configPath, testConfig(mock.port, catalogPath, 'live'), { mode: 0o600 });
  const liveConfigBefore = await fsp.readFile(configPath);
  const liveCacheBefore = await fsp.readFile(path.join(paths.codexHome, 'models_cache.json'));
  const liveApply = await invokeTool(paths, [
    'apply', '--yes', '--codex-home', paths.codexHome, '--catalog-file', catalogPath,
  ]);
  assert.equal(liveApply.code, 0, processDetails(liveApply));
  const liveState = JSON.parse(await fsp.readFile(statePath, 'utf8'));
  assert.equal(liveState.config.web_search_modified, false);
  assert.equal(liveState.config.previous_web_search_present, false);
  assert.equal((await fsp.readFile(configPath, 'utf8')).includes('web_search = "live"'), true);
  const liveStatus = await invokeTool(paths, ['status', '--codex-home', paths.codexHome]);
  assert.equal(liveStatus.code, 0, processDetails(liveStatus));
  console.log('PASS macOS apply/status preserves user-configured live Web Search without owning it');

  await invokeCodex(codexBinary, paths);
  await mock.stop();
  assertStandard(singleRecord(mock), liteTools, 1);
  mock = null;
  console.log('PASS user-configured live Web Search adds only the hosted tool on macOS');

  const liveGeneratedCatalog = liveState.generated_catalog.path;
  const liveRollback = await invokeTool(paths, ['rollback', '--yes', '--codex-home', paths.codexHome]);
  assert.equal(liveRollback.code, 0, processDetails(liveRollback));
  assert.deepEqual(await fsp.readFile(configPath), liveConfigBefore);
  assert.deepEqual(await fsp.readFile(path.join(paths.codexHome, 'models_cache.json')), liveCacheBefore);
  assert.equal(fs.existsSync(liveGeneratedCatalog), false);
  assert.equal(fs.existsSync(statePath), false);
  assert.equal(fs.existsSync(path.join(paths.codexHome, 'provider-compat-transaction.json')), false);
  console.log('PASS macOS rollback preserves the user-configured live Web Search setting');
} catch (error) {
  failure = error;
} finally {
  if (mock) {
    try { await mock.stop(); } catch {}
  }
  try {
    const realHomeAfter = await snapshotRealCodexHome();
    if (realHomeBefore !== realHomeAfter && !failure) failure = new Error('real Codex home hashes changed during macOS request-shape test');
  } catch (error) {
    failure ||= error;
  }
  try { await safeRemove(testRoot); } catch (error) { failure ||= error; }
}

if (failure) throw failure;
console.log('PASS real Codex home hashes unchanged');
console.log('macOS request-shape integration test: passed=11 failed=0');
