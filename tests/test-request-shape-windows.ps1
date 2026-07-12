$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'The request-shape integration test requires PowerShell 7 or later.'
}

$script:ExpectedCodexVersion = '0.144.1'
$script:ExpectedCatalogSha256 = 'DCAB00231A5178A9C84B7AEF4CC06A1E1359E37EE0DD7E69D5822C4B1DE723B1'
$script:CatalogUrl = 'https://raw.githubusercontent.com/openai/codex/rust-v0.144.1/codex-rs/models-manager/models.json'
$script:TargetModels = @('gpt-5.6-sol', 'gpt-5.6-terra', 'gpt-5.6-luna')
$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:ToolPath = Join-Path $script:RepoRoot 'codex-provider-compat.ps1'
$script:PowerShellPath = (Get-Process -Id $PID).Path

function Assert-True($Value, [string]$Message) {
    if (-not $Value) { throw $Message }
}

function Assert-Equal($Expected, $Actual, [string]$Message) {
    if ($Expected -ne $Actual) {
        throw "$Message (expected=[$Expected] actual=[$Actual])"
    }
}

function Test-JsonProperty($Object, [string]$Name) {
    return $null -ne $Object.PSObject.Properties[$Name]
}

function ConvertTo-CanonicalJsonFragment($Value) {
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [string] -or $Value -is [char] -or $Value -is [bool] -or
        $Value -is [byte] -or $Value -is [sbyte] -or $Value -is [int16] -or
        $Value -is [uint16] -or $Value -is [int32] -or $Value -is [uint32] -or
        $Value -is [int64] -or $Value -is [uint64] -or $Value -is [single] -or
        $Value -is [double] -or $Value -is [decimal]) {
        return ($Value | ConvertTo-Json -Compress)
    }
    if ($Value -is [Collections.IDictionary]) {
        $parts = foreach ($key in @($Value.Keys | Sort-Object { [string]$_ })) {
            $name = ([string]$key | ConvertTo-Json -Compress)
            $child = ConvertTo-CanonicalJsonFragment $Value[$key]
            "$name`:$child"
        }
        return '{' + ($parts -join ',') + '}'
    }
    if ($Value -is [Collections.IEnumerable] -and $Value -isnot [string]) {
        $parts = foreach ($item in $Value) { ConvertTo-CanonicalJsonFragment $item }
        return '[' + ($parts -join ',') + ']'
    }
    $properties = @($Value.PSObject.Properties | Where-Object MemberType -eq 'NoteProperty' | Sort-Object Name)
    if ($properties.Count -gt 0) {
        $parts = foreach ($property in $properties) {
            $name = ($property.Name | ConvertTo-Json -Compress)
            $child = ConvertTo-CanonicalJsonFragment $property.Value
            "$name`:$child"
        }
        return '{' + ($parts -join ',') + '}'
    }
    return ($Value | ConvertTo-Json -Compress -Depth 100)
}

