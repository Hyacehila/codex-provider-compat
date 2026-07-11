$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repo 'codex-provider-compat.ps1'
$fixtures = Join-Path $PSScriptRoot 'fixtures'
$powershellExe = (Get-Process -Id $PID).Path
$script:Passed = 0
$script:Failed = 0
$script:TempRoots = New-Object Collections.ArrayList
$script:TestTempParent = [IO.Path]::GetFullPath((Join-Path $repo '.test-tmp'))
$script:TestTempBase = [IO.Path]::GetFullPath((Join-Path $script:TestTempParent ("w-$PID-"+[guid]::NewGuid().ToString('N').Substring(0,8))))

$repoFull = [IO.Path]::GetFullPath($repo).TrimEnd('\','/')
$expectedTestParent = [IO.Path]::GetFullPath((Join-Path $repoFull '.test-tmp')).TrimEnd('\','/')
$userProfileFull = [IO.Path]::GetFullPath($env:USERPROFILE).TrimEnd('\','/')
if (-not $script:TestTempParent.TrimEnd('\','/').Equals($expectedTestParent,[StringComparison]::OrdinalIgnoreCase)) { throw 'test temp parent is not the repository .test-tmp directory' }
if ($script:TestTempParent.Equals($userProfileFull,[StringComparison]::OrdinalIgnoreCase) -or $script:TestTempParent.StartsWith($userProfileFull + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { throw 'test temp parent must not be inside the user profile' }
if (Test-Path -LiteralPath $script:TestTempParent) {$testParentItem=Get-Item -LiteralPath $script:TestTempParent -Force;if(-not$testParentItem.PSIsContainer-or($testParentItem.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){throw 'test temp parent must be a real directory, not a link'}}else{[IO.Directory]::CreateDirectory($script:TestTempParent)|Out-Null}
if(-not(Split-Path -Parent $script:TestTempBase).Equals($script:TestTempParent,[StringComparison]::OrdinalIgnoreCase)){throw 'unsafe test temp base parent'}
[IO.Directory]::CreateDirectory($script:TestTempBase)|Out-Null

function Assert-True($Value, [string]$Message) { if (-not $Value) { throw $Message } }
function Assert-False($Value, [string]$Message) { if ($Value) { throw $Message } }
function Assert-Equal($Expected, $Actual, [string]$Message) { if ($Expected -ne $Actual) { throw "$Message (expected=[$Expected] actual=[$Actual])" } }
function Assert-Contains([string]$Text, [string]$Expected, [string]$Message) { if (-not $Text.Contains($Expected)) { throw "$Message (missing=[$Expected])" } }
function Assert-NotContains([string]$Text, [string]$Unexpected, [string]$Message) { if ($Text.Contains($Unexpected)) { throw "$Message (unexpected=[$Unexpected])" } }
function Assert-KeySet($Object,[string[]]$Expected,[string]$Message){$actual=@($Object.PSObject.Properties.Name|Sort-Object)-join',';$wanted=@($Expected|Sort-Object)-join',';Assert-Equal $wanted $actual $Message}

function New-TestHome([string]$Name) {
    if ($Name -notmatch '^[A-Za-z0-9._-]+$') { throw "unsafe test name: $Name" }
    $shortName=if($Name.Length-gt12){$Name.Substring(0,12)}else{$Name};$testCodexRoot = [IO.Path]::GetFullPath((Join-Path $script:TestTempBase ("t-$shortName-" + [guid]::NewGuid().ToString('N').Substring(0,16))))
    if (-not (Split-Path -Parent $testCodexRoot).Equals($script:TestTempBase,[StringComparison]::OrdinalIgnoreCase)) { throw "unsafe test root parent: $testCodexRoot" }
    [IO.Directory]::CreateDirectory($testCodexRoot) | Out-Null
    [void]$script:TempRoots.Add($testCodexRoot)
    return $testCodexRoot
}

function Write-Utf8([string]$Path, [string]$Text, [bool]$Bom = $false) {
    $encoding = New-Object Text.UTF8Encoding($Bom)
    $body = $encoding.GetBytes($Text)
    if ($Bom) {
        $preamble = $encoding.GetPreamble(); $bytes = New-Object byte[] ($preamble.Length + $body.Length)
        [Array]::Copy($preamble,0,$bytes,0,$preamble.Length); [Array]::Copy($body,0,$bytes,$preamble.Length,$body.Length)
        [IO.File]::WriteAllBytes($Path,$bytes)
    } else { [IO.File]::WriteAllBytes($Path,$body) }
}

function Invoke-Tool([string[]]$Arguments, [hashtable]$Environment = @{}, [bool]$AuthorizeInternalTests = $true) {
    $effective = @{ CODEX_PROVIDER_COMPAT_TEST_VERSIONS = 'cli=0.144.1' }
    if($AuthorizeInternalTests){$effective['CODEX_PROVIDER_COMPAT_INTERNAL_TEST_CONFIRM']='I-understand-this-is-test-only'}else{$effective['CODEX_PROVIDER_COMPAT_INTERNAL_TEST_CONFIRM']=$null}
    foreach ($key in $Environment.Keys) { $effective[$key] = $Environment[$key] }
    $old = @{}
    foreach ($key in $effective.Keys) {
        $old[$key] = [Environment]::GetEnvironmentVariable($key,'Process')
        [Environment]::SetEnvironmentVariable($key, [string]$effective[$key], 'Process')
    }
    try {
        $output = & $powershellExe -NoLogo -NoProfile -File $scriptPath @Arguments 2>&1 | Out-String
        return [pscustomobject]@{ ExitCode=$LASTEXITCODE; Output=$output }
    } finally {
        foreach ($key in $effective.Keys) { [Environment]::SetEnvironmentVariable($key,$old[$key],'Process') }
    }
}

function Test-Case([string]$Name, [scriptblock]$Body) {
    if($env:CODEX_PROVIDER_COMPAT_TEST_CASE_FILTER-and$Name-notmatch$env:CODEX_PROVIDER_COMPAT_TEST_CASE_FILTER){Write-Host "SKIP $Name";return}
    try { & $Body; $script:Passed++; Write-Host "PASS $Name" }
    catch { $script:Failed++; Write-Host "FAIL $Name`n$($_.Exception.Message)" }
}

function Copy-Fixture([string]$Name,[string]$Destination) { [IO.File]::Copy((Join-Path $fixtures $Name),$Destination,$true) }
function Apply-Args([string]$CodexRoot,[string]$Catalog='models-valid.json') { return @('apply','--yes','--codex-home',$CodexRoot,'--codex-version','0.144.1','--catalog-file',(Join-Path $fixtures $Catalog)) }
function Status-Args([string]$CodexRoot) { return @('status','--codex-home',$CodexRoot,'--codex-version','0.144.1') }
function Rollback-Args([string]$CodexRoot) { return @('rollback','--yes','--codex-home',$CodexRoot) }
function Read-StateJson([string]$CodexRoot) { return ([IO.File]::ReadAllText((Join-Path $CodexRoot 'provider-compat-state.json'),[Text.Encoding]::UTF8) | ConvertFrom-Json) }
function Write-Json([string]$Path,$Value) { Write-Utf8 $Path (($Value | ConvertTo-Json -Depth 100) + "`n") }

function Snapshot-RealHome {
    $CodexRoot = if($env:CODEX_HOME){[IO.Path]::GetFullPath($env:CODEX_HOME)}else{Join-Path $env:USERPROFILE '.codex'}
    $result=[ordered]@{}
    foreach($name in @('config.toml','models_cache.json','provider-compat-state.json','provider-compat-transaction.json','provider-compat.lock')) {
        $path=Join-Path $CodexRoot $name; $result[$path]=if(Test-Path -LiteralPath $path -PathType Leaf){(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash}else{'<missing>'}
    }
    $catalogDir=Join-Path $CodexRoot 'model-catalogs'
    if(Test-Path -LiteralPath $catalogDir -PathType Container){Get-ChildItem -LiteralPath $catalogDir -File -ErrorAction SilentlyContinue|Sort-Object FullName|ForEach-Object{$result[$_.FullName]=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash}}
    foreach($pattern in @('config.toml.bak-provider-compat-*','models_cache.json.bak-provider-compat-*','provider-compat-state.json.rolled-back-*')){
        $result["listing:$pattern"] = @((Get-ChildItem -LiteralPath $CodexRoot -Filter $pattern -File -ErrorAction SilentlyContinue|Sort-Object Name|ForEach-Object Name)) -join '|'
    }
    return ($result|ConvertTo-Json -Depth 5 -Compress)
}

function Remove-SafeTree([string]$Path) {
    foreach($item in @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue)){
        if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint)-ne0){if($item.PSIsContainer){[IO.Directory]::Delete($item.FullName)}else{[IO.File]::Delete($item.FullName)};continue}
        if($item.PSIsContainer){Remove-SafeTree $item.FullName;Remove-Item -LiteralPath $item.FullName -Force}
        else{$item.IsReadOnly=$false;Remove-Item -LiteralPath $item.FullName -Force}
    }
}

function Remove-TestTree([string]$Path) {
    $full=[IO.Path]::GetFullPath($Path)
    if(-not(Split-Path -Parent $full).Equals($script:TestTempBase,[StringComparison]::OrdinalIgnoreCase) -or -not([IO.Path]::GetFileName($full).StartsWith('t-',[StringComparison]::Ordinal))){throw "unsafe test cleanup path: $full"}
    $rootItem=Get-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue
    if($rootItem -and (($rootItem.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0)){throw "test root is a reparse point: $full"}
    Remove-SafeTree $full;Remove-Item -LiteralPath $full -Force
}

function Set-TestPrivateAcl([string]$Path) {
    $userSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;$acl=New-Object Security.AccessControl.FileSecurity
    $acl.SetSecurityDescriptorSddlForm("O:${userSid}G:${userSid}D:P(A;;FA;;;${userSid})(A;;FA;;;SY)(A;;FA;;;BA)");Set-Acl -LiteralPath $Path -AclObject $acl
}

function Get-AtomicTemps([string]$CodexRoot) { return @(Get-ChildItem -LiteralPath $CodexRoot -Recurse -Force -File -Filter '*.provider-compat-*.tmp' -ErrorAction SilentlyContinue) }
function Assert-NoAtomicTemps([string]$CodexRoot,[string]$Message) { $temps=Get-AtomicTemps $CodexRoot;if($temps.Count-ne0){throw "$Message ($(@($temps.FullName)-join', '))"} }
function Get-ExpectedAtomicTemp([string]$Destination,[string]$Nonce) { return Join-Path (Split-Path -Parent $Destination) ('.'+[IO.Path]::GetFileName($Destination)+'.provider-compat-'+$Nonce+'.tmp') }
function Snapshot-TestRoot([string]$CodexRoot) {
    $full=[IO.Path]::GetFullPath($CodexRoot);if(-not(Split-Path -Parent $full).Equals($script:TestTempBase,[StringComparison]::OrdinalIgnoreCase)){throw "unsafe snapshot root: $full"}
    $result=New-Object Collections.Generic.List[string]
    foreach($item in @(Get-ChildItem -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue|Sort-Object FullName)){
        $relative=$item.FullName.Substring($full.Length).TrimStart('\','/')
        if($item.PSIsContainer){$result.Add("D|$relative|$($item.Attributes)")}else{$result.Add("F|$relative|$($item.Length)|$((Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash)|$($item.Attributes)")}
    }
    return $result -join "`n"
}

function Start-MockCatalogServer([string]$Mode, [byte[]]$Body = $null) {
    $bodyBase64=if($Body){[Convert]::ToBase64String($Body)}else{''}
    for($attempt=0;$attempt-lt10;$attempt++){
        $port=Get-Random -Minimum 20000 -Maximum 50000
        $job=Start-Job -ArgumentList $port,$Mode,$bodyBase64 -ScriptBlock {
            param($Port,$Mode,$BodyBase64)
            $ErrorActionPreference='Stop';$listener=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,[int]$Port);$client=$null
            try{
                $listener.Start();Write-Output "READY:$Port"
                $client=$listener.AcceptTcpClient();$stream=$client.GetStream();$readBuffer=New-Object byte[] 4096;$request=New-Object Text.StringBuilder
                while($request.ToString().IndexOf("`r`n`r`n",[StringComparison]::Ordinal)-lt0){$count=$stream.Read($readBuffer,0,$readBuffer.Length);if($count-le0){break};[void]$request.Append([Text.Encoding]::ASCII.GetString($readBuffer,0,$count));if($request.Length-gt32768){throw 'request too large'}}
                $body=if($BodyBase64){[Convert]::FromBase64String($BodyBase64)}else{[byte[]]@()};$ascii=[Text.Encoding]::ASCII
                switch($Mode){
                    'success'{$header=$ascii.GetBytes("HTTP/1.1 200 OK`r`nContent-Type: application/json`r`nContent-Length: $($body.Length)`r`nConnection: close`r`n`r`n");$stream.Write($header,0,$header.Length);$stream.Write($body,0,$body.Length)}
                    'redirect'{$header=$ascii.GetBytes("HTTP/1.1 302 Found`r`nLocation: https://example.invalid/forbidden`r`nContent-Length: 0`r`nConnection: close`r`n`r`n");$stream.Write($header,0,$header.Length)}
                    'truncated'{$declared=$body.Length+257;$header=$ascii.GetBytes("HTTP/1.1 200 OK`r`nContent-Type: application/json`r`nContent-Length: $declared`r`nConnection: close`r`n`r`n");$stream.Write($header,0,$header.Length);$stream.Write($body,0,$body.Length)}
                    'slow'{$header=$ascii.GetBytes("HTTP/1.1 200 OK`r`nContent-Type: application/json`r`nContent-Length: $($body.Length)`r`nConnection: close`r`n`r`n");$stream.Write($header,0,$header.Length);$stream.Flush();Start-Sleep -Seconds 2;$stream.Write($body,0,$body.Length)}
                    'stream-oversize'{$header=$ascii.GetBytes("HTTP/1.1 200 OK`r`nContent-Type: application/json`r`nConnection: close`r`n`r`n");$stream.Write($header,0,$header.Length);$chunk=New-Object byte[] 65536;for($i=0;$i-lt82;$i++){$stream.Write($chunk,0,$chunk.Length)}}
                    default{throw "unknown mode $Mode"}
                }
                $stream.Flush()
            }catch{Write-Output "SERVER-ERROR:$($_.Exception.Message)"}
            finally{if($client){$client.Dispose()};$listener.Stop()}
        }
        $ready=$false
        for($i=0;$i-lt100;$i++){Start-Sleep -Milliseconds 25;$messages=@(Receive-Job -Job $job -Keep);if($messages -match "READY:$port"){$ready=$true;break};if($job.State-in@('Failed','Stopped','Completed')){break}}
        if($ready){return [pscustomobject]@{Job=$job;Port=$port;Url="http://127.0.0.1:$port/openai/codex/rust-v0.144.1/codex-rs/models-manager/models.json"}}
        Stop-Job -Job $job -ErrorAction SilentlyContinue;Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    }
    throw 'could not start localhost mock catalog server'
}

function Stop-MockCatalogServer($Server) { if(-not$Server){return};Stop-Job -Job $Server.Job -ErrorAction SilentlyContinue;Remove-Job -Job $Server.Job -Force -ErrorAction SilentlyContinue }
function Get-TransportEnvironment($Server,[int]$TimeoutMilliseconds=5000){return @{CODEX_PROVIDER_COMPAT_INTERNAL_TEST_TRANSPORT='localhost-only-v1';CODEX_PROVIDER_COMPAT_INTERNAL_TEST_CONFIRM='I-understand-this-is-test-only';CODEX_PROVIDER_COMPAT_INTERNAL_TEST_URL=$Server.Url;CODEX_PROVIDER_COMPAT_INTERNAL_TEST_TIMEOUT_MS=[string]$TimeoutMilliseconds}}

$realBefore = if($env:CODEX_PROVIDER_COMPAT_TEST_CASE_FILTER){'<filtered-run-real-home-not-read>'}else{Snapshot-RealHome}

Test-Case 'apply/status/rollback full cycle, semantic catalog protection, and secret-free state' {
    $CodexRoot=New-TestHome 'cycle';Copy-Fixture 'config-complex.toml' (Join-Path $CodexRoot 'config.toml');Write-Utf8 (Join-Path $CodexRoot 'models_cache.json') 'cache-v1'
    $originalHash=(Get-FileHash -LiteralPath (Join-Path $CodexRoot 'config.toml')).Hash
    $apply=Invoke-Tool (Apply-Args $CodexRoot);Assert-Equal 0 $apply.ExitCode $apply.Output
    $stateText=[IO.File]::ReadAllText((Join-Path $CodexRoot 'provider-compat-state.json'),[Text.Encoding]::UTF8);$state=$stateText|ConvertFrom-Json
    Assert-Equal 'responses-lite-standard-tools' $state.patch_id 'patch id';Assert-True ($state.config.PSObject.Properties.Name -contains 'previous_model_catalog_json_literal') 'state stores minimal literal';Assert-True ($state.config.PSObject.Properties.Name -contains 'original_mode') 'cross-platform state field original_mode missing';Assert-Equal $null $state.config.original_mode 'Windows original_mode should be null';Assert-False ($state.config.PSObject.Properties.Name -contains 'previous_model_catalog_json_line') 'state must not store full config lines';Assert-NotContains $stateText '# user choice' 'state leaked a config comment';Assert-NotContains $stateText 'provider.example.invalid' 'state leaked provider configuration'
    $source=[IO.File]::ReadAllText((Join-Path $fixtures 'models-valid.json'),[Text.Encoding]::UTF8)|ConvertFrom-Json;$patched=[IO.File]::ReadAllText($state.generated_catalog.path,[Text.Encoding]::UTF8)|ConvertFrom-Json
    Assert-Equal $source.models.Count $patched.models.Count 'model count preserved';foreach($target in @('gpt-5.6-sol','gpt-5.6-terra','gpt-5.6-luna')){Assert-Equal $false (($patched.models|Where-Object slug -eq $target).use_responses_lite) "$target patched"};Assert-Equal $true (($patched.models|Where-Object slug -eq 'future-lite-model').use_responses_lite) 'other Lite model unchanged'
    $expected=[IO.File]::ReadAllText((Join-Path $fixtures 'models-valid.json'),[Text.Encoding]::UTF8)|ConvertFrom-Json;foreach($model in $expected.models){if($model.slug-in@('gpt-5.6-sol','gpt-5.6-terra','gpt-5.6-luna')){$model.use_responses_lite=$false}};Assert-Equal ($expected|ConvertTo-Json -Depth 100 -Compress) ($patched|ConvertTo-Json -Depth 100 -Compress) 'unexpected catalog semantic changes'
    Assert-Equal 0 (Invoke-Tool (Status-Args $CodexRoot)).ExitCode 'healthy status';Add-Content -LiteralPath (Join-Path $CodexRoot 'config.toml') -Value '# user change after apply'
    $rollback=Invoke-Tool (Rollback-Args $CodexRoot);Assert-Equal 0 $rollback.ExitCode $rollback.Output;$restored=[IO.File]::ReadAllText((Join-Path $CodexRoot 'config.toml'),[Text.Encoding]::UTF8);Assert-Contains $restored '# user change after apply' 'rollback lost later unrelated config';Assert-NotContains $restored 'standard-responses-compat.json' 'owned catalog key remained';Assert-True (Test-Path -LiteralPath (Join-Path $CodexRoot 'models_cache.json')) 'cache not restored';Assert-False (Test-Path -LiteralPath $state.generated_catalog.path) 'owned catalog remained';Assert-False (Test-Path -LiteralPath (Join-Path $CodexRoot 'provider-compat-transaction.json')) 'transaction remained'
}

Test-Case 'web search update and rollback preserve exact user comment' {
    $CodexRoot=New-TestHome 'web';Copy-Fixture 'config-complex.toml' (Join-Path $CodexRoot 'config.toml');$r=Invoke-Tool ((Apply-Args $CodexRoot)+@('--enable-web-search'));Assert-Equal 0 $r.ExitCode $r.Output
    $text=[IO.File]::ReadAllText((Join-Path $CodexRoot 'config.toml'),[Text.Encoding]::UTF8);Assert-Contains $text 'web_search = "live" # user choice' 'web_search was not updated safely'
    Assert-Equal 0 (Invoke-Tool (Rollback-Args $CodexRoot)).ExitCode 'rollback';$restored=[IO.File]::ReadAllText((Join-Path $CodexRoot 'config.toml'),[Text.Encoding]::UTF8);Assert-Contains $restored 'web_search = "disabled" # user choice' 'original web_search literal/comment not restored'
}

Test-Case 'missing config is removed on rollback while an originally empty config stays empty' {
    $missing=New-TestHome 'config-missing';Assert-Equal 0 (Invoke-Tool (Apply-Args $missing)).ExitCode 'missing apply';Assert-True (Test-Path -LiteralPath (Join-Path $missing 'config.toml')) 'config not created';$missingState=Read-StateJson $missing;Assert-Equal $null $missingState.cache.backup_path 'cache backup must remain JSON null when no cache existed';Assert-Equal $null $missingState.cache.sha256 'cache hash must remain JSON null when no cache existed';Assert-Equal 0 (Invoke-Tool (Rollback-Args $missing)).ExitCode 'missing rollback';Assert-False (Test-Path -LiteralPath (Join-Path $missing 'config.toml')) 'originally missing config was left behind'
    $empty=New-TestHome 'config-empty';[IO.File]::WriteAllBytes((Join-Path $empty 'config.toml'),[byte[]]@());Assert-Equal 0 (Invoke-Tool (Apply-Args $empty)).ExitCode 'empty apply';Assert-Equal 0 (Invoke-Tool (Rollback-Args $empty)).ExitCode 'empty rollback';Assert-True (Test-Path -LiteralPath (Join-Path $empty 'config.toml')) 'original empty config removed';Assert-Equal 0 (Get-Item -LiteralPath (Join-Path $empty 'config.toml')).Length 'empty config not restored byte-for-byte'
}

Test-Case 'CRLF, UTF-8 BOM, Unicode path, ACL, and original bytes survive a cycle' {
    $parent=New-TestHome 'unicode';$CodexRoot=Join-Path $parent '含 空格';[IO.Directory]::CreateDirectory($CodexRoot)|Out-Null;$config=Join-Path $CodexRoot 'config.toml';$text="# 注释`r`nmodel = `"gpt-5.6-sol`"`r`nmodel_provider = `"custom`"`r`n`r`n[model_providers.custom]`r`nname = `"x`"`r`n";Write-Utf8 $config $text $true;Set-TestPrivateAcl $config;$beforeHash=(Get-FileHash $config).Hash;$beforeAcl=(Get-Acl $config).Sddl
    Assert-Equal 0 (Invoke-Tool (Apply-Args $CodexRoot)).ExitCode 'apply';$bytes=[IO.File]::ReadAllBytes($config);$state=Read-StateJson $CodexRoot;Assert-True ($bytes[0]-eq0xEF-and$bytes[1]-eq0xBB-and$bytes[2]-eq0xBF) 'BOM lost';Assert-Contains ([Text.Encoding]::UTF8.GetString($bytes)) "`r`n" 'CRLF lost';Assert-Equal $beforeAcl (Get-Acl $config).Sddl 'ACL changed on apply';Assert-Equal $beforeAcl (Get-Acl -LiteralPath $state.config.backup_path).Sddl 'config backup ACL differs from source config'
    Assert-Equal 0 (Invoke-Tool (Rollback-Args $CodexRoot)).ExitCode 'rollback';Assert-Equal $beforeHash (Get-FileHash $config).Hash 'original bytes not restored';Assert-Equal $beforeAcl (Get-Acl $config).Sddl 'ACL changed on rollback'
}

Test-Case 'TOML lexer ignores multiline/array lookalikes and edits quoted keys only' {
    $CodexRoot=New-TestHome 'toml-lexer';$config=Join-Path $CodexRoot 'config.toml';$original=@'
note = """
model_catalog_json = "inside multiline"
web_search = "inside multiline"
"""
basic_four_quotes = """value""""
basic_five_quotes = """value"""""
literal_four_quotes = '''value''''
literal_five_quotes = '''value'''''
lookalikes = [
  "model_catalog_json = inside array",
  "web_search = inside array",
]
model = "gpt-5.6-sol"
model_provider = "custom"
"model_catalog_json" = "C:/old/catalog.json" # keep-catalog-comment
'web_search' = "disabled" # keep-web-comment

[model_providers.custom]
model_catalog_json = "section-value"
'@
    Write-Utf8 $config $original; $before=(Get-FileHash $config).Hash
    $apply=Invoke-Tool ((Apply-Args $CodexRoot)+@('--enable-web-search'));Assert-Equal 0 $apply.ExitCode $apply.Output;$text=[IO.File]::ReadAllText($config,[Text.Encoding]::UTF8);Assert-Contains $text 'model_catalog_json = "inside multiline"' 'multiline content changed';Assert-Contains $text '"model_catalog_json" = "' 'quoted catalog key style lost';Assert-Contains $text "'web_search' = `"live`" # keep-web-comment" 'quoted web key/comment lost';$stateText=[IO.File]::ReadAllText((Join-Path $CodexRoot 'provider-compat-state.json'),[Text.Encoding]::UTF8);Assert-NotContains $stateText 'keep-web-comment' 'state leaked comment'
    Assert-Equal 0 (Invoke-Tool (Rollback-Args $CodexRoot)).ExitCode 'rollback';Assert-Equal $before (Get-FileHash $config).Hash 'lexer cycle did not restore exact TOML'
}

Test-Case 'ambiguous, dotted, multiline-owned, duplicate, and invalid TOML fail closed' {
    $cases=@(
        "model_catalog_json = `"a`"`n`"model_catalog_json`" = `"b`"`n",
        "model_catalog_json.path = `"a`"`n",
        "model_catalog_json = `"`"`"a`n`"`"`"`n",
        "note = `"`"`"unterminated`nmodel_catalog_json = `"inside`"`n"
    )
    foreach($content in $cases){$CodexRoot=New-TestHome 'bad-toml';$config=Join-Path $CodexRoot 'config.toml';Write-Utf8 $config $content;$before=(Get-FileHash $config).Hash;$r=Invoke-Tool (Apply-Args $CodexRoot);Assert-Equal 3 $r.ExitCode $r.Output;Assert-Equal $before (Get-FileHash $config).Hash 'unsafe TOML changed';Assert-False (Test-Path -LiteralPath (Join-Path $CodexRoot 'provider-compat-state.json')) 'state written for unsafe TOML'}
}

Test-Case 'idempotent apply creates no extra backup or transaction' {
    $CodexRoot=New-TestHome 'idempotent';Copy-Fixture 'config-basic.toml' (Join-Path $CodexRoot 'config.toml');Assert-Equal 0 (Invoke-Tool (Apply-Args $CodexRoot)).ExitCode 'first apply';$count=@(Get-ChildItem -LiteralPath $CodexRoot -Filter 'config.toml.bak-provider-compat-*').Count;$second=Invoke-Tool (Apply-Args $CodexRoot);Assert-Equal 0 $second.ExitCode $second.Output;Assert-Contains $second.Output 'already-applied' 'missing idempotent result';Assert-Equal $count @(Get-ChildItem -LiteralPath $CodexRoot -Filter 'config.toml.bak-provider-compat-*').Count 'extra backup created';Assert-False (Test-Path -LiteralPath (Join-Path $CodexRoot 'provider-compat-transaction.json')) 'transaction remained'
}

Test-Case 'dry run performs zero writes' {
    $CodexRoot=New-TestHome 'dry';Copy-Fixture 'config-basic.toml' (Join-Path $CodexRoot 'config.toml');$before=(Get-FileHash (Join-Path $CodexRoot 'config.toml')).Hash;$listing=@(Get-ChildItem -LiteralPath $CodexRoot -Force|ForEach-Object Name)-join'|';$r=Invoke-Tool ((Apply-Args $CodexRoot)+@('--dry-run'));Assert-Equal 0 $r.ExitCode $r.Output;Assert-Equal $before (Get-FileHash (Join-Path $CodexRoot 'config.toml')).Hash 'config changed';Assert-Equal $listing (@(Get-ChildItem -LiteralPath $CodexRoot -Force|ForEach-Object Name)-join'|') 'dry-run created files'
}

Test-Case 'internal mutation and crash hooks require the explicit master confirmation' {
    $CodexRoot=New-TestHome 'unauthorized-hook';Copy-Fixture 'config-basic.toml' (Join-Path $CodexRoot 'config.toml');$before=Snapshot-TestRoot $CodexRoot
    Assert-NotContains ([IO.File]::ReadAllText($scriptPath,[Text.Encoding]::UTF8)) 'Get-ChildItem Env:' 'production script must not enumerate environment variables'
    $r=Invoke-Tool (Apply-Args $CodexRoot) @{CODEX_PROVIDER_COMPAT_TEST_MUTATE_CONFIG_BEFORE_WRITE='1'} $false;Assert-Equal 3 $r.ExitCode $r.Output;Assert-Contains $r.Output 'internal test hooks are disabled' 'missing internal test authorization error';Assert-Equal $before (Snapshot-TestRoot $CodexRoot) 'unauthorized hook changed the test Codex root';Assert-NoAtomicTemps $CodexRoot 'unauthorized hook left an atomic temp'
}

Test-Case 'invalid local catalog matrix fails with exit 3 and no config writes' {
    $dupeRoot=New-TestHome 'dupe-fixture';$dupe=Join-Path $dupeRoot 'duplicate.json';$json=[IO.File]::ReadAllText((Join-Path $fixtures 'models-valid.json'),[Text.Encoding]::UTF8)|ConvertFrom-Json;$json.models+=($json.models|Where-Object slug -eq 'gpt-5.6-sol');Write-Json $dupe $json
    foreach($file in @('models-missing-target.json','models-minimal.json','models-empty.json','models-wrong-type.json','models-invalid.json',$dupe)){$CodexRoot=New-TestHome 'bad-catalog';Copy-Fixture 'config-basic.toml' (Join-Path $CodexRoot 'config.toml');$before=(Get-FileHash (Join-Path $CodexRoot 'config.toml')).Hash;$catalog=if([IO.Path]::IsPathRooted($file)){$file}else{Join-Path $fixtures $file};$r=Invoke-Tool @('apply','--yes','--codex-home',$CodexRoot,'--codex-version','0.144.1','--catalog-file',$catalog);Assert-Equal 3 $r.ExitCode "$file $($r.Output)";Assert-Equal $before (Get-FileHash (Join-Path $CodexRoot 'config.toml')).Hash "$file changed config";Assert-False (Test-Path -LiteralPath (Join-Path $CodexRoot 'provider-compat-state.json')) "$file wrote state"}
}

Test-Case 'already-standard catalog is not applicable and writes nothing' {
    $CodexRoot=New-TestHome 'already-false';$file=Join-Path $CodexRoot 'false.json';$json=[IO.File]::ReadAllText((Join-Path $fixtures 'models-valid.json'),[Text.Encoding]::UTF8)|ConvertFrom-Json;foreach($model in $json.models){if($model.slug-in@('gpt-5.6-sol','gpt-5.6-terra','gpt-5.6-luna')){$model.use_responses_lite=$false}};Write-Json $file $json;$r=Invoke-Tool @('apply','--yes','--codex-home',$CodexRoot,'--codex-version','0.144.1','--catalog-file',$file);Assert-Equal 2 $r.ExitCode $r.Output;Assert-Equal 1 @(Get-ChildItem -LiteralPath $CodexRoot -File).Count 'unexpected files written'
}

Test-Case 'caught apply faults roll back every owned file' {
    foreach($stage in @('before-atomic-rename','apply-prepared','after-backup','after-catalog','after-cache','config-write','after-config','state-write')){$CodexRoot=New-TestHome "apply-fault-$stage";Copy-Fixture 'config-basic.toml' (Join-Path $CodexRoot 'config.toml');Write-Utf8 (Join-Path $CodexRoot 'models_cache.json') 'cache';$configHash=(Get-FileHash (Join-Path $CodexRoot 'config.toml')).Hash;$r=Invoke-Tool (Apply-Args $CodexRoot) @{CODEX_PROVIDER_COMPAT_TEST_FAIL_STAGE=$stage};Assert-Equal 3 $r.ExitCode "$stage $($r.Output)";Assert-Equal $configHash (Get-FileHash (Join-Path $CodexRoot 'config.toml')).Hash "$stage config not restored";Assert-True (Test-Path -LiteralPath (Join-Path $CodexRoot 'models_cache.json')) "$stage cache not restored";Assert-False (Test-Path -LiteralPath (Join-Path $CodexRoot 'provider-compat-state.json')) "$stage state remained";Assert-False (Test-Path -LiteralPath (Join-Path $CodexRoot 'provider-compat-transaction.json')) "$stage transaction remained";Assert-Equal 0 @(Get-ChildItem -LiteralPath (Join-Path $CodexRoot 'model-catalogs') -File -ErrorAction SilentlyContinue).Count "$stage catalog remained";Assert-NoAtomicTemps $CodexRoot "$stage left an atomic temp"}
}

Test-Case 'hard-terminated apply is read-only diagnosed and automatically recovered' {
    foreach($stage in @('apply-prepared','after-catalog','after-config')){$CodexRoot=New-TestHome "apply-crash-$stage";Copy-Fixture 'config-basic.toml' (Join-Path $CodexRoot 'config.toml');Write-Utf8 (Join-Path $CodexRoot 'models_cache.json') 'cache';$crash=Invoke-Tool (Apply-Args $CodexRoot) @{CODEX_PROVIDER_COMPAT_TEST_CRASH_STAGE=$stage};Assert-Equal 91 $crash.ExitCode "$stage did not hard-exit";Assert-True (Test-Path -LiteralPath (Join-Path $CodexRoot 'provider-compat-transaction.json')) "$stage journal missing";$transaction=[IO.File]::ReadAllText((Join-Path $CodexRoot 'provider-compat-transaction.json'),[Text.Encoding]::UTF8)|ConvertFrom-Json;$lock=[IO.File]::ReadAllText((Join-Path $CodexRoot 'provider-compat.lock'),[Text.Encoding]::UTF8)|ConvertFrom-Json;Assert-KeySet $transaction @('schema_version','operation','phase','nonce','created_at','updated_at','codex_version','root','paths','hashes','flags') 'transaction top-level schema';Assert-KeySet $transaction.paths @('config','config_backup','config_snapshot','generated_catalog','generated_catalog_pending','cache_original','cache_backup','state','state_archive') 'transaction paths schema';Assert-KeySet $transaction.hashes @('config_before','config_after','generated_catalog','cache','state') 'transaction hash schema';Assert-KeySet $transaction.flags @('config_existed','config_should_delete','generated_catalog_owned','cache_should_restore') 'transaction flag schema';Assert-Equal $CodexRoot $transaction.root 'transaction root';Assert-Equal $lock.nonce $transaction.nonce 'lock and transaction nonce diverged';$doctor=Invoke-Tool @('doctor','--codex-home',$CodexRoot,'--codex-version','0.144.1','--catalog-file',(Join-Path $fixtures 'models-valid.json'));Assert-Equal 3 $doctor.ExitCode $doctor.Output;Assert-Contains $doctor.Output 'recovery-required' 'doctor did not diagnose recovery';$retry=Invoke-Tool (Apply-Args $CodexRoot);Assert-Equal 0 $retry.ExitCode "$stage recovery/apply failed: $($retry.Output)";Assert-Equal 0 (Invoke-Tool (Status-Args $CodexRoot)).ExitCode "$stage unhealthy after recovery";Assert-Equal 0 (Invoke-Tool (Rollback-Args $CodexRoot)).ExitCode "$stage cleanup rollback";Assert-NoAtomicTemps $CodexRoot "$stage recovery left an atomic temp"}
}

Test-Case 'hard exit before initial journal rename is recovered from the stale lock nonce' {
    $CodexRoot=New-TestHome 'initial-journal-atomic-crash';Copy-Fixture 'config-basic.toml' (Join-Path $CodexRoot 'config.toml');Write-Utf8 (Join-Path $CodexRoot 'models_cache.json') 'cache'
    $crash=Invoke-Tool (Apply-Args $CodexRoot) @{CODEX_PROVIDER_COMPAT_TEST_CRASH_STAGE='initial-transaction-before-rename'}
    Assert-Equal 91 $crash.ExitCode 'initial journal write did not hard-exit';Assert-False (Test-Path -LiteralPath (Join-Path $CodexRoot 'provider-compat-transaction.json')) 'initial journal unexpectedly committed'
    $lockPath=Join-Path $CodexRoot 'provider-compat.lock';Assert-True (Test-Path -LiteralPath $lockPath) 'stale lock missing';$lock=[IO.File]::ReadAllText($lockPath,[Text.Encoding]::UTF8)|ConvertFrom-Json;Assert-True ([string]$lock.nonce-match'^[0-9a-f]{32}$') 'stale lock nonce is invalid'
    $journalPath=Join-Path $CodexRoot 'provider-compat-transaction.json';$journalTemp=Get-ExpectedAtomicTemp $journalPath ([string]$lock.nonce);Assert-True (Test-Path -LiteralPath $journalTemp) 'nonce-bound initial journal temp missing'
    $decoyNonce='11111111111111111111111111111111';$decoy=Get-ExpectedAtomicTemp (Join-Path $CodexRoot 'config.toml') $decoyNonce;Write-Utf8 $decoy 'preserve-me'
    $retry=Invoke-Tool (Apply-Args $CodexRoot);Assert-Equal 0 $retry.ExitCode $retry.Output;Assert-False (Test-Path -LiteralPath $journalTemp) 'stale lock recovery did not remove the exact initial journal temp';Assert-True (Test-Path -LiteralPath $decoy) 'stale lock recovery scanned and deleted an unrelated temp';Assert-Equal 'preserve-me' ([IO.File]::ReadAllText($decoy,[Text.Encoding]::UTF8)) 'unrelated temp changed'
    Remove-Item -LiteralPath $decoy -Force;Assert-NoAtomicTemps $CodexRoot 'initial journal recovery left an atomic temp';Assert-Equal 0 (Invoke-Tool (Rollback-Args $CodexRoot)).ExitCode 'cleanup rollback';Assert-NoAtomicTemps $CodexRoot 'initial journal cleanup rollback left an atomic temp'
}

Test-Case 'hard exit after apply config temp write is recovered with the journal nonce' {
    $CodexRoot=New-TestHome 'config-atomic-crash';Copy-Fixture 'config-basic.toml' (Join-Path $CodexRoot 'config.toml');Write-Utf8 (Join-Path $CodexRoot 'models_cache.json') 'cache';$originalHash=(Get-FileHash (Join-Path $CodexRoot 'config.toml')).Hash
    $crash=Invoke-Tool (Apply-Args $CodexRoot) @{CODEX_PROVIDER_COMPAT_TEST_CRASH_STAGE='apply-config-before-rename'};Assert-Equal 91 $crash.ExitCode 'config atomic write did not hard-exit'
    $transactionPath=Join-Path $CodexRoot 'provider-compat-transaction.json';Assert-True (Test-Path -LiteralPath $transactionPath) 'config crash journal missing';$transaction=[IO.File]::ReadAllText($transactionPath,[Text.Encoding]::UTF8)|ConvertFrom-Json;$lock=[IO.File]::ReadAllText((Join-Path $CodexRoot 'provider-compat.lock'),[Text.Encoding]::UTF8)|ConvertFrom-Json;Assert-Equal $lock.nonce $transaction.nonce 'config crash lock and transaction nonce diverged'
    $configPath=Join-Path $CodexRoot 'config.toml';$configTemp=Get-ExpectedAtomicTemp $configPath ([string]$transaction.nonce);Assert-True (Test-Path -LiteralPath $configTemp) 'nonce-bound config temp missing';Assert-Equal $originalHash (Get-FileHash $configPath).Hash 'config destination changed before rename'
    $doctor=Invoke-Tool @('doctor','--codex-home',$CodexRoot,'--codex-version','0.144.1','--catalog-file',(Join-Path $fixtures 'models-valid.json'));Assert-Equal 3 $doctor.ExitCode $doctor.Output;Assert-Contains $doctor.Output 'recovery-required' 'config crash doctor did not diagnose recovery'
    $beforeDryRun=Snapshot-TestRoot $CodexRoot;$dryApply=Invoke-Tool ((Apply-Args $CodexRoot)+@('--dry-run'));Assert-Equal 3 $dryApply.ExitCode $dryApply.Output;Assert-Contains $dryApply.Output 'recovery-required' 'apply dry-run did not report recovery';Assert-Equal $beforeDryRun (Snapshot-TestRoot $CodexRoot) 'apply dry-run changed interrupted transaction files'
    $dryRollback=Invoke-Tool ((Rollback-Args $CodexRoot)+@('--dry-run'));Assert-Equal 3 $dryRollback.ExitCode $dryRollback.Output;Assert-Contains $dryRollback.Output 'recovery-required' 'rollback dry-run did not report recovery';Assert-Equal $beforeDryRun (Snapshot-TestRoot $CodexRoot) 'rollback dry-run changed interrupted transaction files'
    $retry=Invoke-Tool (Apply-Args $CodexRoot);Assert-Equal 0 $retry.ExitCode $retry.Output;Assert-False (Test-Path -LiteralPath $configTemp) 'transaction recovery did not remove config temp';Assert-NoAtomicTemps $CodexRoot 'config crash recovery left an atomic temp';Assert-Equal 0 (Invoke-Tool (Status-Args $CodexRoot)).ExitCode 'config crash recovery status';Assert-Equal 0 (Invoke-Tool (Rollback-Args $CodexRoot)).ExitCode 'config crash cleanup rollback';Assert-NoAtomicTemps $CodexRoot 'config crash rollback left an atomic temp'
}

Test-Case 'late config race is preserved while apply-owned mutations are recovered' {
    $CodexRoot=New-TestHome 'late-race';Copy-Fixture 'config-basic.toml' (Join-Path $CodexRoot 'config.toml');Write-Utf8 (Join-Path $CodexRoot 'models_cache.json') 'cache';$r=Invoke-Tool (Apply-Args $CodexRoot) @{CODEX_PROVIDER_COMPAT_TEST_MUTATE_CONFIG_BEFORE_WRITE='1'};Assert-Equal 3 $r.ExitCode $r.Output;$text=[IO.File]::ReadAllText((Join-Path $CodexRoot 'config.toml'),[Text.Encoding]::UTF8);Assert-Contains $text '# late-external-change' 'external edit was overwritten';Assert-True (Test-Path -LiteralPath (Join-Path $CodexRoot 'models_cache.json')) 'cache not recovered';Assert-False (Test-Path -LiteralPath (Join-Path $CodexRoot 'provider-compat-transaction.json')) 'journal remained';Assert-Equal 0 @(Get-ChildItem -LiteralPath (Join-Path $CodexRoot 'model-catalogs') -File -ErrorAction SilentlyContinue).Count 'catalog remained'
}

Test-Case 'caught rollback faults restore the applied state; post-archive fault commits' {
    foreach($stage in @('rollback-prepared','rollback-after-snapshot','rollback-after-catalog','rollback-after-cache','rollback-config-write','rollback-after-config')){$CodexRoot=New-TestHome "rollback-fault-$stage";Copy-Fixture 'config-basic.toml' (Join-Path $CodexRoot 'config.toml');Write-Utf8 (Join-Path $CodexRoot 'models_cache.json') 'cache';Assert-Equal 0 (Invoke-Tool (Apply-Args $CodexRoot)).ExitCode "$stage apply";$r=Invoke-Tool (Rollback-Args $CodexRoot) @{CODEX_PROVIDER_COMPAT_TEST_FAIL_STAGE=$stage};Assert-Equal 3 $r.ExitCode "$stage $($r.Output)";Assert-Equal 0 (Invoke-Tool (Status-Args $CodexRoot)).ExitCode "$stage did not restore healthy applied state";Assert-False (Test-Path -LiteralPath (Join-Path $CodexRoot 'provider-compat-transaction.json')) "$stage journal remained"}
    $CodexRoot=New-TestHome 'rollback-post-archive';Copy-Fixture 'config-basic.toml' (Join-Path $CodexRoot 'config.toml');Assert-Equal 0 (Invoke-Tool (Apply-Args $CodexRoot)).ExitCode 'apply';$r=Invoke-Tool (Rollback-Args $CodexRoot) @{CODEX_PROVIDER_COMPAT_TEST_FAIL_STAGE='rollback-after-state'};Assert-Equal 0 $r.ExitCode $r.Output;Assert-False (Test-Path -LiteralPath (Join-Path $CodexRoot 'provider-compat-state.json')) 'committed rollback left state'
}

Test-Case 'hard-terminated rollback is recovered and then completed' {
    $CodexRoot=New-TestHome 'rollback-crash';$configPath=Join-Path $CodexRoot 'config.toml';Copy-Fixture 'config-basic.toml' $configPath;Set-TestPrivateAcl $configPath;Write-Utf8 (Join-Path $CodexRoot 'models_cache.json') 'cache';Assert-Equal 0 (Invoke-Tool (Apply-Args $CodexRoot)).ExitCode 'apply';$crash=Invoke-Tool (Rollback-Args $CodexRoot) @{CODEX_PROVIDER_COMPAT_TEST_CRASH_STAGE='rollback-after-config'};Assert-Equal 91 $crash.ExitCode $crash.Output;$transaction=[IO.File]::ReadAllText((Join-Path $CodexRoot 'provider-compat-transaction.json'),[Text.Encoding]::UTF8)|ConvertFrom-Json;Assert-True (Test-Path -LiteralPath $transaction.paths.config_snapshot) 'rollback snapshot missing after crash';Assert-Equal (Get-Acl -LiteralPath $configPath).Sddl (Get-Acl -LiteralPath $transaction.paths.config_snapshot).Sddl 'rollback snapshot ACL differs from config';Assert-Equal 3 (Invoke-Tool (Status-Args $CodexRoot)).ExitCode 'status should require recovery';$retry=Invoke-Tool (Rollback-Args $CodexRoot);Assert-Equal 0 $retry.ExitCode $retry.Output;Assert-False (Test-Path -LiteralPath (Join-Path $CodexRoot 'provider-compat-state.json')) 'state remained';Assert-True (Test-Path -LiteralPath (Join-Path $CodexRoot 'models_cache.json')) 'cache not restored';Assert-False (Test-Path -LiteralPath (Join-Path $CodexRoot 'provider-compat-transaction.json')) 'journal remained';Assert-NoAtomicTemps $CodexRoot 'rollback recovery left an atomic temp'
}

Test-Case 'tampered state paths cannot touch any file outside home' {
    foreach($field in @('catalog','config-backup','cache-original')){$CodexRoot=New-TestHome "state-tamper-$field";Copy-Fixture 'config-basic.toml' (Join-Path $CodexRoot 'config.toml');Write-Utf8 (Join-Path $CodexRoot 'models_cache.json') 'cache';Assert-Equal 0 (Invoke-Tool (Apply-Args $CodexRoot)).ExitCode 'apply';$outside=New-TestHome "outside-$field";$sentinel=Join-Path $outside 'sentinel.txt';Write-Utf8 $sentinel 'do-not-touch';$hash=(Get-FileHash $sentinel).Hash;$state=Read-StateJson $CodexRoot;switch($field){'catalog'{$state.generated_catalog.path=$sentinel}'config-backup'{$state.config.backup_path=$sentinel}'cache-original'{$state.cache.original_path=$sentinel}};Write-Json (Join-Path $CodexRoot 'provider-compat-state.json') $state;Assert-Equal 3 (Invoke-Tool (Status-Args $CodexRoot)).ExitCode "$field status";Assert-Equal 3 (Invoke-Tool (Rollback-Args $CodexRoot)).ExitCode "$field rollback";Assert-Equal $hash (Get-FileHash $sentinel).Hash "$field touched outside sentinel"}
}

Test-Case 'dot-segment Codex home and state paths fail closed with zero writes' {
    $parent=New-TestHome 'dot-parent';$CodexRoot=Join-Path $parent 'actual';[IO.Directory]::CreateDirectory($CodexRoot)|Out-Null;Copy-Fixture 'config-basic.toml' (Join-Path $CodexRoot 'config.toml');$before=(Get-FileHash (Join-Path $CodexRoot 'config.toml')).Hash;$dotHome=Join-Path (Join-Path $parent 'missing') '..\actual';$r=Invoke-Tool (Apply-Args $dotHome);Assert-Equal 3 $r.ExitCode $r.Output;Assert-Equal $before (Get-FileHash (Join-Path $CodexRoot 'config.toml')).Hash 'dot-segment home changed config';Assert-False (Test-Path -LiteralPath (Join-Path $CodexRoot 'provider-compat-state.json')) 'dot-segment home wrote state'
    Assert-Equal 0 (Invoke-Tool (Apply-Args $CodexRoot)).ExitCode 'baseline apply';$state=Read-StateJson $CodexRoot;$catalogName=[IO.Path]::GetFileName([string]$state.generated_catalog.path);$state.generated_catalog.path=Join-Path (Join-Path $CodexRoot 'missing') (Join-Path '..\model-catalogs' $catalogName);Write-Json (Join-Path $CodexRoot 'provider-compat-state.json') $state;$catalogHash=(Get-FileHash (Join-Path (Join-Path $CodexRoot 'model-catalogs') $catalogName)).Hash;$rollback=Invoke-Tool (Rollback-Args $CodexRoot);Assert-Equal 3 $rollback.ExitCode $rollback.Output;Assert-Equal $catalogHash (Get-FileHash (Join-Path (Join-Path $CodexRoot 'model-catalogs') $catalogName)).Hash 'dot-segment state path touched catalog'
}

Test-Case 'canonical-equivalent backup and archive paths are rejected literally' {
    $stateHome=New-TestHome 'canonical-state';Copy-Fixture 'config-basic.toml' (Join-Path $stateHome 'config.toml');Write-Utf8 (Join-Path $stateHome 'models_cache.json') 'cache';Assert-Equal 0 (Invoke-Tool (Apply-Args $stateHome)).ExitCode 'state baseline apply';$state=Read-StateJson $stateHome;$configBackup=[string]$state.config.backup_path;$cacheBackup=[string]$state.cache.backup_path;$configBackupHash=(Get-FileHash $configBackup).Hash;$cacheBackupHash=(Get-FileHash $cacheBackup).Hash;$state.config.backup_path=$configBackup.Replace('\','/');$state.cache.backup_path=$cacheBackup+'.';Write-Json (Join-Path $stateHome 'provider-compat-state.json') $state;Assert-Equal 3 (Invoke-Tool (Status-Args $stateHome)).ExitCode 'canonical-equivalent state status';Assert-Equal 3 (Invoke-Tool (Rollback-Args $stateHome)).ExitCode 'canonical-equivalent state rollback';Assert-Equal $configBackupHash (Get-FileHash $configBackup).Hash 'config backup touched';Assert-Equal $cacheBackupHash (Get-FileHash $cacheBackup).Hash 'cache backup touched'
    $txHome=New-TestHome 'canonical-tx';Copy-Fixture 'config-basic.toml' (Join-Path $txHome 'config.toml');Assert-Equal 0 (Invoke-Tool (Apply-Args $txHome)).ExitCode 'transaction baseline apply';$stateHash=(Get-FileHash (Join-Path $txHome 'provider-compat-state.json')).Hash;$crash=Invoke-Tool (Rollback-Args $txHome) @{CODEX_PROVIDER_COMPAT_TEST_CRASH_STAGE='rollback-after-snapshot'};Assert-Equal 91 $crash.ExitCode 'rollback did not crash after snapshot';$transactionPath=Join-Path $txHome 'provider-compat-transaction.json';$transaction=[IO.File]::ReadAllText($transactionPath,[Text.Encoding]::UTF8)|ConvertFrom-Json;$transaction.paths.state_archive=([string]$transaction.paths.state_archive).Replace('\','/');Write-Json $transactionPath $transaction;$retry=Invoke-Tool (Rollback-Args $txHome);Assert-Equal 3 $retry.ExitCode $retry.Output;Assert-Equal $stateHash (Get-FileHash (Join-Path $txHome 'provider-compat-state.json')).Hash 'state changed after canonical-equivalent transaction tamper'
}

Test-Case 'state schema type and field tampering fails closed with zero writes' {
    $cases=@(
        [pscustomobject]@{Name='string-bool';Mutate={param($o)$o.config.existed='false'}},
        [pscustomobject]@{Name='string-schema';Mutate={param($o)$o.schema_version='1'}},
        [pscustomobject]@{Name='numeric-version';Mutate={param($o)$o.patch_version=1}},
        [pscustomobject]@{Name='string-count';Mutate={param($o)$o.source_catalog.model_count='9'}},
        [pscustomobject]@{Name='missing-field';Mutate={param($o)$o.PSObject.Properties.Remove('applied_at')}},
        [pscustomobject]@{Name='extra-field';Mutate={param($o)$o|Add-Member -NotePropertyName unexpected -NotePropertyValue $true}},
        [pscustomobject]@{Name='wrong-null-object';Mutate={param($o)$o.source_catalog.url=[pscustomobject]@{unexpected=$true}}},
        [pscustomobject]@{Name='wrong-nested-object';Mutate={param($o)$o.config='not-an-object'}},
        [pscustomobject]@{Name='wrong-array-type';Mutate={param($o)$o.other_lite_models='future-lite-model'}}
    )
    foreach($case in $cases){
        $CodexRoot=New-TestHome ("state-schema-"+$case.Name);Copy-Fixture 'config-basic.toml' (Join-Path $CodexRoot 'config.toml');Assert-Equal 0 (Invoke-Tool (Apply-Args $CodexRoot)).ExitCode "$($case.Name) baseline apply"
        $statePath=Join-Path $CodexRoot 'provider-compat-state.json';$state=Read-StateJson $CodexRoot;& ([scriptblock]$case.Mutate) $state;Write-Json $statePath $state;$before=Snapshot-TestRoot $CodexRoot
        $status=Invoke-Tool (Status-Args $CodexRoot);Assert-Equal 3 $status.ExitCode "$($case.Name) status: $($status.Output)";Assert-Equal $before (Snapshot-TestRoot $CodexRoot) "$($case.Name) status changed files"
        $rollback=Invoke-Tool (Rollback-Args $CodexRoot);Assert-Equal 3 $rollback.ExitCode "$($case.Name) rollback: $($rollback.Output)";Assert-Equal $before (Snapshot-TestRoot $CodexRoot) "$($case.Name) rollback changed files"
    }
}

Test-Case 'transaction schema type and field tampering blocks recovery before writes' {
    $cases=@(
        [pscustomobject]@{Name='string-bool';Mutate={param($o)$o.flags.config_existed='false'}},
        [pscustomobject]@{Name='string-schema';Mutate={param($o)$o.schema_version='1'}},
        [pscustomobject]@{Name='numeric-operation';Mutate={param($o)$o.operation=1}},
        [pscustomobject]@{Name='missing-field';Mutate={param($o)$o.hashes.PSObject.Properties.Remove('cache')}},
        [pscustomobject]@{Name='extra-field';Mutate={param($o)$o|Add-Member -NotePropertyName unexpected -NotePropertyValue $true}},
        [pscustomobject]@{Name='null-object';Mutate={param($o)$o.paths.config_snapshot=[pscustomobject]@{unexpected=$true}}},
        [pscustomobject]@{Name='wrong-nested-object';Mutate={param($o)$o.paths='not-an-object'}},
        [pscustomobject]@{Name='wrong-timestamp';Mutate={param($o)$o.updated_at=[pscustomobject]@{unexpected=$true}}}
    )
    foreach($case in $cases){
        $CodexRoot=New-TestHome ("tx-schema-"+$case.Name);Copy-Fixture 'config-basic.toml' (Join-Path $CodexRoot 'config.toml');$crash=Invoke-Tool (Apply-Args $CodexRoot) @{CODEX_PROVIDER_COMPAT_TEST_CRASH_STAGE='apply-prepared'};Assert-Equal 91 $crash.ExitCode "$($case.Name) transaction setup"
        $transactionPath=Join-Path $CodexRoot 'provider-compat-transaction.json';$transaction=[IO.File]::ReadAllText($transactionPath,[Text.Encoding]::UTF8)|ConvertFrom-Json;& ([scriptblock]$case.Mutate) $transaction;Write-Json $transactionPath $transaction;$before=Snapshot-TestRoot $CodexRoot
        $apply=Invoke-Tool (Apply-Args $CodexRoot);Assert-Equal 3 $apply.ExitCode "$($case.Name) apply recovery: $($apply.Output)";Assert-Equal $before (Snapshot-TestRoot $CodexRoot) "$($case.Name) apply recovery changed files"
        $rollback=Invoke-Tool (Rollback-Args $CodexRoot);Assert-Equal 3 $rollback.ExitCode "$($case.Name) rollback recovery: $($rollback.Output)";Assert-Equal $before (Snapshot-TestRoot $CodexRoot) "$($case.Name) rollback recovery changed files"
    }
}

Test-Case 'tampered rollback journal cannot redirect pending catalog within home' {
    $CodexRoot=New-TestHome 'journal-tamper';Copy-Fixture 'config-basic.toml' (Join-Path $CodexRoot 'config.toml');Assert-Equal 0 (Invoke-Tool (Apply-Args $CodexRoot)).ExitCode 'apply';$crash=Invoke-Tool (Rollback-Args $CodexRoot) @{CODEX_PROVIDER_COMPAT_TEST_CRASH_STAGE='rollback-after-snapshot'};Assert-Equal 91 $crash.ExitCode 'rollback crash';$innocent=Join-Path $CodexRoot 'innocent.json';Write-Utf8 $innocent 'keep';$hash=(Get-FileHash $innocent).Hash;$transaction=[IO.File]::ReadAllText((Join-Path $CodexRoot 'provider-compat-transaction.json'),[Text.Encoding]::UTF8)|ConvertFrom-Json;$transaction.paths.generated_catalog_pending=$innocent;Write-Json (Join-Path $CodexRoot 'provider-compat-transaction.json') $transaction;$r=Invoke-Tool (Rollback-Args $CodexRoot);Assert-Equal 3 $r.ExitCode $r.Output;Assert-Equal $hash (Get-FileHash $innocent).Hash 'tampered journal touched innocent file'
}

Test-Case 'junction escape is rejected before any outside write' {
    $CodexRoot=New-TestHome 'junction-home';Copy-Fixture 'config-basic.toml' (Join-Path $CodexRoot 'config.toml');$outside=New-TestHome 'junction-outside';$sentinel=Join-Path $outside 'sentinel';Write-Utf8 $sentinel 'keep';$junction=Join-Path $CodexRoot 'model-catalogs';New-Item -ItemType Junction -Path $junction -Target $outside|Out-Null
    try{$r=Invoke-Tool (Apply-Args $CodexRoot);Assert-Equal 3 $r.ExitCode $r.Output;Assert-Equal 1 @(Get-ChildItem -LiteralPath $outside -File).Count 'wrote through junction';Assert-Equal 'keep' ([IO.File]::ReadAllText($sentinel,[Text.Encoding]::UTF8)) 'outside sentinel changed'}finally{if(Test-Path -LiteralPath $junction){[IO.Directory]::Delete($junction)}}
}

Test-Case 'active lock blocks; stale owned lock is reclaimed' {
    $CodexRoot=New-TestHome 'lock';Copy-Fixture 'config-basic.toml' (Join-Path $CodexRoot 'config.toml');$lock=Join-Path $CodexRoot 'provider-compat.lock';Write-Json $lock ([ordered]@{schema_version=1;pid=$PID;nonce=[guid]::NewGuid().ToString('N');created_at=[DateTimeOffset]::Now.ToString('o')});Assert-Equal 3 (Invoke-Tool (Apply-Args $CodexRoot)).ExitCode 'active lock';Write-Json $lock ([ordered]@{schema_version=1;pid=999999;nonce=[guid]::NewGuid().ToString('N');created_at=[DateTimeOffset]::Now.AddHours(-2).ToString('o')});Assert-Equal 0 (Invoke-Tool (Apply-Args $CodexRoot)).ExitCode 'stale lock not reclaimed'
}

Test-Case 'status detects version, config, semantic catalog, and backup drift' {
    $staleHome=New-TestHome 'status-version';Copy-Fixture 'config-basic.toml' (Join-Path $staleHome 'config.toml');Assert-Equal 0 (Invoke-Tool (Apply-Args $staleHome)).ExitCode 'apply';Assert-Equal 4 (Invoke-Tool @('status','--codex-home',$staleHome,'--codex-version','0.145.0')).ExitCode 'version stale';Assert-Equal 3 (Invoke-Tool @('status','--codex-home',$staleHome) @{CODEX_PROVIDER_COMPAT_TEST_VERSIONS='cli='}).ExitCode 'undetectable current version should be unknown'
    $configHome=New-TestHome 'status-config';Copy-Fixture 'config-basic.toml' (Join-Path $configHome 'config.toml');Assert-Equal 0 (Invoke-Tool (Apply-Args $configHome)).ExitCode 'apply';$config=Join-Path $configHome 'config.toml';$text=[IO.File]::ReadAllText($config,[Text.Encoding]::UTF8).Replace('standard-responses-compat.json','drift.json');Write-Utf8 $config $text;Assert-Equal 3 (Invoke-Tool (Status-Args $configHome)).ExitCode 'config drift'
    $catalogHome=New-TestHome 'status-semantic';Copy-Fixture 'config-basic.toml' (Join-Path $catalogHome 'config.toml');Assert-Equal 0 (Invoke-Tool (Apply-Args $catalogHome)).ExitCode 'apply';$state=Read-StateJson $catalogHome;$catalog=[IO.File]::ReadAllText($state.generated_catalog.path,[Text.Encoding]::UTF8)|ConvertFrom-Json;($catalog.models|Where-Object slug -eq 'gpt-5.6-sol').use_responses_lite=$true;Write-Json $state.generated_catalog.path $catalog;$state.generated_catalog.sha256=(Get-FileHash $state.generated_catalog.path).Hash;Write-Json (Join-Path $catalogHome 'provider-compat-state.json') $state;$driftedCatalogHash=(Get-FileHash $state.generated_catalog.path).Hash;Assert-Equal 3 (Invoke-Tool (Status-Args $catalogHome)).ExitCode 'semantic catalog drift bypassed hash check';$semanticRollback=Invoke-Tool (Rollback-Args $catalogHome);Assert-Equal 0 $semanticRollback.ExitCode $semanticRollback.Output;Assert-True (Test-Path -LiteralPath $state.generated_catalog.path) 'rollback deleted a semantically drifted catalog';Assert-Equal $driftedCatalogHash (Get-FileHash $state.generated_catalog.path).Hash 'rollback changed a semantically drifted catalog'
    $backupHome=New-TestHome 'status-backup';Copy-Fixture 'config-basic.toml' (Join-Path $backupHome 'config.toml');Assert-Equal 0 (Invoke-Tool (Apply-Args $backupHome)).ExitCode 'apply';$state=Read-StateJson $backupHome;Remove-Item -LiteralPath $state.config.backup_path;Assert-Equal 3 (Invoke-Tool (Status-Args $backupHome)).ExitCode 'missing config backup not detected'
}

Test-Case 'corrupt state refuses status and rollback' {
    $CodexRoot=New-TestHome 'corrupt-state';Write-Utf8 (Join-Path $CodexRoot 'provider-compat-state.json') '{bad';Assert-Equal 3 (Invoke-Tool (Status-Args $CodexRoot)).ExitCode 'status';Assert-Equal 3 (Invoke-Tool (Rollback-Args $CodexRoot)).ExitCode 'rollback'
}

Test-Case 'rollback preserves a new cache and its original backup' {
    $CodexRoot=New-TestHome 'cache-conflict';Copy-Fixture 'config-basic.toml' (Join-Path $CodexRoot 'config.toml');Write-Utf8 (Join-Path $CodexRoot 'models_cache.json') 'old';Assert-Equal 0 (Invoke-Tool (Apply-Args $CodexRoot)).ExitCode 'apply';Write-Utf8 (Join-Path $CodexRoot 'models_cache.json') 'new';$rb=Invoke-Tool (Rollback-Args $CodexRoot);Assert-Equal 0 $rb.ExitCode $rb.Output;Assert-Equal 'new' ([IO.File]::ReadAllText((Join-Path $CodexRoot 'models_cache.json'),[Text.Encoding]::UTF8)) 'new cache overwritten';Assert-Equal 1 @(Get-ChildItem -LiteralPath $CodexRoot -Filter 'models_cache.json.bak-provider-compat-*').Count 'old cache backup lost'
}

Test-Case 'network, redirect, timeout, truncation, size, and official schema failures are classified' {
    foreach($mode in @('404','500','timeout','slow','redirect','truncated','empty','oversize')){$CodexRoot=New-TestHome "network-$mode";Copy-Fixture 'config-basic.toml' (Join-Path $CodexRoot 'config.toml');$before=(Get-FileHash (Join-Path $CodexRoot 'config.toml')).Hash;$r=Invoke-Tool @('apply','--yes','--codex-home',$CodexRoot,'--codex-version','0.144.1') @{CODEX_PROVIDER_COMPAT_TEST_DOWNLOAD_MODE=$mode};Assert-Equal 5 $r.ExitCode "$mode $($r.Output)";Assert-Equal $before (Get-FileHash (Join-Path $CodexRoot 'config.toml')).Hash "$mode changed config"}
    foreach($mode in @('invalid-schema','malformed')){$CodexRoot=New-TestHome "official-schema-$mode";$r=Invoke-Tool @('apply','--yes','--codex-home',$CodexRoot,'--codex-version','0.144.1') @{CODEX_PROVIDER_COMPAT_TEST_DOWNLOAD_MODE=$mode};Assert-Equal 4 $r.ExitCode "$mode should be stale"}
    $CodexRoot=New-TestHome 'missing-tag';$r=Invoke-Tool @('apply','--yes','--codex-home',$CodexRoot,'--codex-version','999.999.999') @{CODEX_PROVIDER_COMPAT_TEST_DOWNLOAD_MODE='404'};Assert-Equal 5 $r.ExitCode 'missing tag';$relative=Invoke-Tool @('apply','--yes','--codex-home',$CodexRoot,'--codex-version','0.144.1','--catalog-file','relative.json');Assert-Equal 3 $relative.ExitCode 'relative local catalog misclassified as network'
}

Test-Case 'real HttpClient transport refuses redirects and enforces total timeout, truncation, and streaming size' {
    $validBytes=[IO.File]::ReadAllBytes((Join-Path $fixtures 'models-valid.json'))
    $successServer=Start-MockCatalogServer 'success' $validBytes
    try{$CodexRoot=New-TestHome 'transport-success';Copy-Fixture 'config-basic.toml' (Join-Path $CodexRoot 'config.toml');$r=Invoke-Tool @('apply','--yes','--codex-home',$CodexRoot,'--codex-version','0.144.1') (Get-TransportEnvironment $successServer 5000);Assert-Equal 0 $r.ExitCode $r.Output;$state=Read-StateJson $CodexRoot;Assert-Equal 'https://raw.githubusercontent.com/openai/codex/rust-v0.144.1/codex-rs/models-manager/models.json' $state.source_catalog.url 'state recorded internal transport URL';Assert-NotContains ([IO.File]::ReadAllText((Join-Path $CodexRoot 'provider-compat-state.json'),[Text.Encoding]::UTF8)) '127.0.0.1' 'state leaked test transport';Assert-Equal 0 (Invoke-Tool (Rollback-Args $CodexRoot)).ExitCode 'success transport rollback'}finally{Stop-MockCatalogServer $successServer}
    foreach($mode in @('redirect','truncated','slow','stream-oversize')){$server=Start-MockCatalogServer $mode $validBytes;try{$CodexRoot=New-TestHome "transport-$mode";Copy-Fixture 'config-basic.toml' (Join-Path $CodexRoot 'config.toml');$before=(Get-FileHash (Join-Path $CodexRoot 'config.toml')).Hash;$timeout=if($mode-eq'slow'){300}else{5000};$r=Invoke-Tool @('apply','--yes','--codex-home',$CodexRoot,'--codex-version','0.144.1') (Get-TransportEnvironment $server $timeout);Assert-Equal 5 $r.ExitCode "$mode $($r.Output)";Assert-Equal $before (Get-FileHash (Join-Path $CodexRoot 'config.toml')).Hash "$mode changed config";Assert-False (Test-Path -LiteralPath (Join-Path $CodexRoot 'provider-compat-state.json')) "$mode wrote state"}finally{Stop-MockCatalogServer $server}}
}

Test-Case 'version discovery and doctor conclusions are explicit and conservative' {
    $catalog=Join-Path $fixtures 'models-valid.json';$custom=New-TestHome 'doctor-custom';Copy-Fixture 'config-basic.toml' (Join-Path $custom 'config.toml');Assert-Equal 0 (Invoke-Tool @('doctor','--codex-home',$custom,'--catalog-file',$catalog) @{CODEX_PROVIDER_COMPAT_TEST_VERSIONS='cli=0.144.1'}).ExitCode 'custom target doctor'
    $unknown=New-TestHome 'doctor-unknown';Assert-Equal 3 (Invoke-Tool @('doctor','--codex-home',$unknown,'--catalog-file',$catalog) @{CODEX_PROVIDER_COMPAT_TEST_VERSIONS='cli=0.144.1'}).ExitCode 'unset provider/model should be unknown'
    $official=New-TestHome 'doctor-official';Write-Utf8 (Join-Path $official 'config.toml') "model = `"gpt-5.6-sol`"`nmodel_provider = `"openai`"`n";Assert-Equal 2 (Invoke-Tool @('doctor','--codex-home',$official,'--catalog-file',$catalog)).ExitCode 'official provider'
    $openaiBase=New-TestHome 'doctor-openai-base';Write-Utf8 (Join-Path $openaiBase 'config.toml') "model = `"gpt-5.6-sol`"`nmodel_provider = `"openai`"`nopenai_base_url = `"https://custom.invalid/v1`"`n";$openaiBaseResult=Invoke-Tool @('doctor','--codex-home',$openaiBase,'--catalog-file',$catalog);Assert-Equal 3 $openaiBaseResult.ExitCode 'openai_base_url override cannot be treated as official';Assert-Contains $openaiBaseResult.Output 'result=unknown' 'openai_base_url override conclusion'
    $openaiTable=New-TestHome 'doctor-openai-table';Write-Utf8 (Join-Path $openaiTable 'config.toml') "model = `"gpt-5.6-sol`"`nmodel_provider = `"openai`"`n[model_providers.'openai']`nbase_url = `"https://custom.invalid/v1`"`n";$openaiTableResult=Invoke-Tool @('doctor','--codex-home',$openaiTable,'--catalog-file',$catalog);Assert-Equal 3 $openaiTableResult.ExitCode 'model_providers.openai override cannot be treated as official';Assert-Contains $openaiTableResult.Output 'result=unknown' 'openai table override conclusion'
    $uncertainOpenAi=New-TestHome 'doctor-openai-uncertain';Write-Utf8 (Join-Path $uncertainOpenAi 'config.toml') "model = `"gpt-5.6-sol`"`nmodel_provider = `"openai`"`n[model_providers.`"op\u0065nai`"]`nbase_url = `"https://custom.invalid/v1`"`n";Assert-Equal 3 (Invoke-Tool @('doctor','--codex-home',$uncertainOpenAi,'--catalog-file',$catalog)).ExitCode 'uncertain openai table must fail closed'
    $chatgpt=New-TestHome 'doctor-chatgpt';Write-Utf8 (Join-Path $chatgpt 'config.toml') "model = `"gpt-5.6-sol`"`nmodel_provider = `"chatgpt`"`n";$chatgptResult=Invoke-Tool @('doctor','--codex-home',$chatgpt,'--catalog-file',$catalog);Assert-Equal 0 $chatgptResult.ExitCode 'chatgpt is not the built-in official provider id';Assert-Contains $chatgptResult.Output 'result=applicable' 'chatgpt provider did not remain applicable'
    $profile=New-TestHome 'doctor-profile';Copy-Fixture 'config-basic.toml' (Join-Path $profile 'config.toml');Write-Utf8 (Join-Path $profile 'work.config.toml') "model_provider = `"openai`"`n";$profileResult=Invoke-Tool @('doctor','--codex-home',$profile,'--catalog-file',$catalog);Assert-Equal 0 $profileResult.ExitCode 'unselected profile should not override base doctor conclusion';Assert-Contains $profileResult.Output 'profile_files_found=work.config.toml' 'profile file listing missing';Assert-Contains $profileResult.Output 'only when selected with --profile' 'profile selection warning missing';Assert-Contains $profileResult.Output 'result=applicable' 'base config conclusion was replaced by an unselected profile';Assert-Equal 0 (Invoke-Tool (Apply-Args $profile)).ExitCode 'profile base apply';$profileStatus=Invoke-Tool (Status-Args $profile);Assert-Equal 0 $profileStatus.ExitCode $profileStatus.Output;Assert-Contains $profileStatus.Output 'profile_files_found=work.config.toml' 'status profile file listing missing';Assert-Contains $profileStatus.Output 'only when selected with --profile' 'status profile warning missing';Assert-Equal 0 (Invoke-Tool (Rollback-Args $profile)).ExitCode 'profile cleanup rollback'
    $conflict=Invoke-Tool @('apply','--yes','--codex-home',$custom,'--catalog-file',$catalog) @{CODEX_PROVIDER_COMPAT_TEST_VERSIONS='cli=0.144.1;desktop=0.143.0'};Assert-Equal 3 $conflict.ExitCode 'version conflict';$explicit=Invoke-Tool @('apply','--dry-run','--yes','--codex-home',$custom,'--codex-version','0.144.1','--catalog-file',$catalog) @{CODEX_PROVIDER_COMPAT_TEST_VERSIONS='cli=bad;desktop=0.143.0'};Assert-Equal 0 $explicit.ExitCode 'explicit version';$none=Invoke-Tool @('apply','--yes','--codex-home',$custom,'--catalog-file',$catalog) @{CODEX_PROVIDER_COMPAT_TEST_VERSIONS='cli='};Assert-Equal 3 $none.ExitCode 'undetected version'
}

Test-Case 'unsafe home and read-only config fail with exit 3; external catalog is read-only input' {
    $root=[IO.Path]::GetPathRoot((Get-Location).Path);Assert-Equal 3 (Invoke-Tool @('apply','--yes','--codex-home',$root,'--codex-version','0.144.1','--catalog-file',(Join-Path $fixtures 'models-valid.json'))).ExitCode 'root home';Assert-Equal 3 (Invoke-Tool @('apply','--yes','--codex-home','relative-home','--codex-version','0.144.1','--catalog-file',(Join-Path $fixtures 'models-valid.json'))).ExitCode 'relative home'
    $drivePrefix=[IO.Path]::GetPathRoot($repo).Substring(0,2);Assert-Equal 3 (Invoke-Tool @('doctor','--codex-home',($drivePrefix+'relative-home'))).ExitCode 'drive-relative Codex home';Assert-Equal 3 (Invoke-Tool @('doctor','--codex-home',$drivePrefix)).ExitCode 'bare drive Codex home';$catalogHome=New-TestHome 'drive-relative-catalog';Assert-Equal 3 (Invoke-Tool @('apply','--yes','--codex-home',$catalogHome,'--codex-version','0.144.1','--catalog-file',($drivePrefix+'models.json'))).ExitCode 'drive-relative catalog file'
    Assert-Equal 3 (Invoke-Tool @('doctor','--codex-home','\\server\share\.codex')).ExitCode 'UNC Codex home'
    Assert-Equal 3 (Invoke-Tool @('doctor') @{CODEX_HOME='relative-home'}).ExitCode 'relative CODEX_HOME environment value'
    $profileBase=New-TestHome 'drive-relative-profile';$relativeProfile=$profileBase.Substring($repoFull.Length+1);$driveRelativeProfile=$drivePrefix+$relativeProfile;$defaultResult=Invoke-Tool @('apply','--yes','--codex-version','0.144.1','--catalog-file',(Join-Path $fixtures 'models-valid.json')) @{CODEX_HOME=$null;USERPROFILE=$driveRelativeProfile};Assert-Equal 3 $defaultResult.ExitCode 'drive-relative USERPROFILE default';Assert-False (Test-Path -LiteralPath (Join-Path $profileBase '.codex')) 'drive-relative USERPROFILE caused a write'
    $simulatedProfile=New-TestHome 'dangerous-user-profile';$profileResult=Invoke-Tool @('apply','--yes','--codex-home',$simulatedProfile,'--codex-version','0.144.1','--catalog-file',(Join-Path $fixtures 'models-valid.json')) @{USERPROFILE=$simulatedProfile};Assert-Equal 3 $profileResult.ExitCode 'Codex home equal to USERPROFILE';foreach($ownedName in @('config.toml','provider-compat-state.json','provider-compat-transaction.json','provider-compat.lock','model-catalogs')){Assert-False (Test-Path -LiteralPath (Join-Path $simulatedProfile $ownedName)) "dangerous USERPROFILE home received $ownedName"}
    $driveUsers=Join-Path ([IO.Path]::GetPathRoot($repo)) 'Users';Assert-Equal 3 (Invoke-Tool @('doctor','--codex-home',$driveUsers)).ExitCode 'drive Users directory'
    $systemTrees=@($env:SystemRoot,$env:ProgramFiles,${env:ProgramFiles(x86)},$env:ProgramW6432,$env:ProgramData)|Where-Object{-not[string]::IsNullOrWhiteSpace([string]$_)}|Select-Object -Unique;foreach($systemTree in $systemTrees){$unsafeDescendant=Join-Path ([string]$systemTree) 'CodexProviderCompatUnsafeProbe';Assert-Equal 3 (Invoke-Tool @('doctor','--codex-home',$unsafeDescendant)).ExitCode "system-managed descendant accepted: $unsafeDescendant"}
    $CodexRoot=New-TestHome 'readonly-config';Copy-Fixture 'config-basic.toml' (Join-Path $CodexRoot 'config.toml');$config=Get-Item (Join-Path $CodexRoot 'config.toml');$before=(Get-FileHash $config.FullName).Hash;$config.IsReadOnly=$true;try{$r=Invoke-Tool (Apply-Args $CodexRoot);Assert-Equal 3 $r.ExitCode $r.Output;Assert-Equal $before (Get-FileHash $config.FullName).Hash 'read-only config changed';Assert-False (Test-Path -LiteralPath (Join-Path $CodexRoot 'provider-compat-transaction.json')) 'journal remained'}finally{$config.IsReadOnly=$false}
    $outside=New-TestHome 'external-catalog';$external=Join-Path $outside 'models.json';Copy-Fixture 'models-valid.json' $external;$hash=(Get-FileHash $external).Hash;$externalHome=New-TestHome 'external-catalog-home';Copy-Fixture 'config-basic.toml' (Join-Path $externalHome 'config.toml');Assert-Equal 0 (Invoke-Tool @('apply','--yes','--codex-home',$externalHome,'--codex-version','0.144.1','--catalog-file',$external)).ExitCode 'external input apply';Assert-Equal $hash (Get-FileHash $external).Hash 'external catalog modified'
}

Test-Case 'confirmation TOCTOU is replanned once and repeated drift is rejected' {
    $once=New-TestHome 'toctou-once';Copy-Fixture 'config-basic.toml' (Join-Path $once 'config.toml');$r=Invoke-Tool (Apply-Args $once) @{CODEX_PROVIDER_COMPAT_TEST_MUTATE_CONFIG_AFTER_CONFIRM='once'};Assert-Equal 0 $r.ExitCode $r.Output;Assert-Contains ([IO.File]::ReadAllText((Join-Path $once 'config.toml'),[Text.Encoding]::UTF8)) '# external-change-1' 'one-time external edit lost'
    $always=New-TestHome 'toctou-always';Copy-Fixture 'config-basic.toml' (Join-Path $always 'config.toml');$r=Invoke-Tool (Apply-Args $always) @{CODEX_PROVIDER_COMPAT_TEST_MUTATE_CONFIG_AFTER_CONFIRM='always'};Assert-Equal 3 $r.ExitCode $r.Output;Assert-Contains ([IO.File]::ReadAllText((Join-Path $always 'config.toml'),[Text.Encoding]::UTF8)) '# external-change-2' 'repeated external edit lost';Assert-False (Test-Path -LiteralPath (Join-Path $always 'provider-compat-state.json')) 'state written after repeated drift';Assert-False (Test-Path -LiteralPath (Join-Path $always 'provider-compat-transaction.json')) 'transaction remained after repeated drift'
}

Test-Case 'backup names remain unique across repeated apply/rollback cycles' {
    $CodexRoot=New-TestHome 'backup-unique';Copy-Fixture 'config-basic.toml' (Join-Path $CodexRoot 'config.toml');Assert-Equal 0 (Invoke-Tool (Apply-Args $CodexRoot)).ExitCode 'first apply';Assert-Equal 0 (Invoke-Tool (Rollback-Args $CodexRoot)).ExitCode 'first rollback';Assert-Equal 0 (Invoke-Tool (Apply-Args $CodexRoot)).ExitCode 'second apply';$backups=@(Get-ChildItem -LiteralPath $CodexRoot -Filter 'config.toml.bak-provider-compat-*');Assert-Equal 2 $backups.Count 'backup collision overwrote an earlier backup';Assert-Equal 2 @($backups.Name|Select-Object -Unique).Count 'backup names not unique'
}

$realAfter = if($env:CODEX_PROVIDER_COMPAT_TEST_CASE_FILTER){'<filtered-run-real-home-not-read>'}else{Snapshot-RealHome}
Test-Case 'real Codex home hashes and owned-file listings are unchanged' { Assert-Equal $realBefore $realAfter 'real Codex home changed' }

foreach($testCodexRoot in $script:TempRoots){if(Test-Path -LiteralPath $testCodexRoot){Remove-TestTree $testCodexRoot}}
$remainingTestItems=@(Get-ChildItem -LiteralPath $script:TestTempBase -Force -ErrorAction SilentlyContinue)
if($remainingTestItems.Count-eq0){Remove-Item -LiteralPath $script:TestTempBase -Force}else{$script:Failed++;Write-Host "FAIL test temp base is not empty after cleanup: $(@($remainingTestItems.Name)-join', ')"}
Write-Host "Windows tests ($($PSVersionTable.PSVersion)): passed=$script:Passed failed=$script:Failed"
if($script:Failed -gt 0){exit 1}
