$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Maintenance-only real-provider smoke harness. It is intentionally not called
# by normal CI or included in release packages. It never discovers credentials
# from the user's Codex home: all authority must arrive through explicit
# environment variables plus the exact confirmation phrase below.
# Required variables:
#   CODEX_PROVIDER_COMPAT_REAL_CONFIRM
#   CODEX_PROVIDER_COMPAT_REAL_BASE_URL
#   CODEX_PROVIDER_COMPAT_REAL_API_KEY
#   CODEX_PROVIDER_COMPAT_REAL_CATALOG_FILE
# Optional variables:
#   CODEX_PROVIDER_COMPAT_REAL_MODELS (comma-separated target models)
#   CODEX_PROVIDER_COMPAT_REAL_CODEX_BIN
#   CODEX_PROVIDER_COMPAT_REAL_SUMMARY_DIR

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'test-real-provider.ps1 requires PowerShell 7 or later.'
}

$script:ExpectedConfirmation = 'I-understand-this-is-a-billable-real-provider-test'
$script:ExpectedCodexVersion = '0.144.1'
$script:TargetModels = @('gpt-5.6-sol', 'gpt-5.6-terra', 'gpt-5.6-luna')
$script:MaxTurns = 48
$script:MaxAttempts = 2
$script:WorstCaseTurnBudget = 44
$script:TurnTimeoutMilliseconds = 120000
$script:TurnCount = 0
$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:CompatTool = Join-Path $script:RepoRoot 'codex-provider-compat.ps1'
$script:McpFixture = Join-Path $PSScriptRoot 'fixtures\provider-compat-mcp-echo.mjs'

if ($script:WorstCaseTurnBudget -gt $script:MaxTurns) {
    throw 'real-provider worst-case turn budget exceeds the hard limit'
}

function Get-RequiredEnvironment([string]$Name) {
    $value = [Environment]::GetEnvironmentVariable($Name, 'Process')
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "required environment variable is missing: $Name"
    }
    return $value
}

function Quote-TomlString([string]$Value) {
    return ($Value | ConvertTo-Json -Compress)
}

function Redact-Text([string]$Text, [string]$Secret, [string]$BaseUrl) {
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $safe = $Text
    if (-not [string]::IsNullOrEmpty($Secret)) { $safe = $safe.Replace($Secret, '<redacted-secret>') }
    if (-not [string]::IsNullOrEmpty($BaseUrl)) {
        $safe = $safe.Replace($BaseUrl, '<redacted-endpoint>')
        try {
            $endpoint = [Uri]$BaseUrl
            foreach ($part in @($endpoint.GetLeftPart([UriPartial]::Authority), $endpoint.Authority, $endpoint.Host) | Sort-Object Length -Descending -Unique) {
                if (-not [string]::IsNullOrWhiteSpace($part)) { $safe = $safe.Replace($part, '<redacted-endpoint>') }
            }
        } catch { }
    }
    $safe = [regex]::Replace($safe, '(?i)authorization\s*[:=]\s*[^\s,;]+', 'authorization=<redacted>')
    $safe = [regex]::Replace($safe, '(?i)bearer\s+[A-Za-z0-9._~+\-/=]+', 'Bearer <redacted>')
    $safe = [regex]::Replace($safe, '(?i)\b(?:sk|key|token)[-_][A-Za-z0-9._~+\-/=]{12,}\b', '<redacted-token>')
    $safe = [regex]::Replace($safe, '(?i)(?:x[-_])?request[-_ ]?id\s*[:=]\s*[^\s,;]+', 'request_id=<redacted>')
    $safe = [regex]::Replace($safe, '(?i)\breq_[A-Za-z0-9._~-]{8,}\b', '<redacted-request-id>')
    if ($safe.Length -gt 500) { $safe = $safe.Substring(0, 500) + '<truncated>' }
    return $safe
}

function Resolve-CodexBinary {
    $explicit = [Environment]::GetEnvironmentVariable('CODEX_PROVIDER_COMPAT_REAL_CODEX_BIN', 'Process')
    if (-not [string]::IsNullOrWhiteSpace($explicit)) {
        $path = [IO.Path]::GetFullPath($explicit)
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'explicit Codex binary does not exist' }
        return $path
    }
    $npm = Get-Command npm.cmd -CommandType Application -ErrorAction SilentlyContinue
    if ($npm) {
        $npmRoot = (& $npm.Source root -g 2>$null | Out-String).Trim()
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($npmRoot)) {
            $packageRoot = Join-Path $npmRoot '@openai\codex\node_modules'
            $matches = @(Get-ChildItem -LiteralPath $packageRoot -Recurse -Filter codex.exe -File -ErrorAction SilentlyContinue |
                Where-Object FullName -Match '[\\/]bin[\\/]codex\.exe$')
            if ($matches.Count -eq 1) { return $matches[0].FullName }
        }
    }
    $native = Get-Command codex.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($native) { return $native.Source }
    throw 'could not resolve a native codex.exe; set CODEX_PROVIDER_COMPAT_REAL_CODEX_BIN'
}

function Resolve-NodeBinary {
    $node = Get-Command node.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $node) { $node = Get-Command node -ErrorAction SilentlyContinue | Select-Object -First 1 }
    if (-not $node) { throw 'Node.js is required for the maintenance-only MCP echo fixture' }
    return [IO.Path]::GetFullPath($node.Source)
}

function New-ProcessResult($Process, [string]$Stdout, [string]$Stderr, [bool]$TimedOut, [long]$DurationMs) {
    return [pscustomobject]@{
        ExitCode = if ($TimedOut) { $null } else { $Process.ExitCode }
        Stdout = $Stdout
        Stderr = $Stderr
        TimedOut = $TimedOut
        DurationMs = $DurationMs
    }
}