function Get-Sha256Bytes([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToUpperInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Get-Sha256File([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '<missing>' }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Get-PathSnapshotValue([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return '<missing>' }
    $item = Get-Item -LiteralPath $Path -Force
    $kind = if ($item.PSIsContainer) { 'directory' } else { 'file' }
    $hash = if ($item.PSIsContainer) { '-' } else { Get-Sha256File $Path }
    $sddl = (Get-Acl -LiteralPath $Path).Sddl
    return "$kind|$hash|$([int]$item.Attributes)|$sddl"
}

function Get-RealHomeSnapshot {
    $realHome = if ([string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
        Join-Path $env:USERPROFILE '.codex'
    } else {
        [IO.Path]::GetFullPath($env:CODEX_HOME)
    }
    $snapshot = [ordered]@{}
    foreach ($name in @('config.toml', 'models_cache.json', 'provider-compat-state.json', 'provider-compat-transaction.json')) {
        $path = Join-Path $realHome $name
        $snapshot[$path] = Get-PathSnapshotValue $path
    }
    foreach ($pattern in @(
        'provider-compat.lock',
        'provider-compat.lock.d',
        'config.toml.bak-provider-compat-*',
        'models_cache.json.bak-provider-compat-*',
        'provider-compat-state.json.rolled-back-*',
        '.provider-compat-rollback-*.config',
        '*.provider-compat-*.tmp'
    )) {
        foreach ($item in @(Get-ChildItem -LiteralPath $realHome -Force -Filter $pattern -ErrorAction SilentlyContinue | Sort-Object FullName)) {
            if ($item.PSIsContainer) {
                $snapshot[$item.FullName] = Get-PathSnapshotValue $item.FullName
                foreach ($child in @(Get-ChildItem -LiteralPath $item.FullName -Force -Recurse -File -ErrorAction SilentlyContinue | Sort-Object FullName)) {
                    $snapshot[$child.FullName] = Get-PathSnapshotValue $child.FullName
                }
            } else {
                $snapshot[$item.FullName] = Get-PathSnapshotValue $item.FullName
            }
        }
    }
    $catalogDir = Join-Path $realHome 'model-catalogs'
    $snapshot[$catalogDir] = Get-PathSnapshotValue $catalogDir
    if (Test-Path -LiteralPath $catalogDir -PathType Container) {
        foreach ($file in @(Get-ChildItem -LiteralPath $catalogDir -File | Sort-Object FullName)) {
            $snapshot[$file.FullName] = Get-PathSnapshotValue $file.FullName
        }
    }
    return ($snapshot | ConvertTo-Json -Compress)
}

function Remove-SafeTestTree([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
    $prefix = $temp + [IO.Path]::DirectorySeparatorChar
    $leaf = [IO.Path]::GetFileName($full)
    if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or
        -not $leaf.StartsWith('codex-provider-compat-shape-', [StringComparison]::Ordinal)) {
        throw "unsafe integration-test cleanup path: $full"
    }
    foreach ($file in @(Get-ChildItem -LiteralPath $full -Recurse -Force -File -ErrorAction SilentlyContinue)) {
        try { $file.Attributes = [IO.FileAttributes]::Normal } catch {}
        [IO.File]::Delete($file.FullName)
    }
    foreach ($directory in @(Get-ChildItem -LiteralPath $full -Recurse -Force -Directory -ErrorAction SilentlyContinue | Sort-Object FullName -Descending)) {
        [IO.Directory]::Delete($directory.FullName, $false)
    }
    [IO.Directory]::Delete($full, $false)
}

function Get-PinnedCatalog([string]$Destination) {
    Add-Type -AssemblyName System.Net.Http
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $client = [Net.Http.HttpClient]::new($handler)
    $client.Timeout = [Threading.Timeout]::InfiniteTimeSpan
    $cts = [Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds(30))
    $response = $null
    $stream = $null
    $memory = $null
    try {
        $response = $client.GetAsync(
            $script:CatalogUrl,
            [Net.Http.HttpCompletionOption]::ResponseHeadersRead,
            $cts.Token
        ).GetAwaiter().GetResult()
        try {
            if ([int]$response.StatusCode -ne 200) {
                throw "pinned catalog download returned HTTP $([int]$response.StatusCode)"
            }
            if ($response.Headers.Location) { throw 'pinned catalog download unexpectedly redirected' }
            if ($response.Content.Headers.ContentLength -and $response.Content.Headers.ContentLength -gt 5MB) {
                throw 'pinned catalog response exceeded the 5 MiB limit'
            }
            $stream = $response.Content.ReadAsStreamAsync($cts.Token).GetAwaiter().GetResult()
            $memory = [IO.MemoryStream]::new()
            $buffer = New-Object byte[] 65536
            while (($read = $stream.ReadAsync($buffer, 0, $buffer.Length, $cts.Token).GetAwaiter().GetResult()) -gt 0) {
                $memory.Write($buffer, 0, $read)
                if ($memory.Length -gt 5MB) { throw 'pinned catalog response exceeded the 5 MiB limit' }
            }
            $bytes = $memory.ToArray()
            if ($null -ne $response.Content.Headers.ContentLength -and
                $bytes.Length -ne [long]$response.Content.Headers.ContentLength) {
                throw 'pinned catalog response was truncated'
            }
        } finally {
            if ($memory) { $memory.Dispose() }
            if ($stream) { $stream.Dispose() }
            $response.Dispose()
        }
    } catch [OperationCanceledException] {
        throw 'pinned catalog download timed out'
    } finally {
        $cts.Dispose()
        $client.Dispose()
        $handler.Dispose()
    }
    Assert-True ($bytes.Length -gt 0 -and $bytes.Length -le 5MB) 'pinned catalog response size is invalid'
    Assert-Equal $script:ExpectedCatalogSha256 (Get-Sha256Bytes $bytes) 'pinned official catalog hash'
    [IO.File]::WriteAllBytes($Destination, $bytes)

    $catalog = [Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json
    Assert-True (Test-JsonProperty $catalog 'models') 'official catalog is missing models'
    $models = @($catalog.models)
    Assert-Equal 8 $models.Count 'official catalog model count'
    $slugs = @($models | ForEach-Object { [string]$_.slug })
    Assert-Equal $slugs.Count @($slugs | Sort-Object -Unique).Count 'official catalog slugs must be unique'
    foreach ($target in $script:TargetModels) {
        $matches = @($models | Where-Object slug -eq $target)
        Assert-Equal 1 $matches.Count "$target count in official catalog"
        Assert-Equal $true $matches[0].use_responses_lite "$target must be Lite in the pinned source catalog"
    }
}

function Resolve-CodexBinary {
    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_BIN)) {
        $explicit = [IO.Path]::GetFullPath($env:CODEX_BIN)
        if (-not (Test-Path -LiteralPath $explicit -PathType Leaf)) { throw "CODEX_BIN does not exist: $explicit" }
        return $explicit
    }
    $npm = Get-Command npm.cmd -CommandType Application -ErrorAction SilentlyContinue
    if ($npm) {
        $npmRoot = (& $npm.Source root -g 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($npmRoot)) {
            $packageRoot = Join-Path $npmRoot '@openai\codex\node_modules'
            $candidates = @(Get-ChildItem -LiteralPath $packageRoot -Recurse -Filter codex.exe -File -ErrorAction SilentlyContinue |
                Where-Object FullName -Match '[\\/]bin[\\/]codex\.exe$')
            if ($candidates.Count -eq 1) { return $candidates[0].FullName }
            if ($candidates.Count -gt 1) { throw "expected exactly one native codex.exe under the npm package; found $($candidates.Count)" }
        }
    }
    $application = Get-Command codex.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($application) { return $application.Source }
    throw 'CODEX_BIN is unset and no native npm Codex binary was found'
}

function Add-ProcessEnvironment($StartInfo, [string]$CodexHome) {
    foreach ($name in @($StartInfo.Environment.Keys)) {
        if ($name -match '(?i)proxy' -or
            $name -match '(?i)^(OPENAI|CODEX|CHATGPT|AZURE_OPENAI)' -or
            $name -match '(?i)^(OTEL|SENTRY|SEGMENT|STATSD|DATADOG|DD_)') {
            [void]$StartInfo.Environment.Remove($name)
        }
    }
    $StartInfo.Environment['CODEX_HOME'] = $CodexHome
    foreach ($name in @($StartInfo.Environment.Keys)) {
        if (($name -match '(?i)proxy' -or $name -match '(?i)^(OPENAI|CHATGPT|AZURE_OPENAI)' -or
            $name -match '(?i)^(OTEL|SENTRY|SEGMENT|STATSD|DATADOG|DD_)' -or
            ($name -match '(?i)^CODEX' -and $name -ne 'CODEX_HOME'))) {
            throw "failed to sanitize child environment variable: $name"
        }
    }
}

function Invoke-IsolatedProcess {
    param(
        [Parameter(Mandatory=$true)][string]$FilePath,
        [Parameter(Mandatory=$true)][string[]]$Arguments,
        [Parameter(Mandatory=$true)][string]$CodexHome,
        [int]$TimeoutSeconds = 60
    )
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FilePath
    $startInfo.WorkingDirectory = $CodexHome
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in $Arguments) { $startInfo.ArgumentList.Add($argument) }
    Add-ProcessEnvironment $startInfo $CodexHome

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        Assert-True $process.Start() "failed to start $FilePath"
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill($true) } catch { try { $process.Kill() } catch {} }
            throw "process timed out after $TimeoutSeconds seconds: $FilePath"
        }
        $process.WaitForExit()
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            Stdout = $stdout.GetAwaiter().GetResult()
            Stderr = $stderr.GetAwaiter().GetResult()
        }
    } finally {
        $process.Dispose()
    }
}

