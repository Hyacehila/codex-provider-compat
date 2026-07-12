$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'test-real-provider-harness.ps1 requires PowerShell 7 or later.'
}

$testsRoot = $PSScriptRoot
$harness = Join-Path $testsRoot 'test-real-provider.ps1'
$mcp = Join-Path $testsRoot 'fixtures\provider-compat-mcp-echo.mjs'

foreach ($path in @($harness, $mcp)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "missing fixture: $path" }
}

$source = Get-Content -LiteralPath $harness -Raw
foreach ($required in @(
    "I-understand-this-is-a-billable-real-provider-test",
    "status_enum = @('passed', 'failed', 'not-supported', 'not-run')",
    "'function-dynamic-tool'", "'image-detail-original'", "'image-generation'",
    "'client-auth-isolation'", "'no-deterministic-hosted-fixture'",
    'Add-NotRunResult $results ''function-dynamic-tool'' $model ''client-auth-isolation''',
    'Add-NotRunResult $results ''image-detail-original'' $model ''client-auth-isolation''',
    'requires_openai_auth = true', 'sandbox_mode = "workspace-write"',
    '[sandbox_workspace_write]', 'network_access = false', 'CODEX_API_KEY = $ApiKey',
    'default_tools_approval_mode = "approve"', 'enabled_tools = ["echo_nonce"]',
    '$script:WorstCaseTurnBudget = 44', "case='collaboration-single-spawn';model=`$model",
    'function Test-RetryableFailure', 'reason = Get-PublicReason', '$models = @($models)',
    'McpStatuses = @($mcpStatuses | Sort-Object -Unique)', "case='mcp-final-echo';model=`$Model",
    'CODEX_PROVIDER_COMPAT_REAL_CASE_FILTER', 'the mcp-function directed filter requires exactly gpt-5.6-sol'
)) {
    if (-not $source.Contains($required, [StringComparison]::Ordinal)) { throw "real-provider harness is missing required invariant: $required" }
}
foreach ($forbidden in @(
    'I-understand-this-sends-billable-provider-requests', 'env_key =', 'auth.json',
    'Get-RealHomeSnapshot', 'CODEX_PROVIDER_COMPAT_REAL_HOME_SNAPSHOT_ROOT',
    'endpoint_sha256', 'endpoint_domain', 'raw_response', 'raw_events', 'response_body',
    "Status='inconclusive'", "status='inconclusive'"
)) {
    if ($source.Contains($forbidden, [StringComparison]::OrdinalIgnoreCase)) { throw "real-provider harness contains forbidden persistence or state marker: $forbidden" }
}
if ($source -match '(?m)^\s*(?:endpoint|domain|request_id|raw_[A-Za-z0-9_]*)\s*=') {
    throw 'real-provider summary must not persist endpoint, domain, request id, or raw response fields'
}
$allowedStatuses = @('passed', 'failed', 'not-supported', 'not-run')
foreach ($match in [regex]::Matches($source, '(?i)\bstatus\s*=\s*''([^'']+)''')) {
    if ($match.Groups[1].Value -notin $allowedStatuses) { throw "unexpected public status literal: $($match.Groups[1].Value)" }
}
if ($source.Contains('for ($multiAttempt', [StringComparison]::Ordinal)) {
    throw 'multi-turn acceptance must remain a single attempt to preserve the hard turn budget'
}
$resumeBranch = $source.IndexOf('if (-not [string]::IsNullOrWhiteSpace($ResumeThreadId))', [StringComparison]::Ordinal)
$resumeColor = $source.IndexOf("`$arguments.Add('--color')", $resumeBranch, [StringComparison]::Ordinal)
$resumeCommand = $source.IndexOf("`$arguments.Add('resume')", $resumeBranch, [StringComparison]::Ordinal)
if ($resumeBranch -lt 0 -or $resumeColor -lt 0 -or $resumeCommand -lt 0 -or $resumeColor -gt $resumeCommand) {
    throw 'resume arguments must be ordered as codex exec --color never resume'
}

$tokens = $null
$errors = $null
[void][Management.Automation.Language.Parser]::ParseFile($harness, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw "real-provider harness has PowerShell parse errors: $($errors[0].Message)" }

$node = Get-Command node -ErrorAction Stop
$nodeCheck = & $node.Source --check $mcp 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) { throw "MCP fixture failed node --check: $nodeCheck" }