function Invoke-IsolatedProcess(
    [string]$FilePath,
    [string[]]$Arguments,
    [hashtable]$Environment,
    [int]$TimeoutMilliseconds = 120000
) {
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $FilePath
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    foreach ($argument in $Arguments) { [void]$psi.ArgumentList.Add($argument) }
    foreach ($name in @($psi.Environment.Keys)) {
        if ($name -match '(?i)(OPENAI|CODEX|CHATGPT|AZURE|PROXY|TOKEN|KEY|SECRET|AUTH|TELEMETRY|OTEL)') {
            [void]$psi.Environment.Remove($name)
        }
    }
    foreach ($entry in $Environment.GetEnumerator()) {
        if ($null -eq $entry.Value) { [void]$psi.Environment.Remove([string]$entry.Key) }
        else { $psi.Environment[[string]$entry.Key] = [string]$entry.Value }
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $psi
    $watch = [Diagnostics.Stopwatch]::StartNew()
    if (-not $process.Start()) { throw 'failed to start child process' }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $timedOut = -not $process.WaitForExit($TimeoutMilliseconds)
    if ($timedOut) {
        try { $process.Kill($true) } catch { try { $process.Kill() } catch {} }
        [void]$process.WaitForExit(5000)
    }
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    $watch.Stop()
    return New-ProcessResult $process $stdout $stderr $timedOut $watch.ElapsedMilliseconds
}

function ConvertFrom-CodexJsonl([string]$Text) {
    $events = [Collections.Generic.List[object]]::new()
    foreach ($line in ($Text -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $events.Add(($line | ConvertFrom-Json -Depth 100)) } catch { }
    }
    return @($events)
}

function Get-TraceSummary([object[]]$Events) {
    $itemTypes = [Collections.Generic.List[string]]::new()
    $toolNames = [Collections.Generic.List[string]]::new()
    $messages = [Collections.Generic.List[string]]::new()
    $mcpStatuses = [Collections.Generic.List[string]]::new()
    $mcpResultTexts = [Collections.Generic.List[string]]::new()
    $mcpErrors = [Collections.Generic.List[string]]::new()
    $threadId = $null
    $usage = $null
    foreach ($event in $Events) {
        if ([string]$event.type -eq 'thread.started') {
            if ($event.PSObject.Properties['thread_id']) { $threadId = [string]$event.thread_id }
            elseif ($event.PSObject.Properties['threadId']) { $threadId = [string]$event.threadId }
        }
        if ([string]$event.type -eq 'turn.completed' -and $event.PSObject.Properties['usage']) { $usage = $event.usage }
        if ($event.PSObject.Properties['item'] -and $null -ne $event.item) {
            $item = $event.item
            $itemType = [string]$item.type
            if (-not [string]::IsNullOrWhiteSpace($itemType)) { $itemTypes.Add($itemType) }
            foreach ($nameProperty in @('name', 'tool_name', 'toolName')) {
                if ($item.PSObject.Properties[$nameProperty]) {
                    $name = [string]$item.$nameProperty
                    if (-not [string]::IsNullOrWhiteSpace($name)) { $toolNames.Add($name) }
                }
            }
            if ($itemType -eq 'agent_message') {
                foreach ($textProperty in @('text', 'content')) {
                    if ($item.PSObject.Properties[$textProperty] -and $item.$textProperty -is [string]) {
                        $messages.Add([string]$item.$textProperty)
                    }
                }
            }
            if ($itemType -eq 'mcp_tool_call') {
                if ($item.PSObject.Properties['status']) {
                    $mcpStatuses.Add([string]$item.status)
                }
                if ($item.PSObject.Properties['result'] -and $null -ne $item.result -and
                    $item.result.PSObject.Properties['content']) {
                    foreach ($content in @($item.result.content)) {
                        if ($content -and $content.PSObject.Properties['text'] -and $content.text -is [string]) {
                            $mcpResultTexts.Add([string]$content.text)
                        }
                    }
                }
                if ($item.PSObject.Properties['error'] -and $null -ne $item.error -and
                    $item.error.PSObject.Properties['message'] -and $item.error.message -is [string]) {
                    $mcpErrors.Add([string]$item.error.message)
                }
            }
        }
    }
    return [pscustomobject]@{
        ThreadId = $threadId
        FinalMessage = if ($messages.Count) { $messages[$messages.Count - 1] } else { '' }
        ItemTypes = @($itemTypes | Sort-Object -Unique)
        ToolNames = @($toolNames | Sort-Object -Unique)
        McpStatuses = @($mcpStatuses | Sort-Object -Unique)
        McpResultTexts = @($mcpResultTexts)
        McpErrors = @($mcpErrors | Sort-Object -Unique)
        Usage = $usage
    }
}

function Test-TraceContains([object]$Trace, [string]$Expected) {
    return -not [string]::IsNullOrWhiteSpace($Trace.FinalMessage) -and $Trace.FinalMessage.Contains($Expected, [StringComparison]::Ordinal)
}

function Test-TraceEquals([object]$Trace, [string]$Expected) {
    return -not [string]::IsNullOrWhiteSpace($Trace.FinalMessage) -and
        $Trace.FinalMessage.Trim().Equals($Expected, [StringComparison]::Ordinal)
}

function Invoke-CodexTurn(
    [string]$CodexBinary,
    [string]$CodexHome,
    [string]$WorkDir,
    [string]$Model,
    [string]$Prompt,
    [string]$ApiKey,
    [string]$ImagePath,
    [string]$ResumeThreadId,
    [bool]$EnableWebSearch = $false
) {
    if ($script:TurnCount -ge $script:MaxTurns) { throw "real-provider turn budget exhausted ($($script:MaxTurns))" }
    $script:TurnCount++
    $arguments = [Collections.Generic.List[string]]::new()
    $arguments.Add('exec')
    if (-not [string]::IsNullOrWhiteSpace($ResumeThreadId)) {
        $arguments.Add('--color')
        $arguments.Add('never')
        $arguments.Add('resume')
        $arguments.Add('--skip-git-repo-check')
        $arguments.Add('--ignore-rules')
        $arguments.Add('--strict-config')
        $arguments.Add('--json')
        if ($EnableWebSearch) { $arguments.Add('-c'); $arguments.Add('web_search="live"') }
        $arguments.Add('-m')
        $arguments.Add($Model)
        if (-not [string]::IsNullOrWhiteSpace($ImagePath)) { $arguments.Add('-i'); $arguments.Add($ImagePath) }
        $arguments.Add($ResumeThreadId)
        $arguments.Add($Prompt)
    } else {
        $arguments.Add('--skip-git-repo-check')
        $arguments.Add('--ignore-rules')
        $arguments.Add('--strict-config')
        $arguments.Add('--json')
        $arguments.Add('--color')
        $arguments.Add('never')
        if ($EnableWebSearch) { $arguments.Add('-c'); $arguments.Add('web_search="live"') }
        $arguments.Add('-C')
        $arguments.Add($WorkDir)
        $arguments.Add('-m')
        $arguments.Add($Model)
        if (-not [string]::IsNullOrWhiteSpace($ImagePath)) { $arguments.Add('-i'); $arguments.Add($ImagePath) }
        $arguments.Add($Prompt)
    }
    $environment = @{
        CODEX_HOME = $CodexHome
        HOME = $CodexHome
        USERPROFILE = $CodexHome
        CODEX_API_KEY = $ApiKey
        NO_COLOR = '1'
        RUST_LOG = 'off'
        CODEX_PROVIDER_COMPAT_TEST_VERSIONS = $null
        CODEX_PROVIDER_COMPAT_TEST_DOWNLOAD_MODE = $null
        CODEX_PROVIDER_COMPAT_TEST_FAIL_STAGE = $null
        CODEX_PROVIDER_COMPAT_TEST_CRASH_STAGE = $null
        CODEX_PROVIDER_COMPAT_TEST_PAUSE_STAGE = $null
        CODEX_PROVIDER_COMPAT_TEST_PAUSE_EVENT = $null
        CODEX_PROVIDER_COMPAT_INTERNAL_TEST_URL = $null
        CODEX_PROVIDER_COMPAT_INTERNAL_TEST_TRANSPORT = $null
        CODEX_PROVIDER_COMPAT_INTERNAL_TEST_CONFIRM = $null
    }
    $result = Invoke-IsolatedProcess $CodexBinary @($arguments) $environment $script:TurnTimeoutMilliseconds
    $events = ConvertFrom-CodexJsonl $result.Stdout
    return [pscustomobject]@{ Process = $result; Events = $events; Trace = Get-TraceSummary $events }
}

function Add-Result([Collections.Generic.List[object]]$Results, [hashtable]$Value) {
    $Results.Add([pscustomobject]$Value)
}

function Add-NotRunResult(
    [Collections.Generic.List[object]]$Results,
    [string]$CaseId,
    [string]$Model,
    [string]$ReasonCode,
    [string]$Diagnostic
) {
    Add-Result $Results ([ordered]@{
        case=$CaseId;model=$Model;status='not-run';attempts=0;duration_ms=0;exit_code=$null;timed_out=$false
        item_types=@();tool_names=@();usage=$null;reason=$ReasonCode;diagnostic=$Diagnostic
    })
}

function Get-PublicStatus([string]$Status, $Run) {
    if ($Status -eq 'failed' -and $Run) {
        $combined = [string]$Run.Process.Stdout + "`n" + [string]$Run.Process.Stderr
        if ($combined -match '(?i)(not supported|unsupported|unknown tool|tool[^\r\n]{0,80}not available)') {
            return 'not-supported'
        }
    }
    if ($Status -notin @('passed', 'failed', 'not-supported', 'not-run')) { return 'failed' }
    return $Status
}

function Test-RetryableFailure($Run) {
    if ($Run.Process.TimedOut) { return $true }
    if ($Run.Process.ExitCode -eq 0) { return $false }
    $combined = [string]$Run.Process.Stdout + "`n" + [string]$Run.Process.Stderr
    if ($combined -match '(?i)(?:\b408\b|\b429\b|\b5\d\d\b)') { return $true }
    return $combined -match '(?i)(network[^\r\n]{0,40}timeout|request[^\r\n]{0,40}timeout|stream[^\r\n]{0,40}timeout|operation timed out|timed out)'
}

function Get-PublicReason([string]$Status, $Run, [string]$Diagnostic, [string]$ExplicitReason = '') {
    if ($Status -eq 'passed') { return $null }
    if (-not [string]::IsNullOrWhiteSpace($ExplicitReason)) { return $ExplicitReason }
    if ($Run -and $Run.Process.TimedOut) { return 'timeout' }
    if ($Status -eq 'not-supported') { return 'provider' }
    if ($Status -eq 'not-run') { return 'tool-not-selected' }
    $combined = [string]$Diagnostic + "`n" + $(if ($Run) { [string]$Run.Process.Stderr } else { '' })
    if ($combined -match '(?i)(schema|protocol|invalid (?:request|tool|function)|malformed|unknown field)') { return 'protocol' }
    if ($Run -and $Run.Process.ExitCode -ne 0) { return 'provider' }
    if ($Run -and @($Run.Trace.ItemTypes).Count -gt 0) { return 'client' }
    return 'tool-not-selected'
}

function Invoke-RetryCase(
    [Collections.Generic.List[object]]$Results,
    [string]$CaseId,
    [string]$Model,
    [scriptblock]$Attempt,
    [scriptblock]$Evaluate,
    [string]$ApiKey,
    [string]$BaseUrl
) {
    for ($attemptNumber = 1; $attemptNumber -le $script:MaxAttempts; $attemptNumber++) {
        $run = & $Attempt
        $evaluation = & $Evaluate $run
        $rawStatus = [string]$evaluation.Status
        $shouldRetry = $attemptNumber -lt $script:MaxAttempts -and $rawStatus -eq 'failed' -and (Test-RetryableFailure $run)
        if (-not $shouldRetry) {
            $status = Get-PublicStatus $rawStatus $run
            $diagnostic = Redact-Text ([string]$evaluation.Diagnostic) $ApiKey $BaseUrl
            Add-Result $Results ([ordered]@{
                case = $CaseId
                model = $Model
                status = $status
                attempts = $attemptNumber
                duration_ms = [long]$run.Process.DurationMs
                exit_code = $run.Process.ExitCode
                timed_out = [bool]$run.Process.TimedOut
                item_types = @($run.Trace.ItemTypes)
                tool_names = @($run.Trace.ToolNames)
                usage = $run.Trace.Usage
                reason = Get-PublicReason $status $run $diagnostic
                diagnostic = $diagnostic
            })
            return $run
        }
    }
}

function Invoke-McpAcceptance(
    [Collections.Generic.List[object]]$Results,
    [string]$CodexBinary,
    [string]$CodexHome,
    [string]$WorkDir,
    [string]$Model,
    [string]$ApiKey,
    [string]$BaseUrl
) {
    $mcpMarker = 'MCP_' + [guid]::NewGuid().ToString('N')
    $mcpRun = Invoke-RetryCase $Results 'mcp-function' $Model {
        Invoke-CodexTurn $CodexBinary $CodexHome $WorkDir $Model "You must call the provider_compat_echo MCP tool echo_nonce with nonce $mcpMarker, then return exactly the tool output." $ApiKey $null $null
    } {
        param($run)
        $usedMcp = @($run.Trace.ItemTypes | Where-Object { $_ -eq 'mcp_tool_call' }).Count -gt 0
        $completed = @($run.Trace.McpStatuses | Where-Object { $_ -eq 'completed' }).Count -gt 0
        $resultMatched = @($run.Trace.McpResultTexts | Where-Object { $_.Contains($mcpMarker, [StringComparison]::Ordinal) }).Count -gt 0
        if ($run.Process.ExitCode -eq 0 -and $usedMcp -and $completed -and $resultMatched) { return [pscustomobject]@{Status='passed';Diagnostic=''} }
        if (-not $usedMcp) { return [pscustomobject]@{Status='failed';Diagnostic='no mcp_tool_call event was observed'} }
        if (-not $completed) {
            $errorSummary = @($run.Trace.McpErrors) -join ' | '
            return [pscustomobject]@{Status='failed';Diagnostic=('MCP event did not complete; observed statuses=' + (@($run.Trace.McpStatuses) -join ',') + '; local MCP error=' + $errorSummary)}
        }
        return [pscustomobject]@{Status='failed';Diagnostic='completed MCP result did not contain the marker'}
    } $ApiKey $BaseUrl
    $mcpFinalStatus = if ($mcpRun.Process.ExitCode -eq 0 -and (Test-TraceContains $mcpRun.Trace $mcpMarker)) { 'passed' } else { 'failed' }
    $mcpTransportCompleted = @($mcpRun.Trace.McpStatuses | Where-Object { $_ -eq 'completed' }).Count -gt 0
    $mcpFinalDiagnostic = if ($mcpFinalStatus -eq 'passed') { '' } elseif ($mcpTransportCompleted) { 'the MCP call completed, but the final assistant message did not contain the returned marker' } else { 'the MCP transport did not complete, so no final marker echo was expected' }
    Add-Result $Results ([ordered]@{
        case='mcp-final-echo';model=$Model;status=$mcpFinalStatus;attempts=1
        duration_ms=$mcpRun.Process.DurationMs;exit_code=$mcpRun.Process.ExitCode;timed_out=$mcpRun.Process.TimedOut
        item_types=@($mcpRun.Trace.ItemTypes);tool_names=@($mcpRun.Trace.ToolNames);usage=$mcpRun.Trace.Usage
        reason=Get-PublicReason $mcpFinalStatus $mcpRun $mcpFinalDiagnostic
        diagnostic=$mcpFinalDiagnostic
    })
}

function New-TestImage([string]$Path, [string]$Marker) {
    Add-Type -AssemblyName System.Drawing
    $bitmap = [Drawing.Bitmap]::new(1600, 500)
    try {
        $graphics = [Drawing.Graphics]::FromImage($bitmap)
        try {
            $graphics.Clear([Drawing.Color]::White)
            $font = [Drawing.Font]::new('Arial', 82, [Drawing.FontStyle]::Bold, [Drawing.GraphicsUnit]::Pixel)
            try { $graphics.DrawString($Marker, $font, [Drawing.Brushes]::Black, 40, 170) } finally { $font.Dispose() }
        } finally { $graphics.Dispose() }
        $bitmap.Save($Path, [Drawing.Imaging.ImageFormat]::Png)
    } finally { $bitmap.Dispose() }
}

function Write-MinimalConfig(
    [string]$Path,
    [string]$BaseUrl,
    [string]$CatalogPath,
    [string]$Model,
    [string]$NodeBinary
) {
    $config = @"
model = $(Quote-TomlString $Model)
model_provider = "provider_compat_real"
model_catalog_json = $(Quote-TomlString $CatalogPath)
approval_policy = "never"
sandbox_mode = "workspace-write"
web_search = "disabled"
check_for_update_on_startup = false

[sandbox_workspace_write]
network_access = false

[analytics]
enabled = false

[feedback]
enabled = false

[otel]
exporter = "none"
trace_exporter = "none"
metrics_exporter = "none"
log_user_prompt = false

[shell_environment_policy]
inherit = "core"
exclude = ["CODEX_API_KEY", "CODEX_PROVIDER_COMPAT_REAL_API_KEY", "OPENAI_API_KEY"]

[features]
code_mode = true
unified_exec = true
multi_agent = true
apps = false
plugins = false

[model_providers.provider_compat_real]
name = "provider-compat-real-maintainer-test"
base_url = $(Quote-TomlString $BaseUrl)
wire_api = "responses"
requires_openai_auth = true
request_max_retries = 0
stream_max_retries = 0
stream_idle_timeout_ms = 120000

[mcp_servers.provider_compat_echo]
command = $(Quote-TomlString $NodeBinary)
args = [$(Quote-TomlString $script:McpFixture)]
startup_timeout_sec = 10
tool_timeout_sec = 30
default_tools_approval_mode = "approve"
enabled_tools = ["echo_nonce"]
"@
    [IO.File]::WriteAllText($Path, $config, [Text.UTF8Encoding]::new($false))
}

function Invoke-CompatTool([string]$CodexHome, [string[]]$Arguments) {
    $pwsh = (Get-Process -Id $PID).Path
    $environment = @{
        CODEX_HOME = $CodexHome
        CODEX_PROVIDER_COMPAT_TEST_VERSIONS = $null
        CODEX_PROVIDER_COMPAT_TEST_DOWNLOAD_MODE = $null
        CODEX_PROVIDER_COMPAT_TEST_FAIL_STAGE = $null
        CODEX_PROVIDER_COMPAT_TEST_CRASH_STAGE = $null
        CODEX_PROVIDER_COMPAT_TEST_PAUSE_STAGE = $null
        CODEX_PROVIDER_COMPAT_TEST_PAUSE_EVENT = $null
        CODEX_PROVIDER_COMPAT_INTERNAL_TEST_URL = $null
        CODEX_PROVIDER_COMPAT_INTERNAL_TEST_TRANSPORT = $null
        CODEX_PROVIDER_COMPAT_INTERNAL_TEST_CONFIRM = $null
    }
    return Invoke-IsolatedProcess $pwsh (@('-NoProfile', '-File', $script:CompatTool) + $Arguments) $environment 120000
}

$confirmation = Get-RequiredEnvironment 'CODEX_PROVIDER_COMPAT_REAL_CONFIRM'
if (-not $confirmation.Equals($script:ExpectedConfirmation, [StringComparison]::Ordinal)) {
    throw 'real-provider confirmation phrase is missing or incorrect'
}

$baseUrl = Get-RequiredEnvironment 'CODEX_PROVIDER_COMPAT_REAL_BASE_URL'
$apiKey = Get-RequiredEnvironment 'CODEX_PROVIDER_COMPAT_REAL_API_KEY'
$catalogPath = [IO.Path]::GetFullPath((Get-RequiredEnvironment 'CODEX_PROVIDER_COMPAT_REAL_CATALOG_FILE'))
if (-not (Test-Path -LiteralPath $catalogPath -PathType Leaf)) { throw 'real-provider catalog file does not exist' }

$uri = $null
if (-not [Uri]::TryCreate($baseUrl, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne 'https') {
    throw 'real-provider endpoint must be an absolute HTTPS URL'
}
if (-not [string]::IsNullOrEmpty($uri.UserInfo) -or -not [string]::IsNullOrEmpty($uri.Query) -or
    -not [string]::IsNullOrEmpty($uri.Fragment)) {
    throw 'real-provider endpoint must not contain userinfo, query, or fragment data'
}

$modelsValue = [Environment]::GetEnvironmentVariable('CODEX_PROVIDER_COMPAT_REAL_MODELS', 'Process')
$models = if ([string]::IsNullOrWhiteSpace($modelsValue)) { @($script:TargetModels) } else {
    @($modelsValue -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}
$models = @($models)
if (-not $models.Count) { throw 'no real-provider models were selected' }
foreach ($model in $models) {
    if ($model -notin $script:TargetModels) { throw "unsupported real-provider test model: $model" }
}
if (@($models | Sort-Object -Unique).Count -ne $models.Count) { throw 'real-provider model list contains duplicates' }
$caseFilter = [Environment]::GetEnvironmentVariable('CODEX_PROVIDER_COMPAT_REAL_CASE_FILTER', 'Process')
if (-not [string]::IsNullOrWhiteSpace($caseFilter) -and $caseFilter -ne 'mcp-function') {
    throw 'unsupported real-provider case filter'
}
$mcpOnly = $caseFilter -eq 'mcp-function'
if ($mcpOnly -and ($models.Count -ne 1 -or $models[0] -ne 'gpt-5.6-sol')) {
    throw 'the mcp-function directed filter requires exactly gpt-5.6-sol'
}

$codexBinary = Resolve-CodexBinary
$nodeBinary = Resolve-NodeBinary
if (-not (Test-Path -LiteralPath $script:CompatTool -PathType Leaf)) { throw 'compatibility script is missing' }
if (-not (Test-Path -LiteralPath $script:McpFixture -PathType Leaf)) { throw 'MCP fixture is missing' }

$version = Invoke-IsolatedProcess $codexBinary @('--version') @{} 15000
if ($version.TimedOut -or $version.ExitCode -ne 0 -or $version.Stdout.Trim() -ne "codex-cli $($script:ExpectedCodexVersion)") {
    throw "real-provider harness requires codex-cli $($script:ExpectedCodexVersion)"
}

$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$runId = [guid]::NewGuid().ToString('N')
$tempRoot = Join-Path $tempBase "codex-provider-compat-real-$runId"
$codexHome = Join-Path $tempRoot 'codex-home'
$workDir = Join-Path $tempRoot 'workspace'
$summaryBaseValue = [Environment]::GetEnvironmentVariable('CODEX_PROVIDER_COMPAT_REAL_SUMMARY_DIR', 'Process')
$summaryBase = if ([string]::IsNullOrWhiteSpace($summaryBaseValue)) {
    Join-Path $tempBase 'codex-provider-compat-real-summaries'
} else { [IO.Path]::GetFullPath($summaryBaseValue) }
$summaryPath = Join-Path $summaryBase "summary-$runId.json"
$results = [Collections.Generic.List[object]]::new()
foreach ($model in $models) {
    Add-NotRunResult $results 'function-dynamic-tool' $model 'client-auth-isolation' 'Codex 0.144.1 app-server exposes dynamicTools and item/tool/call, but disables CODEX_API_KEY environment authentication; this harness will not create a temporary credential file or weaken credential isolation.'
    Add-NotRunResult $results 'image-detail-original' $model 'client-auth-isolation' 'Codex 0.144.1 app-server exposes localImage detail=original, but disables CODEX_API_KEY environment authentication; this harness will not create a temporary credential file or weaken credential isolation.'
    Add-NotRunResult $results 'image-generation' $model 'no-deterministic-hosted-fixture' 'No deterministic, client-observable hosted image-generation acceptance path is implemented in this maintenance harness.'
}
$startedAt = [DateTimeOffset]::UtcNow
$fatal = $null
$applySucceeded = $false
$rollbackStatus = 'not-run'
$cleanupStatus = 'not-run'

try {
    [IO.Directory]::CreateDirectory($codexHome) | Out-Null
    [IO.Directory]::CreateDirectory($workDir) | Out-Null
    Write-MinimalConfig (Join-Path $codexHome 'config.toml') $baseUrl $catalogPath $models[0] $nodeBinary

    if (-not $mcpOnly) {
      foreach ($model in $models) {
        $marker = 'BASE_' + [guid]::NewGuid().ToString('N')
        $run = Invoke-CodexTurn $codexBinary $codexHome $workDir $model "Return exactly $marker and do not call any tool." $apiKey $null $null
        $status = if ($run.Process.ExitCode -eq 0 -and (Test-TraceEquals $run.Trace $marker)) { 'passed' } else { Get-PublicStatus 'failed' $run }
        $baselineDiagnostic = if($status -eq 'passed'){''}else{'unpatched Lite text baseline did not complete exactly'}
        Add-Result $results ([ordered]@{
            case='baseline-lite-text';model=$model;status=$status;attempts=1;duration_ms=$run.Process.DurationMs
            exit_code=$run.Process.ExitCode;timed_out=$run.Process.TimedOut;item_types=@($run.Trace.ItemTypes)
            tool_names=@($run.Trace.ToolNames);usage=$run.Trace.Usage
            reason=Get-PublicReason $status $run $baselineDiagnostic
            diagnostic=$baselineDiagnostic
        })
    }
    $baselineToolMarker = 'BASE_TOOL_' + [guid]::NewGuid().ToString('N')
    $baselineToolPath = Join-Path $workDir 'baseline-sol-tool.txt'
    [IO.File]::WriteAllText($baselineToolPath, $baselineToolMarker, [Text.UTF8Encoding]::new($false))
    $baselineTool = Invoke-CodexTurn $codexBinary $codexHome $workDir 'gpt-5.6-sol' "Use the terminal tool to read $baselineToolPath and return exactly its contents." $apiKey $null $null
    $baselineUsedCommand = @($baselineTool.Trace.ItemTypes | Where-Object { $_ -eq 'command_execution' }).Count -gt 0
    $baselineToolStatus = if ($baselineTool.Process.ExitCode -eq 0 -and $baselineUsedCommand -and (Test-TraceEquals $baselineTool.Trace $baselineToolMarker)) {
        'passed'
    } elseif ((Get-PublicStatus 'failed' $baselineTool) -eq 'not-supported') { 'not-supported' } else { 'not-run' }
    $baselineToolDiagnostic = if($baselineToolStatus -eq 'passed'){''}else{'observational Lite baseline did not demonstrate a completed shell tool call'}
      Add-Result $results ([ordered]@{
        case='baseline-lite-sol-tool';model='gpt-5.6-sol';status=$baselineToolStatus;attempts=1
        duration_ms=$baselineTool.Process.DurationMs;exit_code=$baselineTool.Process.ExitCode;timed_out=$baselineTool.Process.TimedOut
        item_types=@($baselineTool.Trace.ItemTypes);tool_names=@($baselineTool.Trace.ToolNames);usage=$baselineTool.Trace.Usage
        reason=Get-PublicReason $baselineToolStatus $baselineTool $baselineToolDiagnostic
        diagnostic=$baselineToolDiagnostic
      })
    }

    $apply = Invoke-CompatTool $codexHome @(
        'apply', '--yes', '--codex-home', $codexHome, '--codex-version', $script:ExpectedCodexVersion,
        '--catalog-file', $catalogPath
    )
    if ($apply.TimedOut -or $apply.ExitCode -ne 0) {
        throw ('temporary apply failed: ' + (Redact-Text ($apply.Stdout + "`n" + $apply.Stderr) $apiKey $baseUrl))
    }
    $applySucceeded = $true

    if ($mcpOnly) {
        Invoke-McpAcceptance $results $codexBinary $codexHome $workDir 'gpt-5.6-sol' $apiKey $baseUrl
    } else {
      foreach ($model in $models) {
        $textMarker = 'TEXT_' + [guid]::NewGuid().ToString('N')
        $null = Invoke-RetryCase $results 'text' $model {
            Invoke-CodexTurn $codexBinary $codexHome $workDir $model "Return exactly $textMarker and do not call any tool." $apiKey $null $null
        } {
            param($run)
            if ($run.Process.TimedOut) { return [pscustomobject]@{Status='failed';Diagnostic='turn timed out'} }
            if ($run.Process.ExitCode -eq 0 -and (Test-TraceEquals $run.Trace $textMarker)) { return [pscustomobject]@{Status='passed';Diagnostic=''} }
            return [pscustomobject]@{Status='failed';Diagnostic=($run.Process.Stderr + "`n" + $run.Trace.FinalMessage)}
        } $apiKey $baseUrl

        $shellMarker = 'SHELL_' + [guid]::NewGuid().ToString('N')
        $shellPath = Join-Path $workDir "shell-$($model.Replace('.', '_')).txt"
        [IO.File]::WriteAllText($shellPath, $shellMarker, [Text.UTF8Encoding]::new($false))
        $null = Invoke-RetryCase $results 'shell' $model {
            Invoke-CodexTurn $codexBinary $codexHome $workDir $model "You must use the terminal/shell tool to read this file and then return exactly its contents: $shellPath" $apiKey $null $null
        } {
            param($run)
            $usedCommand = @($run.Trace.ItemTypes | Where-Object { $_ -eq 'command_execution' }).Count -gt 0
            if ($run.Process.ExitCode -eq 0 -and $usedCommand -and (Test-TraceEquals $run.Trace $shellMarker)) { return [pscustomobject]@{Status='passed';Diagnostic=''} }
            return [pscustomobject]@{Status='failed';Diagnostic='expected successful command_execution plus marker'}
        } $apiKey $baseUrl

        $codeMarker = 'CODE_' + [guid]::NewGuid().ToString('N')
        $codePath = Join-Path $workDir "code-$($model.Replace('.', '_')).txt"
        [IO.File]::WriteAllText($codePath, $codeMarker, [Text.UTF8Encoding]::new($false))
        $null = Invoke-RetryCase $results 'code-mode' $model {
            Invoke-CodexTurn $codexBinary $codexHome $workDir $model "Use the code-mode JavaScript exec orchestration tool, not a direct terminal call, to invoke shell_command, read $codePath, and return exactly the file contents." $apiKey $null $null
        } {
            param($run)
            $sawExec = @($run.Trace.ToolNames | Where-Object { $_ -eq 'exec' }).Count -gt 0
            if ($run.Process.ExitCode -eq 0 -and $sawExec -and (Test-TraceEquals $run.Trace $codeMarker)) { return [pscustomobject]@{Status='passed';Diagnostic=''} }
            if ($run.Process.ExitCode -eq 0 -and (Test-TraceEquals $run.Trace $codeMarker)) { return [pscustomobject]@{Status='not-run';Diagnostic='marker returned, but codex exec JSONL did not expose an observable exec tool item; app-server/raw-event validation is still needed'} }
            return [pscustomobject]@{Status='failed';Diagnostic='code-mode marker was not returned'}
        } $apiKey $baseUrl

        Invoke-McpAcceptance $results $codexBinary $codexHome $workDir $model $apiKey $baseUrl

        $imageMarker = 'IMG' + [guid]::NewGuid().ToString('N').Substring(0, 12).ToUpperInvariant()
        $imagePath = Join-Path $workDir "image-$($model.Replace('.', '_')).png"
        New-TestImage $imagePath $imageMarker
        $null = Invoke-RetryCase $results 'image-input-auto-detail' $model {
            Invoke-CodexTurn $codexBinary $codexHome $workDir $model 'Read the exact black identifier in the attached image and return only that identifier.' $apiKey $imagePath $null
        } {
            param($run)
            if ($run.Process.ExitCode -eq 0 -and (Test-TraceEquals $run.Trace $imageMarker)) { return [pscustomobject]@{Status='passed';Diagnostic=''} }
            return [pscustomobject]@{Status='failed';Diagnostic='image marker was not returned; explicit image detail is not covered by this CLI-only harness'}
        } $apiKey $baseUrl

        $multiMarker = 'MULTI_' + [guid]::NewGuid().ToString('N')
        $first = Invoke-CodexTurn $codexBinary $codexHome $workDir $model "Remember this nonce for the next turn: $multiMarker. Reply exactly ACK." $apiKey $null $null
        $second = $null
        $status = 'failed'
        $diagnostic = 'first turn did not yield a resumable thread'
        if ($first.Process.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($first.Trace.ThreadId)) {
            $second = Invoke-CodexTurn $codexBinary $codexHome $workDir $model 'Return exactly the nonce I asked you to remember in the previous turn.' $apiKey $null $first.Trace.ThreadId
            if ($second.Process.ExitCode -eq 0 -and (Test-TraceEquals $second.Trace $multiMarker)) {
                $status = 'passed'; $diagnostic = ''
            } else { $diagnostic = 'resumed turn did not return the prior nonce' }
        }
        $lastRun = if ($second) { $second } else { $first }
        $safeMultiDiagnostic = Redact-Text $diagnostic $apiKey $baseUrl
        Add-Result $results ([ordered]@{
            case = 'multi-turn-resume'
            model = $model
            status = $status
            attempts = 1
            duration_ms = [long]$first.Process.DurationMs + $(if ($second) { [long]$second.Process.DurationMs } else { 0 })
            exit_code = $lastRun.Process.ExitCode
            timed_out = [bool]$first.Process.TimedOut -or $(if ($second) { [bool]$second.Process.TimedOut } else { $false })
            item_types = @($lastRun.Trace.ItemTypes)
            tool_names = @($lastRun.Trace.ToolNames)
            usage = $lastRun.Trace.Usage
            reason = Get-PublicReason $status $lastRun $safeMultiDiagnostic
            diagnostic = $safeMultiDiagnostic
        })
    }

    foreach ($model in $models) {
        $collaborationMarker = 'AGENT_' + [guid]::NewGuid().ToString('N')
        $collaboration = Invoke-CodexTurn $codexBinary $codexHome $workDir $model "Use collaboration spawn_agent exactly once. Ask the child to return $collaborationMarker without tools, wait for it, then return exactly $collaborationMarker." $apiKey $null $null
        $sawCollaboration = @($collaboration.Trace.ToolNames | Where-Object { $_ -eq 'spawn_agent' }).Count -gt 0 -or
            @($collaboration.Trace.ItemTypes | Where-Object { $_ -match '(?i)(collaboration|agent)' }).Count -gt 0
        $collaborationStatus = if ($collaboration.Process.ExitCode -eq 0 -and $sawCollaboration -and (Test-TraceEquals $collaboration.Trace $collaborationMarker)) {
            'passed'
        } elseif ((Get-PublicStatus 'failed' $collaboration) -eq 'not-supported') { 'not-supported' } else { 'not-run' }
        $collaborationDiagnostic = if($collaborationStatus -eq 'passed'){''}else{'single spawn_agent execution was not observably demonstrated'}
        Add-Result $results ([ordered]@{
            case='collaboration-single-spawn';model=$model;status=$collaborationStatus;attempts=1
            duration_ms=$collaboration.Process.DurationMs;exit_code=$collaboration.Process.ExitCode;timed_out=$collaboration.Process.TimedOut
            item_types=@($collaboration.Trace.ItemTypes);tool_names=@($collaboration.Trace.ToolNames);usage=$collaboration.Trace.Usage
            reason=Get-PublicReason $collaborationStatus $collaboration $collaborationDiagnostic
            diagnostic=$collaborationDiagnostic
        })
    }

    $webMarker = 'WEB_' + [guid]::NewGuid().ToString('N')
    $web = Invoke-CodexTurn $codexBinary $codexHome $workDir 'gpt-5.6-sol' "Use native Web Search exactly once to verify the current UTC date, then return exactly $webMarker." $apiKey $null $null $true
    $sawWeb = @($web.Trace.ItemTypes | Where-Object { $_ -match '(?i)web_search' }).Count -gt 0 -or
        @($web.Trace.ToolNames | Where-Object { $_ -match '(?i)web_search' }).Count -gt 0
    $webStatus = if ($web.Process.ExitCode -eq 0 -and $sawWeb -and (Test-TraceEquals $web.Trace $webMarker)) {
        'passed'
    } elseif ((Get-PublicStatus 'failed' $web) -eq 'not-supported') { 'not-supported' } else { 'not-run' }
    $webDiagnostic = if($webStatus -eq 'passed'){''}else{'command-level Web Search probe was not observably completed; the compatibility script did not enable it'}
    Add-Result $results ([ordered]@{
        case='web-search-command-config';model='gpt-5.6-sol';status=$webStatus;attempts=1
        duration_ms=$web.Process.DurationMs;exit_code=$web.Process.ExitCode;timed_out=$web.Process.TimedOut
        item_types=@($web.Trace.ItemTypes);tool_names=@($web.Trace.ToolNames);usage=$web.Trace.Usage
        reason=Get-PublicReason $webStatus $web $webDiagnostic
        diagnostic=$webDiagnostic
    })
    }
} catch {
    $fatal = Redact-Text $_.Exception.Message $apiKey $baseUrl
} finally {
    if ($applySucceeded -or (Test-Path -LiteralPath (Join-Path $codexHome 'provider-compat-state.json') -PathType Leaf)) {
        try {
            $rollback = Invoke-CompatTool $codexHome @('rollback', '--yes', '--codex-home', $codexHome)
            $rollbackStatus = if (-not $rollback.TimedOut -and $rollback.ExitCode -eq 0) { 'passed' } else { 'failed' }
            if ($rollbackStatus -eq 'failed' -and -not $fatal) {
                $fatal = Redact-Text ('temporary rollback failed: ' + $rollback.Stdout + "`n" + $rollback.Stderr) $apiKey $baseUrl
            }
        } catch {
            $rollbackStatus = 'failed'
            if (-not $fatal) { $fatal = Redact-Text $_.Exception.Message $apiKey $baseUrl }
        }
    }
    try {
        $resolvedTemp = [IO.Path]::GetFullPath($tempRoot)
        if (-not $resolvedTemp.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase) -or
            [IO.Path]::GetFileName($resolvedTemp) -notlike 'codex-provider-compat-real-*') {
            throw 'refusing to clean an unexpected real-provider temp path'
        }
        if (Test-Path -LiteralPath $resolvedTemp) { Remove-Item -LiteralPath $resolvedTemp -Recurse -Force }
        $cleanupStatus = 'passed'
    } catch {
        $cleanupStatus = 'failed'
        if (-not $fatal) { $fatal = Redact-Text $_.Exception.Message $apiKey $baseUrl }
    }

    $summary = [ordered]@{
        schema_version = 1
        run_id = $runId
        started_at = $startedAt.ToString('o')
        finished_at = [DateTimeOffset]::UtcNow.ToString('o')
        codex_version = $script:ExpectedCodexVersion
        provider_id = 'provider_compat_real'
        models = @($models)
        case_filter = if ($mcpOnly) { 'mcp-function' } else { $null }
        status_enum = @('passed', 'failed', 'not-supported', 'not-run')
        limits = [ordered]@{max_turns=$script:MaxTurns;worst_case_turns=$script:WorstCaseTurnBudget;max_attempts=$script:MaxAttempts;turn_timeout_seconds=120}
        turns_used = $script:TurnCount
        results = @($results)
        rollback = $rollbackStatus
        cleanup = $cleanupStatus
        # A one-off launcher outside this repository may compare the real home
        # before/after and replace these two fields. This harness never opens it.
        real_home_check = 'not-run'
        real_home_unchanged = $null
        fatal = $fatal
    }
    [IO.Directory]::CreateDirectory($summaryBase) | Out-Null
    $summaryText = ($summary | ConvertTo-Json -Depth 20) + "`n"
    $summaryEndpoint = [Uri]$baseUrl
    if ($summaryText.Contains($apiKey, [StringComparison]::Ordinal) -or
        $summaryText.Contains($baseUrl, [StringComparison]::Ordinal) -or
        $summaryText.Contains($summaryEndpoint.Authority, [StringComparison]::OrdinalIgnoreCase) -or
        $summaryText.Contains($summaryEndpoint.Host, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'refusing to write a summary containing credential or endpoint material'
    }
    [IO.File]::WriteAllText($summaryPath, $summaryText, [Text.UTF8Encoding]::new($false))
}

$apiKey = $null
Write-Host "real-provider-summary=$summaryPath"
if ($fatal -or $rollbackStatus -eq 'failed' -or $cleanupStatus -eq 'failed' -or @($results | Where-Object status -eq 'failed').Count) {
    if ($fatal) { Write-Error $fatal } else { Write-Error 'one or more real-provider acceptance cases failed' }
    exit 1
}
exit 0