function Format-ProcessResult($Result) {
    $text = "exit=$($Result.ExitCode)`nstdout:`n$($Result.Stdout)`nstderr:`n$($Result.Stderr)"
    if ($text.Length -gt 8000) { return $text.Substring(0, 8000) + "`n<truncated>" }
    return $text
}

function Invoke-CompatTool([string]$CodexHome, [string[]]$Arguments) {
    $allArguments = @('-NoLogo', '-NoProfile', '-File', $script:ToolPath) + $Arguments
    return Invoke-IsolatedProcess -FilePath $script:PowerShellPath -Arguments $allArguments -CodexHome $CodexHome
}

$script:MockServerScript = {
    param([string]$ReadyPath, [string]$StopPath, [string]$CapturePath)
    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version Latest
    $records = @()
    $fatal = $null
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)

    function Find-HeaderEnd([byte[]]$Bytes) {
        for ($i = 0; $i -le $Bytes.Length - 4; $i++) {
            if ($Bytes[$i] -eq 13 -and $Bytes[$i + 1] -eq 10 -and
                $Bytes[$i + 2] -eq 13 -and $Bytes[$i + 3] -eq 10) { return $i + 4 }
        }
        return -1
    }

    function Write-HttpResponse($Stream, [int]$Status, [string]$ContentType, [byte[]]$Body) {
        $reason = if ($Status -eq 200) { 'OK' } else { 'Not Found' }
        $header = "HTTP/1.1 $Status $reason`r`nContent-Type: $ContentType`r`nContent-Length: $($Body.Length)`r`nConnection: close`r`n`r`n"
        $headerBytes = [Text.Encoding]::ASCII.GetBytes($header)
        $Stream.Write($headerBytes, 0, $headerBytes.Length)
        if ($Body.Length -gt 0) { $Stream.Write($Body, 0, $Body.Length) }
        $Stream.Flush()
    }

    function Get-SseBody {
        $id = 'resp-provider-compat-shape'
        $body = @(
            'event: response.created'
            "data: {`"type`":`"response.created`",`"response`":{`"id`":`"$id`"}}"
            ''
            'event: response.output_item.done'
            'data: {"type":"response.output_item.done","item":{"type":"message","role":"assistant","id":"msg-provider-compat-shape","content":[{"type":"output_text","text":"shape-test-complete"}]}}'
            ''
            'event: response.completed'
            "data: {`"type`":`"response.completed`",`"response`":{`"id`":`"$id`",`"usage`":{`"input_tokens`":0,`"input_tokens_details`":null,`"output_tokens`":0,`"output_tokens_details`":null,`"total_tokens`":0}}}"
            ''
            ''
        ) -join "`n"
        return [Text.Encoding]::UTF8.GetBytes($body)
    }

    try {
        $listener.Start()
        $port = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
        [IO.File]::WriteAllText($ReadyPath, [string]$port, [Text.Encoding]::ASCII)
        $stopObservedAt = $null
        while ($true) {
            if (Test-Path -LiteralPath $StopPath) {
                if (-not $stopObservedAt) { $stopObservedAt = [DateTime]::UtcNow }
                if (-not $listener.Pending() -and ([DateTime]::UtcNow - $stopObservedAt).TotalMilliseconds -ge 300) { break }
            }
            if (-not $listener.Pending()) { Start-Sleep -Milliseconds 25; continue }

            $client = $listener.AcceptTcpClient()
            try {
                $client.ReceiveTimeout = 10000
                $client.SendTimeout = 10000
                $stream = $client.GetStream()
                $buffer = New-Object byte[] 8192
                $memory = [IO.MemoryStream]::new()
                $headerEnd = -1
                while ($headerEnd -lt 0) {
                    $read = $stream.Read($buffer, 0, $buffer.Length)
                    if ($read -le 0) { throw 'connection closed before HTTP headers completed' }
                    $memory.Write($buffer, 0, $read)
                    if ($memory.Length -gt 64KB) { throw 'HTTP request headers exceeded 64 KiB' }
                    $headerEnd = Find-HeaderEnd $memory.ToArray()
                }
                $allBytes = $memory.ToArray()
                $headerText = [Text.Encoding]::ASCII.GetString($allBytes, 0, $headerEnd)
                $lines = @($headerText -split "`r`n")
                $requestParts = @($lines[0] -split ' ')
                if ($requestParts.Count -ne 3) { throw "invalid request line: $($lines[0])" }
                $method = $requestParts[0]
                $target = $requestParts[1]
                $headers = [ordered]@{}
                for ($i = 1; $i -lt $lines.Count; $i++) {
                    if (-not $lines[$i].Contains(':')) { continue }
                    $pair = $lines[$i].Split(':', 2)
                    $headers[$pair[0].Trim().ToLowerInvariant()] = $pair[1].Trim()
                }
                if ($headers.Contains('expect') -and $headers['expect'] -eq '100-continue') {
                    $continue = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 100 Continue`r`n`r`n")
                    $stream.Write($continue, 0, $continue.Length)
                    $stream.Flush()
                }
                if ($headers.Contains('transfer-encoding')) { throw 'chunked request bodies are not accepted by this fixed test server' }
                $contentLength = 0
                if ($headers.Contains('content-length') -and -not [int]::TryParse($headers['content-length'], [ref]$contentLength)) {
                    throw 'invalid Content-Length'
                }
                if ($contentLength -lt 0 -or $contentLength -gt 2MB) { throw 'HTTP request body exceeded 2 MiB' }
                $bodyBytes = New-Object byte[] $contentLength
                $available = [Math]::Min($contentLength, $allBytes.Length - $headerEnd)
                if ($available -gt 0) { [Array]::Copy($allBytes, $headerEnd, $bodyBytes, 0, $available) }
                $offset = $available
                while ($offset -lt $contentLength) {
                    $read = $stream.Read($bodyBytes, $offset, $contentLength - $offset)
                    if ($read -le 0) { throw 'connection closed before HTTP body completed' }
                    $offset += $read
                }

                $targetUri = [Uri]::new('http://127.0.0.1' + $target)
                $path = $targetUri.AbsolutePath
                $isResponses = $method -eq 'POST' -and $target -eq '/v1/responses'
                $records += [pscustomobject]@{
                    method = $method
                    path = $path
                    has_query = -not [string]::IsNullOrEmpty($targetUri.Query)
                    host = if ($headers.Contains('host')) { $headers['host'] } else { $null }
                    has_authorization = $headers.Contains('authorization')
                    has_proxy_authorization = $headers.Contains('proxy-authorization')
                    responses_lite_header = if ($headers.Contains('x-openai-internal-codex-responses-lite')) { $headers['x-openai-internal-codex-responses-lite'] } else { $null }
                    body = if ($isResponses) { [Text.Encoding]::UTF8.GetString($bodyBytes) } else { $null }
                }
                if ($isResponses) {
                    Write-HttpResponse $stream 200 'text/event-stream' (Get-SseBody)
                } else {
                    Write-HttpResponse $stream 404 'text/plain' ([Text.Encoding]::UTF8.GetBytes('localhost test endpoint rejected this path'))
                }
            } finally {
                $client.Dispose()
            }
        }
    } catch {
        $fatal = $_.Exception.ToString()
    } finally {
        try { $listener.Stop() } catch {}
        $capture = [ordered]@{ fatal = $fatal; records = @($records) }
        [IO.File]::WriteAllText($CapturePath, ($capture | ConvertTo-Json -Depth 20), [Text.Encoding]::UTF8)
    }
}