$codex = Get-Command codex -ErrorAction Stop
$helpPsi = [Diagnostics.ProcessStartInfo]::new()
$helpPsi.UseShellExecute = $false
$helpPsi.RedirectStandardOutput = $true
$helpPsi.RedirectStandardError = $true
$helpPsi.CreateNoWindow = $true
if ([IO.Path]::GetExtension($codex.Source).Equals('.ps1', [StringComparison]::OrdinalIgnoreCase)) {
    $helpPsi.FileName = (Get-Process -Id $PID).Path
    foreach ($argument in @('-NoProfile', '-File', $codex.Source, 'exec', '--color', 'never', 'resume', '--help')) {
        [void]$helpPsi.ArgumentList.Add($argument)
    }
} else {
    $helpPsi.FileName = $codex.Source
    foreach ($argument in @('exec', '--color', 'never', 'resume', '--help')) { [void]$helpPsi.ArgumentList.Add($argument) }
}
foreach ($name in @($helpPsi.Environment.Keys)) {
    if ($name -match '(?i)(OPENAI|CODEX|CHATGPT|AZURE|PROXY|TOKEN|KEY|SECRET|AUTH|TELEMETRY|OTEL)') {
        [void]$helpPsi.Environment.Remove($name)
    }
}
$helpProcess = [Diagnostics.Process]::Start($helpPsi)
$helpStdoutTask = $helpProcess.StandardOutput.ReadToEndAsync()
$helpStderrTask = $helpProcess.StandardError.ReadToEndAsync()
if (-not $helpProcess.WaitForExit(15000)) {
    try { $helpProcess.Kill($true) } catch { $helpProcess.Kill() }
    throw 'codex resume help validation timed out'
}
$helpOutput = $helpStdoutTask.GetAwaiter().GetResult() + "`n" + $helpStderrTask.GetAwaiter().GetResult()
if ($helpProcess.ExitCode -ne 0 -or $helpOutput -notmatch 'Resume a previous session') {
    throw "codex rejected the required exec --color never resume ordering: $helpOutput"
}

$before = @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Directory -Filter 'codex-provider-compat-real-*' -ErrorAction SilentlyContinue |
    ForEach-Object FullName | Sort-Object)

$psi = [Diagnostics.ProcessStartInfo]::new()
$psi.FileName = (Get-Process -Id $PID).Path
$psi.UseShellExecute = $false
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.CreateNoWindow = $true
[void]$psi.ArgumentList.Add('-NoProfile')
[void]$psi.ArgumentList.Add('-File')
[void]$psi.ArgumentList.Add($harness)
foreach ($name in @($psi.Environment.Keys)) {
    if ($name -match '(?i)(OPENAI|CODEX|CHATGPT|AZURE|PROXY|TOKEN|KEY|SECRET|AUTH|TELEMETRY|OTEL)') {
        [void]$psi.Environment.Remove($name)
    }
}
$psi.Environment['CODEX_PROVIDER_COMPAT_REAL_CONFIRM'] = 'I-understand-this-is-a-billable-real-provider-test'
$psi.Environment['CODEX_PROVIDER_COMPAT_REAL_BASE_URL'] = 'https://provider.invalid/v1'
[void]$psi.Environment.Remove('CODEX_PROVIDER_COMPAT_REAL_API_KEY')
[void]$psi.Environment.Remove('CODEX_PROVIDER_COMPAT_REAL_CATALOG_FILE')
[void]$psi.Environment.Remove('CODEX_PROVIDER_COMPAT_REAL_CODEX_BIN')
[void]$psi.Environment.Remove('CODEX_PROVIDER_COMPAT_REAL_MODELS')
[void]$psi.Environment.Remove('CODEX_PROVIDER_COMPAT_REAL_CASE_FILTER')

$process = [Diagnostics.Process]::Start($psi)
$stdoutTask = $process.StandardOutput.ReadToEndAsync()
$stderrTask = $process.StandardError.ReadToEndAsync()
if (-not $process.WaitForExit(15000)) {
    try { $process.Kill($true) } catch { $process.Kill() }
    throw 'credential-refusal check timed out'
}
$stdout = $stdoutTask.GetAwaiter().GetResult()
$stderr = $stderrTask.GetAwaiter().GetResult()
if ($process.ExitCode -eq 0) { throw 'real-provider harness accepted missing credentials' }
if (($stdout + "`n" + $stderr) -notmatch 'required environment variable is missing: CODEX_PROVIDER_COMPAT_REAL_API_KEY') {
    throw "real-provider harness did not fail at the credential gate: $stdout $stderr"
}

$after = @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Directory -Filter 'codex-provider-compat-real-*' -ErrorAction SilentlyContinue |
    ForEach-Object FullName | Sort-Object)
if (($before -join "`n") -ne ($after -join "`n")) { throw 'credential-refusal check created a real-provider temp directory' }

Write-Host 'PASS real-provider static schema, resume CLI ordering, MCP syntax, and no-credential fail-closed gate'