function Start-LocalMock([string]$Root, [string]$Name) {
    $ready = Join-Path $Root "$Name-ready.txt"
    $stop = Join-Path $Root "$Name-stop.txt"
    $capture = Join-Path $Root "$Name-capture.json"
    $job = Start-Job -ScriptBlock $script:MockServerScript -ArgumentList $ready, $stop, $capture
    for ($i = 0; $i -lt 200 -and -not (Test-Path -LiteralPath $ready); $i++) {
        if ($job.State -in @('Failed', 'Stopped', 'Completed')) { break }
        Start-Sleep -Milliseconds 50
    }
    if (-not (Test-Path -LiteralPath $ready)) {
        $details = Receive-Job -Job $job -ErrorAction SilentlyContinue | Out-String
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        throw "localhost mock failed to start: $details"
    }
    $port = 0
    if (-not [int]::TryParse((Get-Content -LiteralPath $ready -Raw).Trim(), [ref]$port) -or $port -le 0) {
        throw 'localhost mock wrote an invalid port'
    }
    return [pscustomobject]@{ Job=$job; Ready=$ready; Stop=$stop; Capture=$capture; Port=$port }
}

function Stop-LocalMock($Server, [bool]$ReadCapture) {
    if (-not $Server) { return $null }
    if (-not (Test-Path -LiteralPath $Server.Stop)) { [IO.File]::WriteAllText($Server.Stop, 'stop') }
    $null = Wait-Job -Job $Server.Job -Timeout 15
    if ($Server.Job.State -notin @('Completed', 'Failed', 'Stopped')) {
        Stop-Job -Job $Server.Job -ErrorAction SilentlyContinue
        $null = Wait-Job -Job $Server.Job -Timeout 5
    }
    $jobOutput = Receive-Job -Job $Server.Job -ErrorAction SilentlyContinue | Out-String
    $state = $Server.Job.State
    Remove-Job -Job $Server.Job -Force -ErrorAction SilentlyContinue
    if (-not $ReadCapture) { return $null }
    if (-not (Test-Path -LiteralPath $Server.Capture -PathType Leaf)) {
        throw "localhost mock did not write a capture (job state=$state output=$jobOutput)"
    }
    $capture = Get-Content -LiteralPath $Server.Capture -Raw | ConvertFrom-Json
    if (-not [string]::IsNullOrWhiteSpace([string]$capture.fatal)) { throw "localhost mock failed: $($capture.fatal)" }
    return $capture
}

function New-TestConfig([int]$Port) {
    return @"
model = "gpt-5.6-sol"
model_provider = "mock"
web_search = "live"
check_for_update_on_startup = false
openai_base_url = "http://127.0.0.1:$Port/v1"
chatgpt_base_url = "http://127.0.0.1:$Port"
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
standalone_web_search = false

[model_providers.mock]
name = "provider-compat-localhost-test"
base_url = "http://127.0.0.1:$Port/v1"
wire_api = "responses"
requires_openai_auth = false
request_max_retries = 0
stream_max_retries = 0
stream_idle_timeout_ms = 10000
"@
}

function Invoke-CodexTurn([string]$CodexBinary, [string]$CodexHome) {
    $arguments = @(
        'exec', '--skip-git-repo-check', '--ephemeral', '--ignore-rules',
        '-C', $CodexHome, 'shape-test'
    )
    $result = Invoke-IsolatedProcess -FilePath $CodexBinary -Arguments $arguments -CodexHome $CodexHome -TimeoutSeconds 45
    Assert-Equal 0 $result.ExitCode (Format-ProcessResult $result)
    Assert-True $result.Stdout.Contains('shape-test-complete') "Codex did not consume the mock completion: $(Format-ProcessResult $result)"
    $outsideUrl = [regex]::Match(($result.Stdout + "`n" + $result.Stderr), '(?i)https?://(?!127\.0\.0\.1(?::\d+)?(?:/|\b))\S+')
    Assert-True (-not $outsideUrl.Success) "Codex reported a non-local network target: $($outsideUrl.Value)"
    return $result
}

function Get-SingleResponseRecord($Capture, [int]$Port) {
    $records = @($Capture.records)
    Assert-Equal 1 $records.Count 'Codex must make exactly one HTTP request'
    $record = $records[0]
    Assert-Equal 'POST' $record.method 'request method'
    Assert-Equal '/v1/responses' $record.path 'only /v1/responses is allowed'
    Assert-Equal $false $record.has_query 'Responses request must not contain query parameters'
    Assert-Equal "127.0.0.1:$Port" $record.host 'request host must be the local listener'
    Assert-Equal $false $record.has_authorization 'test request must not carry an Authorization header'
    Assert-Equal $false $record.has_proxy_authorization 'test request must not carry proxy credentials'
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$record.body)) 'Responses request body is empty'
    return $record
}

function Assert-LiteShape($Record) {
    Assert-Equal 'true' $Record.responses_lite_header 'Lite request header'
    $body = $Record.body | ConvertFrom-Json
    Assert-Equal 'gpt-5.6-sol' $body.model 'Lite request model'
    Assert-True (-not (Test-JsonProperty $body 'tools')) 'Lite request must omit top-level tools'
    Assert-True (-not (Test-JsonProperty $body 'instructions')) 'Lite request must omit top-level instructions'
    Assert-Equal $false $body.parallel_tool_calls 'Lite request parallel_tool_calls'
    Assert-True (Test-JsonProperty $body.reasoning 'context') 'Lite request must include reasoning.context'
    Assert-Equal 'all_turns' $body.reasoning.context 'Lite request reasoning context'
    $input = @($body.input)
    Assert-True ($input.Count -gt 0) 'Lite request input is empty'
    Assert-Equal 'additional_tools' $input[0].type 'Lite request first input item'
    $tools = @($input[0].tools)
    Assert-True ($tools.Count -gt 0) 'Lite additional_tools is empty'
    Assert-Equal 0 @($tools | Where-Object type -eq 'web_search').Count 'Lite request must omit hosted web_search'
    Assert-Equal 0 @($tools | Where-Object { $_.type -eq 'namespace' -and $_.name -eq 'web' }).Count 'custom provider must not receive web/run'
    return [pscustomobject]@{ Body=$body; Tools=$tools }
}

function Assert-StandardShape($Record, $LiteTools) {
    Assert-True ([string]::IsNullOrWhiteSpace([string]$Record.responses_lite_header)) 'standard request must omit the Lite header'
    $body = $Record.body | ConvertFrom-Json
    Assert-Equal 'gpt-5.6-sol' $body.model 'standard request model'
    Assert-True (Test-JsonProperty $body 'tools') 'standard request must include top-level tools'
    Assert-True (Test-JsonProperty $body 'instructions') 'standard request must include top-level instructions'
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$body.instructions)) 'standard instructions must be non-empty'
    Assert-Equal $true $body.parallel_tool_calls 'standard request parallel_tool_calls'
    Assert-True (-not (Test-JsonProperty $body.reasoning 'context')) 'standard reasoning must omit Lite all_turns context'
    Assert-Equal 0 @($body.input | Where-Object type -eq 'additional_tools').Count 'standard input must omit additional_tools'

    $tools = @($body.tools)
    Assert-True ($tools.Count -gt 0) 'standard top-level tools is empty'
    $hostedWeb = @($tools | Where-Object type -eq 'web_search')
    Assert-Equal 1 $hostedWeb.Count 'standard request must include exactly one hosted web_search'
    Assert-True (@($tools | Where-Object { (Test-JsonProperty $_ 'name') -and $_.name -in @('exec', 'shell') }).Count -gt 0) 'standard request must include exec/shell capability'
    Assert-Equal 1 @($tools | Where-Object { $_.type -eq 'custom' -and $_.name -eq 'exec' -and $_.description -like '*orchestrate/compose tool calls*' }).Count 'standard request must include the code-mode exec orchestrator'
    Assert-True (@($tools | Where-Object type -eq 'function').Count -gt 0) 'standard request must include ordinary function tools'
    Assert-Equal 1 @($tools | Where-Object { $_.type -eq 'namespace' -and $_.name -eq 'collaboration' }).Count 'standard request must include collaboration namespace'

    $clientTools = @($tools | Where-Object type -ne 'web_search')
    Assert-Equal $LiteTools.Count $clientTools.Count 'hosted web_search must be the only added standard tool'
    $liteCanonical = @($LiteTools | ForEach-Object { ConvertTo-CanonicalJsonFragment $_ } | Sort-Object)
    $standardCanonical = @($clientTools | ForEach-Object { ConvertTo-CanonicalJsonFragment $_ } | Sort-Object)
    Assert-Equal ($liteCanonical -join "`n") ($standardCanonical -join "`n") 'Lite and standard client-tool definitions differ'
    return $body
}

$realHomeBefore = Get-RealHomeSnapshot
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-provider-compat-shape-' + [guid]::NewGuid().ToString('N'))
$codexHome = Join-Path $testRoot 'home'
$server1 = $null
$server2 = $null
$failure = $null

try {
    [IO.Directory]::CreateDirectory($codexHome) | Out-Null
    $officialCatalog = Join-Path $testRoot 'models-0.144.1.official.json'
    Get-PinnedCatalog $officialCatalog
    Write-Host 'PASS pinned official 0.144.1 catalog and SHA-256'

    $codexBinary = Resolve-CodexBinary
    $versionResult = Invoke-IsolatedProcess -FilePath $codexBinary -Arguments @('--version') -CodexHome $codexHome -TimeoutSeconds 15
    Assert-Equal 0 $versionResult.ExitCode (Format-ProcessResult $versionResult)
    Assert-Equal "codex-cli $($script:ExpectedCodexVersion)" $versionResult.Stdout.Trim() 'native Codex version'
    Write-Host "PASS fixed Codex CLI $($script:ExpectedCodexVersion)"

    $server1 = Start-LocalMock $testRoot 'lite'
    [IO.File]::WriteAllText((Join-Path $codexHome 'config.toml'), (New-TestConfig $server1.Port), [Text.UTF8Encoding]::new($false))
    $null = Invoke-CodexTurn $codexBinary $codexHome
    $capture1 = Stop-LocalMock $server1 $true
    $record1 = Get-SingleResponseRecord $capture1 $server1.Port
    $lite = Assert-LiteShape $record1
    $server1 = $null
    Write-Host 'PASS unpatched Responses Lite request shape'

    $server2 = Start-LocalMock $testRoot 'standard'
    $configPath = Join-Path $codexHome 'config.toml'
    [IO.File]::WriteAllText($configPath, (New-TestConfig $server2.Port), [Text.UTF8Encoding]::new($false))
    $configBeforeApply = [IO.File]::ReadAllBytes($configPath)
    $configHashBeforeApply = Get-Sha256Bytes $configBeforeApply
    $cachePath = Join-Path $codexHome 'models_cache.json'
    [IO.File]::WriteAllText($cachePath, 'request-shape-cache-before-apply', [Text.UTF8Encoding]::new($false))
    $cacheHashBeforeApply = Get-Sha256File $cachePath

    $apply = Invoke-CompatTool $codexHome @(
        'apply', '--yes', '--codex-home', $codexHome, '--codex-version', $script:ExpectedCodexVersion,
        '--catalog-file', $officialCatalog, '--enable-web-search'
    )
    Assert-Equal 0 $apply.ExitCode (Format-ProcessResult $apply)
    Assert-True $apply.Stdout.Contains('result=applied') (Format-ProcessResult $apply)
    $statePath = Join-Path $codexHome 'provider-compat-state.json'
    Assert-True (Test-Path -LiteralPath $statePath -PathType Leaf) 'apply did not create state'
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    Assert-Equal 'responses-lite-standard-tools' $state.patch_id 'state patch_id'
    Assert-Equal $script:ExpectedCodexVersion $state.codex_version 'state Codex version'
    Assert-Equal $script:ExpectedCatalogSha256 ([string]$state.source_catalog.sha256).ToUpperInvariant() 'state source catalog hash'
    Assert-True (Test-Path -LiteralPath $state.generated_catalog.path -PathType Leaf) 'generated catalog is missing'
    Write-Host 'PASS apply with the complete official catalog'

    $status = Invoke-CompatTool $codexHome @('status', '--codex-home', $codexHome, '--codex-version', $script:ExpectedCodexVersion)
    Assert-Equal 0 $status.ExitCode (Format-ProcessResult $status)
    Assert-True $status.Stdout.Contains('result=healthy') (Format-ProcessResult $status)
    Write-Host 'PASS status after apply'

    $null = Invoke-CodexTurn $codexBinary $codexHome
    $capture2 = Stop-LocalMock $server2 $true
    $record2 = Get-SingleResponseRecord $capture2 $server2.Port
    $null = Assert-StandardShape $record2 $lite.Tools
    $server2 = $null
    Write-Host 'PASS patched standard Responses request shape and normalized tool set'

    $generatedCatalog = [string]$state.generated_catalog.path
    $rollback = Invoke-CompatTool $codexHome @('rollback', '--yes', '--codex-home', $codexHome)
    Assert-Equal 0 $rollback.ExitCode (Format-ProcessResult $rollback)
    Assert-True $rollback.Stdout.Contains('result=rolled-back') (Format-ProcessResult $rollback)
    Assert-Equal $configHashBeforeApply (Get-Sha256File $configPath) 'rollback must restore exact config bytes'
    Assert-Equal $cacheHashBeforeApply (Get-Sha256File $cachePath) 'rollback must restore the original cache'
    Assert-True (-not (Test-Path -LiteralPath $generatedCatalog)) 'rollback must remove the unchanged generated catalog'
    Assert-True (-not (Test-Path -LiteralPath $statePath)) 'rollback must remove active state'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $codexHome 'provider-compat-transaction.json'))) 'rollback left an active transaction journal'
    Assert-Equal 1 @(Get-ChildItem -LiteralPath $codexHome -Filter 'provider-compat-state.json.rolled-back-*' -File).Count 'rollback state archive count'
    Write-Host 'PASS rollback restored config, cache, catalog, state, and transaction state'
} catch {
    $failure = $_
} finally {
    if ($server1) { try { $null = Stop-LocalMock $server1 $false } catch {} }
    if ($server2) { try { $null = Stop-LocalMock $server2 $false } catch {} }
    $realHomeAfter = Get-RealHomeSnapshot
    if ($realHomeBefore -ne $realHomeAfter -and -not $failure) {
        $failure = [Management.Automation.ErrorRecord]::new(
            [InvalidOperationException]::new('real Codex home hashes changed during request-shape integration test'),
            'RealCodexHomeChanged', [Management.Automation.ErrorCategory]::SecurityError, $null)
    }
    try { Remove-SafeTestTree $testRoot } catch { if (-not $failure) { $failure = $_ } }
}

if ($failure) {
    Write-Error $failure
    exit 1
}

Write-Host 'PASS real Codex home hashes unchanged'
Write-Host 'Request-shape integration test: passed=8 failed=0'
exit 0
