#!/usr/bin/env pwsh

# SPDX-License-Identifier: MIT
# Copyright (c) 2026 codex-provider-compat contributors

$ErrorActionPreference = 'Stop'
$script:ToolVersion = '0.2.1'
$script:PatchId = 'responses-lite-standard-tools'
$script:TargetModels = @('gpt-5.6-sol', 'gpt-5.6-terra', 'gpt-5.6-luna')
$script:TrackedConfigKeys = @('model_catalog_json', 'web_search', 'model', 'model_provider', 'openai_base_url')
$script:OwnedConfigKeys = @('model_catalog_json')
$script:MaxCatalogBytes = 5MB
$script:MinCatalogModels = 8
$script:MinNonTargetModels = 5
$script:ExitSuccess = 0
$script:ExitError = 1
$script:ExitNotApplicable = 2
$script:ExitUnsafe = 3
$script:ExitStale = 4
$script:ExitNetwork = 5
$script:TestMutationCount = 0

function Assert-InternalTestAuthorization {
    $hookNames=@('CODEX_PROVIDER_COMPAT_TEST_VERSIONS','CODEX_PROVIDER_COMPAT_TEST_DOWNLOAD_MODE','CODEX_PROVIDER_COMPAT_TEST_FAIL_STAGE','CODEX_PROVIDER_COMPAT_TEST_CRASH_STAGE','CODEX_PROVIDER_COMPAT_TEST_PAUSE_STAGE','CODEX_PROVIDER_COMPAT_TEST_PAUSE_EVENT','CODEX_PROVIDER_COMPAT_TEST_MUTATE_CONFIG_AFTER_CONFIRM','CODEX_PROVIDER_COMPAT_TEST_MUTATE_CONFIG_BEFORE_WRITE','CODEX_PROVIDER_COMPAT_INTERNAL_TEST_URL','CODEX_PROVIDER_COMPAT_INTERNAL_TEST_TIMEOUT_MS','CODEX_PROVIDER_COMPAT_INTERNAL_TEST_TRANSPORT')
    $used=$false;foreach($hookName in $hookNames){if(-not[string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable($hookName,'Process'))){$used=$true;break}}
    if($used-and[Environment]::GetEnvironmentVariable('CODEX_PROVIDER_COMPAT_INTERNAL_TEST_CONFIRM','Process')-ne'I-understand-this-is-test-only'){throw 'internal test hooks are disabled without CODEX_PROVIDER_COMPAT_INTERNAL_TEST_CONFIRM=I-understand-this-is-test-only'}
}

try { Add-Type -AssemblyName System.Net.Http -ErrorAction Stop } catch { }
if (-not ('ProviderCompatNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Threading;
public static class ProviderCompatNative {
    private delegate bool ConsoleControlHandler(int controlType);
    private static ConsoleControlHandler cancellationHandler;
    private static int cancellationHandlerInstalled;
    private static int cancellationRequested;

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool MoveFileEx(string existingFileName, string newFileName, int flags);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetConsoleCtrlHandler(ConsoleControlHandler handler, bool add);

    private static bool HandleConsoleControl(int controlType) {
        if (controlType != 0 && controlType != 1) {
            return false;
        }
        Interlocked.Exchange(ref cancellationRequested, 1);
        return true;
    }

    public static bool InstallCancellationHandler() {
        Interlocked.Exchange(ref cancellationRequested, 0);
        if (Interlocked.CompareExchange(ref cancellationHandlerInstalled, 0, 0) != 0) {
            return true;
        }
        cancellationHandler = new ConsoleControlHandler(HandleConsoleControl);
        if (!SetConsoleCtrlHandler(cancellationHandler, true)) {
            cancellationHandler = null;
            return false;
        }
        Interlocked.Exchange(ref cancellationHandlerInstalled, 1);
        return true;
    }

    public static bool RemoveCancellationHandler() {
        if (Interlocked.CompareExchange(ref cancellationHandlerInstalled, 0, 0) == 0) {
            return true;
        }
        if (!SetConsoleCtrlHandler(cancellationHandler, false)) {
            return false;
        }
        Interlocked.Exchange(ref cancellationHandlerInstalled, 0);
        cancellationHandler = null;
        return true;
    }

    public static bool CancellationRequested {
        get { return Interlocked.CompareExchange(ref cancellationRequested, 0, 0) != 0; }
    }
}
'@
}

function Write-Info([string]$Message) { Write-Host "[provider-compat] $Message" }
function Write-Warn([string]$Message) { Write-Warning "[provider-compat] $Message" }

function Get-AbsolutePath([string]$Path, [string]$Base = (Get-Location).Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'path is empty' }
    if (-not [IO.Path]::IsPathRooted($Path)) { $Path = Join-Path $Base $Path }
    return [IO.Path]::GetFullPath($Path)
}

function Test-IsFullyQualifiedWindowsPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if ($Path -match '^[A-Za-z]:[\\/]') { return $true }
    return $Path -match '^\\\\[^\\/]+[\\/][^\\/]+'
}

function Assert-NoDotPathSegments([string]$Path, [string]$Label = 'path') {
    if ([string]::IsNullOrWhiteSpace($Path)) { throw "$Label is empty" }
    foreach ($part in ($Path -split '[\\/]')) {
        if ($part -eq '.' -or $part -eq '..') { throw "$Label contains a forbidden dot segment" }
    }
    return $Path
}

function Assert-CanonicalOwnedPath([string]$Path, [string]$Label = 'tool-owned path') {
    Assert-NoDotPathSegments $Path $Label | Out-Null
    if (-not (Test-IsFullyQualifiedWindowsPath $Path)) { throw "$Label is not fully qualified" }
    $full = [IO.Path]::GetFullPath($Path)
    if (-not ([string]$Path).Equals($full, [StringComparison]::OrdinalIgnoreCase)) { throw "$Label is not in canonical Windows path form" }
    return $full
}

function Normalize-Path([string]$Path) {
    return (Get-AbsolutePath $Path).TrimEnd([char[]]@('\','/'))
}

function Test-PathEqual([string]$Left, [string]$Right) {
    if ([string]::IsNullOrWhiteSpace($Left) -or [string]::IsNullOrWhiteSpace($Right)) { return $false }
    return (Normalize-Path $Left).Equals((Normalize-Path $Right), [StringComparison]::OrdinalIgnoreCase)
}

function Resolve-CodexHome([string]$Explicit) {
    if (-not [string]::IsNullOrWhiteSpace($Explicit)) { if(-not(Test-IsFullyQualifiedWindowsPath $Explicit)){throw '--codex-home must be a fully qualified absolute path'};$raw = $Explicit }
    elseif (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) { if(-not(Test-IsFullyQualifiedWindowsPath $env:CODEX_HOME)){throw 'CODEX_HOME must be a fully qualified absolute path'};$raw = $env:CODEX_HOME }
    else { $raw = Join-Path $env:USERPROFILE '.codex' }
    if (-not (Test-IsFullyQualifiedWindowsPath $raw)) { throw 'resolved Codex home must be a fully qualified absolute path' }
    Assert-NoDotPathSegments $raw 'Codex home' | Out-Null
    $CodexRoot = Normalize-Path $raw
    $root = [IO.Path]::GetPathRoot($CodexRoot)
    if ([string]::IsNullOrWhiteSpace($CodexRoot) -or $CodexRoot.Equals($root.TrimEnd('\','/'), [StringComparison]::OrdinalIgnoreCase)) {
        throw "unsafe Codex home: $CodexRoot"
    }
    return $CodexRoot
}

function Assert-NoReparseComponents([string]$Path) {
    $full = Get-AbsolutePath $Path
    $root = [IO.Path]::GetPathRoot($full)
    $current = $root
    $relative = $full.Substring($root.Length).TrimStart('\','/')
    if ($relative.Length -eq 0) { return $full }
    foreach ($part in ($relative -split '[\\/]')) {
        if ([string]::IsNullOrEmpty($part)) { continue }
        $current = Join-Path $current $part
        $item = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
        if (-not $item) { break }
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "refusing path through a reparse point: $current"
        }
    }
    return $full
}

function Assert-CodexHomeSafe([string]$CodexRoot) {
    Assert-NoDotPathSegments $CodexRoot 'Codex home' | Out-Null
    $normalizedHome = Normalize-Path $CodexRoot
    if($normalizedHome.StartsWith('\\',[StringComparison]::Ordinal)){throw 'UNC and network-share Codex homes are not supported'}
    $volumeRoot=[IO.Path]::GetPathRoot($normalizedHome).TrimEnd('\','/')
    if($normalizedHome.Equals($volumeRoot,[StringComparison]::OrdinalIgnoreCase)){throw "unsafe Codex home: $normalizedHome"}
    $exactDangerous=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach($candidate in @($env:USERPROFILE,(Join-Path ([IO.Path]::GetPathRoot($normalizedHome)) 'Users'))){if(-not[string]::IsNullOrWhiteSpace([string]$candidate)){[void]$exactDangerous.Add((Normalize-Path ([string]$candidate)))}}
    if($exactDangerous.Contains($normalizedHome)){throw "refusing a dangerous Codex home: $normalizedHome"}
    foreach($candidate in @($env:SystemRoot,$env:ProgramFiles,${env:ProgramFiles(x86)},$env:ProgramW6432,$env:ProgramData)){
        if([string]::IsNullOrWhiteSpace([string]$candidate)){continue}
        $dangerousTree=Normalize-Path ([string]$candidate)
        if($normalizedHome.Equals($dangerousTree,[StringComparison]::OrdinalIgnoreCase)-or$normalizedHome.StartsWith($dangerousTree+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw "refusing a Codex home in a system-managed directory: $normalizedHome"}
    }
    Assert-NoReparseComponents $normalizedHome | Out-Null
    return $normalizedHome
}

function Assert-PathInHome([string]$CodexRoot, [string]$Path) {
    Assert-NoDotPathSegments $CodexRoot 'Codex home' | Out-Null
    $candidate = Assert-CanonicalOwnedPath $Path 'tool-owned path'
    $normalizedHome = Normalize-Path $CodexRoot
    $prefix = $normalizedHome + [IO.Path]::DirectorySeparatorChar
    if (-not ($candidate.Equals($normalizedHome, [StringComparison]::OrdinalIgnoreCase) -or $candidate.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase))) {
        throw "refusing to access a tool-owned path outside Codex home: $candidate"
    }
    return $candidate
}

function Assert-SafeOwnedPath([string]$CodexRoot, [string]$Path) {
    $candidate = Assert-PathInHome $CodexRoot $Path
    Assert-NoReparseComponents $candidate | Out-Null
    return $candidate
}

function Assert-ExpectedPath([string]$Actual, [string]$Expected, [string]$Label) {
    Assert-NoDotPathSegments $Actual $Label | Out-Null
    if (-not [IO.Path]::IsPathRooted($Actual) -or -not ([string]$Actual).Equals([string]$Expected, [StringComparison]::OrdinalIgnoreCase)) { throw "$Label does not match the expected tool-owned path" }
}

function Assert-HashString($Value, [string]$Label, [bool]$AllowNull = $false) {
    if ($null -eq $Value) { if ($AllowNull) { return }; throw "$Label is null" }
    if ($Value -isnot [string] -or $Value -notmatch '^[0-9A-Fa-f]{64}$') { throw "$Label is not a SHA-256 string" }
}

function Get-BytesSha256([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash($Bytes) } finally { $sha.Dispose() }
    return (($hash | ForEach-Object { $_.ToString('X2') }) -join '')
}

function Get-Sha256([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash($stream) } finally { $sha.Dispose(); $stream.Dispose() }
    return (($hash | ForEach-Object { $_.ToString('X2') }) -join '')
}

function Get-FileAclSemanticFingerprint($Acl) {
    try { $owner=$Acl.GetOwner([Security.Principal.SecurityIdentifier]).Value } catch { $owner=[string]$Acl.Owner }
    try { $group=$Acl.GetGroup([Security.Principal.SecurityIdentifier]).Value } catch { $group=[string]$Acl.Group }
    $rules=New-Object Collections.Generic.List[string]
    foreach($rule in $Acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])){
        [void]$rules.Add(('{0}|{1}|{2}|{3}|{4}' -f $rule.IdentityReference.Value,[int64]$rule.FileSystemRights,[string]$rule.AccessControlType,[string]$rule.InheritanceFlags,[string]$rule.PropagationFlags))
    }
    $sorted=@($rules|Sort-Object)
    return ($owner,$group,[string]$Acl.AreAccessRulesProtected,($sorted-join';'))-join"`n"
}

function Test-FileAclEquivalent($Left,$Right) {
    if($null-eq$Left-or$null-eq$Right){return $false}
    if($Left.Sddl-eq$Right.Sddl){return $true}
    return (Get-FileAclSemanticFingerprint $Left)-eq(Get-FileAclSemanticFingerprint $Right)
}

function Set-FileAclFromSourceIfNeeded($SourceAcl,[string]$Destination,[string]$Label) {
    $destinationAcl=Get-Acl -LiteralPath $Destination
    if(-not(Test-FileAclEquivalent $SourceAcl $destinationAcl)){
        try{Set-Acl -LiteralPath $Destination -AclObject $SourceAcl}catch{throw "could not preserve permissions for ${Label}: $($_.Exception.Message)"}
        $destinationAcl=Get-Acl -LiteralPath $Destination
    }
    if(-not(Test-FileAclEquivalent $SourceAcl $destinationAcl)){throw "$Label ACL verification failed"}
}

function Test-PathAclMatchesSddl([string]$Path,[string]$Sddl) {
    if([string]::IsNullOrEmpty($Sddl)){return $true}
    $expected=New-Object Security.AccessControl.FileSecurity
    try{$expected.SetSecurityDescriptorSddlForm($Sddl)}catch{return $false}
    return Test-FileAclEquivalent $expected (Get-Acl -LiteralPath $Path)
}

function Get-UniquePath([string]$BasePath) {
    if (-not (Test-Path -LiteralPath $BasePath)) { return $BasePath }
    for ($i = 1; $i -lt 1000; $i++) {
        $candidate = "$BasePath.$i"
        if (-not (Test-Path -LiteralPath $candidate)) { return $candidate }
    }
    throw "could not allocate unique backup path for $BasePath"
}

function Enter-OperationInterruptScope {
    if (-not [ProviderCompatNative]::InstallCancellationHandler()) {
        throw (New-Object ComponentModel.Win32Exception([Runtime.InteropServices.Marshal]::GetLastWin32Error()))
    }
    return $true
}

function Exit-OperationInterruptScope {
    if (-not [ProviderCompatNative]::RemoveCancellationHandler()) {
        Write-Warn ("could not unregister the console interrupt handler: " + (New-Object ComponentModel.Win32Exception([Runtime.InteropServices.Marshal]::GetLastWin32Error())).Message)
    }
}

function Assert-OperationNotCancelled {
    if ([ProviderCompatNative]::CancellationRequested) {
        throw (New-Object OperationCanceledException 'operation interrupted by Ctrl+C or Ctrl+Break')
    }
}

function Invoke-TestFault([string]$Stage) {
    Assert-OperationNotCancelled
    if ($env:CODEX_PROVIDER_COMPAT_TEST_PAUSE_STAGE -eq $Stage) {
        if (-not [string]::IsNullOrWhiteSpace($env:CODEX_PROVIDER_COMPAT_TEST_PAUSE_EVENT)) {
            $readyEvent = [Threading.EventWaitHandle]::OpenExisting($env:CODEX_PROVIDER_COMPAT_TEST_PAUSE_EVENT)
            try { [void]$readyEvent.Set() } finally { $readyEvent.Dispose() }
        }
        $deadline = [DateTime]::UtcNow.AddSeconds(30)
        while (-not [ProviderCompatNative]::CancellationRequested) {
            if ([DateTime]::UtcNow -ge $deadline) { throw "timed out waiting for a console interrupt at $Stage" }
            [Threading.Thread]::Sleep(20)
        }
        Assert-OperationNotCancelled
    }
    if ($env:CODEX_PROVIDER_COMPAT_TEST_CRASH_STAGE -eq $Stage) { [Environment]::Exit(91) }
    if ($env:CODEX_PROVIDER_COMPAT_TEST_FAIL_STAGE -eq $Stage) { throw "injected failure at $Stage" }
}

function Assert-OperationNonce([string]$Nonce, [string]$Label = 'operation nonce') {
    if ($Nonce -notmatch '^[0-9a-f]{32}$') { throw "$Label must be 32 lowercase hexadecimal characters" }
}

function Get-AtomicTempPath([string]$CodexRoot, [string]$Path, [string]$Nonce) {
    Assert-OperationNonce $Nonce
    $destination = Assert-SafeOwnedPath $CodexRoot $Path
    $dir = Split-Path -Parent $destination
    $tempPath = Join-Path $dir ('.' + [IO.Path]::GetFileName($destination) + '.provider-compat-' + $Nonce + '.tmp')
    return Assert-SafeOwnedPath $CodexRoot $tempPath
}

function Remove-AtomicTemp([string]$CodexRoot, [string]$Path, [string]$Nonce) {
    $tempPath = Get-AtomicTempPath $CodexRoot $Path $Nonce
    if (-not (Test-Path -LiteralPath $tempPath)) { return }
    if (-not (Test-Path -LiteralPath $tempPath -PathType Leaf)) { throw "atomic temp path is not a file: $tempPath" }
    [IO.File]::Delete($tempPath)
}

function Write-AtomicBytes([string]$CodexRoot, [string]$Path, [byte[]]$Bytes, [string]$Nonce, [bool]$SuppressFault = $false) {
    $Path = Assert-SafeOwnedPath $CodexRoot $Path
    Assert-OperationNonce $Nonce
    $dir = Split-Path -Parent $Path
    Assert-SafeOwnedPath $CodexRoot $dir | Out-Null
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { throw "directory does not exist: $dir" }
    $destinationExisted = Test-Path -LiteralPath $Path -PathType Leaf
    $tmp = Get-AtomicTempPath $CodexRoot $Path $Nonce
    try {
        $stream = New-Object IO.FileStream($tmp, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None, 4096, [IO.FileOptions]::WriteThrough)
        try { $stream.Write($Bytes, 0, $Bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
        if ((Get-Sha256 $tmp) -ne (Get-BytesSha256 $Bytes)) { throw "write verification failed for $Path" }
        if ($destinationExisted) {
            Set-FileAclFromSourceIfNeeded (Get-Acl -LiteralPath $Path) $tmp $Path
        }
        if (-not $SuppressFault) {
            $isInitialTransactionWrite = -not $destinationExisted -and (Test-PathEqual $Path (Get-TransactionPath $CodexRoot))
            if ($isInitialTransactionWrite -and $env:CODEX_PROVIDER_COMPAT_TEST_CRASH_STAGE -eq 'initial-transaction-before-rename') { [Environment]::Exit(91) }
            if ([IO.Path]::GetFileName($Path) -eq 'config.toml' -and $env:CODEX_PROVIDER_COMPAT_TEST_CRASH_STAGE -eq 'apply-config-before-rename') { [Environment]::Exit(91) }
            if ($env:CODEX_PROVIDER_COMPAT_TEST_FAIL_STAGE -eq 'before-atomic-rename') { throw 'injected failure before atomic rename' }
        }
        if (-not [ProviderCompatNative]::MoveFileEx($tmp, $Path, 9)) {
            throw (New-Object ComponentModel.Win32Exception([Runtime.InteropServices.Marshal]::GetLastWin32Error()))
        }
        if ((Get-Sha256 $Path) -ne (Get-BytesSha256 $Bytes)) { throw "atomic replace verification failed for $Path" }
    } finally {
        if (Test-Path -LiteralPath $tmp) { [IO.File]::Delete($tmp) }
    }
}

function ConvertTo-Utf8Bytes([string]$Text, [bool]$Bom) {
    $encoding = New-Object Text.UTF8Encoding($Bom, $true)
    $body = $encoding.GetBytes($Text)
    if (-not $Bom) { return ,$body }
    $preamble = $encoding.GetPreamble()
    $bytes = New-Object byte[] ($preamble.Length + $body.Length)
    [Array]::Copy($preamble, 0, $bytes, 0, $preamble.Length)
    [Array]::Copy($body, 0, $bytes, $preamble.Length, $body.Length)
    return ,$bytes
}

function Write-AtomicText([string]$CodexRoot, [string]$Path, [string]$Text, [bool]$Bom, [string]$Nonce, [bool]$SuppressFault = $false) {
    Write-AtomicBytes $CodexRoot $Path (ConvertTo-Utf8Bytes $Text $Bom) $Nonce $SuppressFault
}

function Set-PrivateFileAcl([string]$Path) {
    try {
        $userSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $sddl = "O:${userSid}G:${userSid}D:P(A;;FA;;;${userSid})(A;;FA;;;SY)(A;;FA;;;BA)"
        $acl = New-Object Security.AccessControl.FileSecurity
        $acl.SetSecurityDescriptorSddlForm($sddl)
        Set-Acl -LiteralPath $Path -AclObject $acl
    } catch { throw "could not restrict permissions on new config.toml: $($_.Exception.Message)" }
}

function Read-TextFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{ Exists=$false; Text=''; Bom=$false; Newline=[Environment]::NewLine; Bytes=[byte[]]@(); Sha256=$null; Acl=$null }
    }
    $bytes = [IO.File]::ReadAllBytes($Path)
    $bom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $offset = if ($bom) { 3 } else { 0 }
    $encoding = New-Object Text.UTF8Encoding($false, $true)
    try { $text = $encoding.GetString($bytes, $offset, $bytes.Length - $offset) } catch { throw "config.toml is not valid UTF-8: $($_.Exception.Message)" }
    $newline = if ($text.Contains("`r`n")) { "`r`n" } elseif ($text.Contains("`n")) { "`n" } else { [Environment]::NewLine }
    $acl = $null
    try { $acl = (Get-Acl -LiteralPath $Path).Sddl } catch { }
    return [pscustomobject]@{ Exists=$true; Text=$text; Bom=$bom; Newline=$newline; Bytes=$bytes; Sha256=(Get-BytesSha256 $bytes); Acl=$acl }
}

function Split-TextRecords([string]$Text) {
    $records = New-Object Collections.ArrayList
    if ($Text.Length -eq 0) { [void]$records.Add([pscustomobject]@{ Content=''; Ending='' }); return @($records) }
    $start = 0
    for ($i = 0; $i -lt $Text.Length; $i++) {
        if ($Text[$i] -eq "`r" -and $i + 1 -lt $Text.Length -and $Text[$i + 1] -eq "`n") {
            [void]$records.Add([pscustomobject]@{ Content=$Text.Substring($start, $i-$start); Ending="`r`n" })
            $i++; $start = $i + 1
        } elseif ($Text[$i] -eq "`n") {
            [void]$records.Add([pscustomobject]@{ Content=$Text.Substring($start, $i-$start); Ending="`n" })
            $start = $i + 1
        }
    }
    if ($start -lt $Text.Length) { [void]$records.Add([pscustomobject]@{ Content=$Text.Substring($start); Ending='' }) }
    return @($records)
}

function Parse-TomlKeyAssignment([string]$Line, [int]$Start) {
    $parts = New-Object Collections.ArrayList
    $i = $Start
    while ($true) {
        while ($i -lt $Line.Length -and [char]::IsWhiteSpace($Line[$i])) { $i++ }
        if ($i -ge $Line.Length) { throw 'invalid TOML key without an equals sign' }
        $value = ''
        if ($Line[$i] -eq "'" -or $Line[$i] -eq '"') {
            $quote = $Line[$i]; $i++; $builder = New-Object Text.StringBuilder; $escaped = $false; $closed = $false
            while ($i -lt $Line.Length) {
                $ch = $Line[$i]
                if ($quote -eq '"' -and $escaped) { [void]$builder.Append($ch); $escaped=$false; $i++; continue }
                if ($quote -eq '"' -and $ch -eq '\') { $escaped=$true; [void]$builder.Append($ch); $i++; continue }
                if ($ch -eq $quote) { $closed=$true; $i++; break }
                [void]$builder.Append($ch); $i++
            }
            if (-not $closed -or $escaped) { throw 'unterminated quoted TOML key' }
            $rawInner = $builder.ToString()
            if ($quote -eq '"') {
                if ($rawInner.Contains('\')) { throw 'escaped quoted TOML keys are not safely editable' }
                $value = $rawInner
            } else { $value = $rawInner }
        } else {
            $begin = $i
            while ($i -lt $Line.Length -and $Line[$i] -match '[A-Za-z0-9_-]') { $i++ }
            if ($i -eq $begin) { throw 'invalid TOML key syntax' }
            $value = $Line.Substring($begin, $i-$begin)
        }
        [void]$parts.Add($value)
        while ($i -lt $Line.Length -and [char]::IsWhiteSpace($Line[$i])) { $i++ }
        if ($i -lt $Line.Length -and $Line[$i] -eq '.') { $i++; continue }
        if ($i -lt $Line.Length -and $Line[$i] -eq '=') { return [pscustomobject]@{ Parts=@($parts); EqualsIndex=$i } }
        throw 'invalid TOML key; expected dot or equals sign'
    }
}

function New-TomlLexState { return [pscustomobject]@{ Mode='normal'; SquareDepth=0; CurlyDepth=0 } }

function Scan-TomlFragment([string]$Line, [int]$Start, $State) {
    $comment = -1
    $i = $Start
    while ($i -lt $Line.Length) {
        $ch = $Line[$i]
        switch ($State.Mode) {
            'normal' {
                if ($ch -eq '#') { $comment=$i; $i=$Line.Length; continue }
                if ($ch -eq '"') {
                    if ($i+2 -lt $Line.Length -and $Line.Substring($i,3) -eq '"""') { $State.Mode='multi-basic'; $i+=3 }
                    else { $State.Mode='basic'; $i++ }
                    continue
                }
                if ($ch -eq "'") {
                    if ($i+2 -lt $Line.Length -and $Line.Substring($i,3) -eq "'''" ) { $State.Mode='multi-literal'; $i+=3 }
                    else { $State.Mode='literal'; $i++ }
                    continue
                }
                if ($ch -eq '[') { $State.SquareDepth++; $i++; continue }
                if ($ch -eq ']') { $State.SquareDepth--; if($State.SquareDepth -lt 0){throw 'unbalanced TOML array bracket'}; $i++; continue }
                if ($ch -eq '{') { $State.CurlyDepth++; $i++; continue }
                if ($ch -eq '}') { $State.CurlyDepth--; if($State.CurlyDepth -lt 0){throw 'unbalanced TOML inline-table brace'}; $i++; continue }
                $i++
            }
            'basic' {
                if ($ch -eq '\') { $i += 2; continue }
                if ($ch -eq '"') { $State.Mode='normal' }
                $i++
            }
            'literal' { if ($ch -eq "'") { $State.Mode='normal' }; $i++ }
            'multi-basic' {
                if ($ch -eq '\') { $i += 2; continue }
                if ($ch -eq '"') {
                    $run=1;while($i+$run-lt$Line.Length-and$Line[$i+$run]-eq'"'){$run++}
                    if($run-ge3){$consume=if($run-le5){$run}else{3};$State.Mode='normal';$i+=$consume;continue}
                }
                $i++
            }
            'multi-literal' {
                if ($ch -eq "'") {
                    $run=1;while($i+$run-lt$Line.Length-and$Line[$i+$run]-eq"'"){$run++}
                    if($run-ge3){$consume=if($run-le5){$run}else{3};$State.Mode='normal';$i+=$consume;continue}
                }
                $i++
            }
        }
    }
    if ($State.Mode -eq 'basic' -or $State.Mode -eq 'literal') { throw 'unterminated single-line TOML string' }
    return $comment
}

function Assert-TomlTableHeader([string]$Line, [int]$Start) {
    $double = $Start+1 -lt $Line.Length -and $Line[$Start+1] -eq '['
    $openCount = if($double){2}else{1}; $closeToken=if($double){']]'}else{']'}
    $contentStart=$Start+$openCount;$i=$contentStart; $mode='normal'; $closed=$false;$closeStart=-1
    while($i -lt $Line.Length){
        $ch=$Line[$i]
        if($mode -eq 'normal'){
            if($ch -eq '"'){$mode='basic';$i++;continue}
            if($ch -eq "'"){$mode='literal';$i++;continue}
            if($i+$closeToken.Length-1 -lt $Line.Length -and $Line.Substring($i,$closeToken.Length) -eq $closeToken){$closeStart=$i;$i+=$closeToken.Length;$closed=$true;break}
            $i++;continue
        }
        if($mode -eq 'basic'){
            if($ch -eq '\'){$i+=2;continue}
            if($ch -eq '"'){$mode='normal'};$i++;continue
        }
        if($ch -eq "'"){$mode='normal'};$i++
    }
    if(-not $closed -or $mode -ne 'normal'){throw 'invalid or unterminated TOML table header'}
    while($i -lt $Line.Length -and [char]::IsWhiteSpace($Line[$i])){$i++}
    if($i -lt $Line.Length -and $Line[$i] -ne '#'){throw 'unexpected content after TOML table header'}
    $inner=$Line.Substring($contentStart,$closeStart-$contentStart)
    try{$assignment=Parse-TomlKeyAssignment ($inner+'=0') 0;return [pscustomobject]@{Parts=@($assignment.Parts);Certain=$true;IsArray=$double}}catch{return [pscustomobject]@{Parts=@();Certain=$false;IsArray=$double}}
}

function Copy-VerifiedFileWithAcl([string]$CodexRoot,[string]$Source,[string]$Destination,[string]$ExpectedHash,[string]$Label) {
    $sourcePath=Assert-SafeOwnedPath $CodexRoot $Source;$destinationPath=Assert-SafeOwnedPath $CodexRoot $Destination
    if(-not(Test-Path -LiteralPath $sourcePath -PathType Leaf)){throw "$Label source is missing"}
    if(Test-Path -LiteralPath $destinationPath){throw "$Label destination already exists"}
    $sourceAcl=Get-Acl -LiteralPath $sourcePath;$created=$false
    try{
        $empty=New-Object IO.FileStream($destinationPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None,4096,[IO.FileOptions]::WriteThrough);$empty.Dispose();$created=$true
        Set-FileAclFromSourceIfNeeded $sourceAcl $destinationPath $Label
        $bytes=[IO.File]::ReadAllBytes($sourcePath);$stream=New-Object IO.FileStream($destinationPath,[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::None,4096,[IO.FileOptions]::WriteThrough)
        try{$stream.SetLength(0);$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
        if((Get-Sha256 $destinationPath)-ne$ExpectedHash.ToUpperInvariant()){throw "$Label hash verification failed"}
        if(-not(Test-FileAclEquivalent $sourceAcl (Get-Acl -LiteralPath $destinationPath))){throw "$Label ACL verification failed after copying content"}
    }catch{if($created-and(Test-Path -LiteralPath $destinationPath -PathType Leaf)){[IO.File]::Delete($destinationPath)};throw}
}

function ConvertFrom-TomlSimpleValue([string]$Raw) {
    $value = $Raw.Trim()
    if ($value.Length -ge 2 -and $value[0] -eq "'" -and $value[$value.Length-1] -eq "'") { return $value.Substring(1,$value.Length-2) }
    if ($value.Length -ge 2 -and $value[0] -eq '"' -and $value[$value.Length-1] -eq '"') {
        try { return [string]($value | ConvertFrom-Json) } catch { throw 'unsupported or invalid escape in TOML basic string' }
    }
    return $value
}

function Get-ConfigAnalysisFromText([string]$Path, [bool]$Exists, [string]$Text, [bool]$Bom, [string]$Newline, [string]$Sha256, [string]$Acl) {
    $records = @(Split-TextRecords $Text)
    $keys = @{}
    foreach($key in $script:TrackedConfigKeys){$keys[$key]=New-Object Collections.ArrayList}
    $state=New-TomlLexState; $topLevel=$true; $sectionIndex=$records.Count;$modelProvidersOpenAiTable=$false;$unknownTableHeaders=$false
    for($index=0;$index -lt $records.Count;$index++){
        $line=[string]$records[$index].Content
        $atStatement = $state.Mode -eq 'normal' -and $state.SquareDepth -eq 0 -and $state.CurlyDepth -eq 0
        if(-not $atStatement){Scan-TomlFragment $line 0 $state|Out-Null;continue}
        $start=0;while($start -lt $line.Length -and [char]::IsWhiteSpace($line[$start])){$start++}
        if($start -ge $line.Length -or $line[$start] -eq '#'){continue}
        if($line[$start] -eq '['){$header=Assert-TomlTableHeader $line $start;if(-not$header.Certain){$unknownTableHeaders=$true}elseif($header.Parts.Count-ge2-and[string]$header.Parts[0]-ceq'model_providers'-and[string]$header.Parts[1]-ceq'openai'){$modelProvidersOpenAiTable=$true};if($topLevel){$sectionIndex=$index};$topLevel=$false;continue}
        $assignment=Parse-TomlKeyAssignment $line $start
        $first=[string]$assignment.Parts[0]
        if($topLevel -and $assignment.Parts.Count -gt 1 -and $first -in $script:OwnedConfigKeys){throw "dotted top-level $first is not safely editable"}
        $valueState=New-TomlLexState
        $commentIndex=Scan-TomlFragment $line ($assignment.EqualsIndex+1) $valueState
        $isTracked=$topLevel -and $assignment.Parts.Count -eq 1 -and $first -in $script:TrackedConfigKeys
        if($isTracked){
            $isSimpleValue=$valueState.Mode -eq 'normal' -and $valueState.SquareDepth -eq 0 -and $valueState.CurlyDepth -eq 0
            if(-not$isSimpleValue){
                if($first -ne 'web_search'){throw "top-level $first must use a simple single-line value"}
            }else{
                $valueEnd=if($commentIndex -ge 0){$commentIndex}else{$line.Length}
                $raw=$line.Substring($assignment.EqualsIndex+1,$valueEnd-$assignment.EqualsIndex-1).Trim()
                if([string]::IsNullOrWhiteSpace($raw)){throw "top-level $first has an empty value"}
                $isCompleteMultilineWebString=$first-eq'web_search'-and(($raw.StartsWith('"""',[StringComparison]::Ordinal)-and$raw.EndsWith('"""',[StringComparison]::Ordinal))-or($raw.StartsWith("'''",[StringComparison]::Ordinal)-and$raw.EndsWith("'''",[StringComparison]::Ordinal)))
                if(-not$isCompleteMultilineWebString){$parsedValue=ConvertFrom-TomlSimpleValue $raw;[void]$keys[$first].Add([pscustomobject]@{Index=$index;Line=$line;Raw=$raw;Value=$parsedValue;EqualsIndex=$assignment.EqualsIndex;CommentIndex=$commentIndex})}
            }
        }
        $state=$valueState
    }
    if($state.Mode -ne 'normal' -or $state.SquareDepth -ne 0 -or $state.CurlyDepth -ne 0){throw 'unterminated multi-line TOML value'}
    return [pscustomobject]@{Path=$Path;Exists=$Exists;Text=$Text;Bom=$Bom;Newline=$Newline;Sha256=$Sha256;Acl=$Acl;Records=$records;SectionIndex=$sectionIndex;Keys=$keys;ModelProvidersOpenAiTable=$modelProvidersOpenAiTable;UnknownTableHeaders=$unknownTableHeaders}
}

function Get-ConfigAnalysis([string]$Path) {
    $file=Read-TextFile $Path
    return Get-ConfigAnalysisFromText $Path $file.Exists $file.Text $file.Bom $file.Newline $file.Sha256 $file.Acl
}

function Assert-NoDuplicateOwnedKeys($Analysis) {
    foreach($key in $script:OwnedConfigKeys){if($Analysis.Keys[$key].Count -gt 1){throw "duplicate top-level $key keys in config.toml"}}
}

function Quote-TomlString([string]$Value) {
    $normalized=$Value.Replace('\','/').Replace('"','\"')
    return '"'+$normalized+'"'
}

function Convert-RecordsToText($Records) {
    $builder=New-Object Text.StringBuilder
    foreach($record in $Records){[void]$builder.Append([string]$record.Content);[void]$builder.Append([string]$record.Ending)}
    return $builder.ToString()
}

function Set-ConfigKey($Analysis,[string]$Key,[string]$Literal,[bool]$ShouldRemove,$RestoreLine=$null){
    $records=New-Object Collections.ArrayList
    foreach($record in $Analysis.Records){[void]$records.Add([pscustomobject]@{Content=[string]$record.Content;Ending=[string]$record.Ending})}
    $entries=$Analysis.Keys[$Key]
    if($entries.Count -gt 1){throw "duplicate top-level $Key keys in config.toml"}
    if($entries.Count -eq 1){
        $entry=$entries[0];$idx=[int]$entry.Index
        if($ShouldRemove){$records.RemoveAt($idx)}
        elseif($null -ne $RestoreLine){$records[$idx].Content=$RestoreLine}
        else{
            $line=[string]$records[$idx].Content;$commentStart=if($entry.CommentIndex -ge 0){[int]$entry.CommentIndex}else{$line.Length}
            $region=$line.Substring($entry.EqualsIndex+1,$commentStart-$entry.EqualsIndex-1)
            $leading=([regex]::Match($region,'^\s*')).Value;$trailing=([regex]::Match($region,'\s*$')).Value
            $comment=if($commentStart -lt $line.Length){$line.Substring($commentStart)}else{''}
            $records[$idx].Content=$line.Substring(0,$entry.EqualsIndex+1)+$leading+$Literal+$trailing+$comment
        }
    }elseif(-not $ShouldRemove){
        $ending=$Analysis.Newline
        if($records.Count -eq 1 -and $records[0].Content -eq '' -and $records[0].Ending -eq ''){$records[0].Content="$Key = $Literal";$records[0].Ending=$ending}
        else{$records.Insert(0,[pscustomobject]@{Content="$Key = $Literal";Ending=$ending})}
    }
    return Convert-RecordsToText @($records)
}

function Get-ConfigPlan([string]$ConfigPath,[string]$GeneratedPath){
    $analysis=Get-ConfigAnalysis $ConfigPath;Assert-NoDuplicateOwnedKeys $analysis
    $text=Set-ConfigKey $analysis 'model_catalog_json' (Quote-TomlString $GeneratedPath) $false
    return [pscustomobject]@{Analysis=$analysis;Text=$text;AfterBytes=(ConvertTo-Utf8Bytes $text $analysis.Bom);Fingerprint=if($analysis.Exists){$analysis.Sha256}else{'<missing>'}}
}

function Invoke-TestConfigMutation([string]$ConfigPath){
    $mode=$env:CODEX_PROVIDER_COMPAT_TEST_MUTATE_CONFIG_AFTER_CONFIRM
    if(-not $mode){return}
    $script:TestMutationCount++
    if($mode -eq 'once' -and $script:TestMutationCount -gt 1){return}
    [IO.File]::AppendAllText($ConfigPath,"# external-change-$script:TestMutationCount`r`n",(New-Object Text.UTF8Encoding($false)))
}

function Invoke-CodexVersion([string]$Path,[string]$Label){
    try{
        if($Path.EndsWith('.ps1',[StringComparison]::OrdinalIgnoreCase)){$output=& $Path --version 2>&1|Out-String}
        else{$psi=New-Object Diagnostics.ProcessStartInfo;$psi.FileName=$Path;$psi.Arguments='--version';$psi.UseShellExecute=$false;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true;$psi.CreateNoWindow=$true;$process=[Diagnostics.Process]::Start($psi);if(-not $process.WaitForExit(5000)){$process.Kill();throw 'version command timed out'};$output=$process.StandardOutput.ReadToEnd()+"`n"+$process.StandardError.ReadToEnd()}
        if($output -match '(\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)'){return [pscustomobject]@{Source=$Label;Path=$Path;Version=$Matches[1];Error=$null}}
        return [pscustomobject]@{Source=$Label;Path=$Path;Version=$null;Error='unrecognized version output'}
    }catch{return [pscustomobject]@{Source=$Label;Path=$Path;Version=$null;Error=$_.Exception.Message}}
}

function Discover-CodexVersions([string]$CodexRoot){
    if($env:CODEX_PROVIDER_COMPAT_TEST_VERSIONS){$items=New-Object Collections.ArrayList;foreach($entry in($env:CODEX_PROVIDER_COMPAT_TEST_VERSIONS -split ';')){if(-not $entry){continue};$parts=$entry -split '=',2;$version=if($parts.Count -eq 2 -and $parts[1]){$parts[1]}else{$null};[void]$items.Add([pscustomobject]@{Source=$parts[0];Path='<test-fixture>';Version=$version;Error=if($version){$null}else{'injected invalid output'}})};return @($items)}
    $items=New-Object Collections.ArrayList;$seen=@{};$cmd=Get-Command codex -ErrorAction SilentlyContinue|Select-Object -First 1
    if($cmd){$path=$cmd.Source;$seen[$path.ToLowerInvariant()]=$true;[void]$items.Add((Invoke-CodexVersion $path 'PATH CLI'))}
    $candidates=New-Object Collections.ArrayList
    [void]$candidates.Add([pscustomobject]@{Path=(Join-Path $CodexRoot 'plugins\.plugin-appserver\codex.exe');Label='Codex home app-server'})
    if($env:LOCALAPPDATA){$localBin=Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin';if(Test-Path -LiteralPath $localBin){Get-ChildItem -LiteralPath $localBin -Directory -ErrorAction SilentlyContinue|ForEach-Object{[void]$candidates.Add([pscustomobject]@{Path=(Join-Path $_.FullName 'codex.exe');Label='Desktop runtime'})}}}
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|Where-Object{$_.Name -eq 'codex.exe' -and $_.ExecutablePath}|ForEach-Object{[void]$candidates.Add([pscustomobject]@{Path=$_.ExecutablePath;Label='running Codex/app-server'})}
    Get-AppxPackage -ErrorAction SilentlyContinue|Where-Object{$_.Name -eq 'OpenAI.Codex'}|ForEach-Object{[void]$candidates.Add([pscustomobject]@{Path=(Join-Path $_.InstallLocation 'app\resources\codex.exe');Label="Desktop package $($_.Version)"})}
    foreach($candidate in $candidates){if(-not(Test-Path -LiteralPath $candidate.Path -PathType Leaf)){continue};$key=(Get-AbsolutePath $candidate.Path).ToLowerInvariant();if($seen.ContainsKey($key)){continue};$seen[$key]=$true;[void]$items.Add((Invoke-CodexVersion $candidate.Path $candidate.Label))}
    return @($items)
}

function Select-CodexVersion([string]$Explicit,$Discovered,[bool]$ForWrite){
    if(-not[string]::IsNullOrWhiteSpace($Explicit)){if($Explicit -notmatch '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$'){throw "invalid Codex version: $Explicit"};return $Explicit}
    $versions=@($Discovered|Where-Object{$_.Version}|Select-Object -ExpandProperty Version -Unique)
    if($versions.Count -eq 1){return $versions[0]};if($versions.Count -eq 0){if($ForWrite){throw 'could not detect Codex version; use --codex-version'};return $null}
    throw('conflicting Codex versions detected: '+($versions -join ', ')+'. Codex surfaces can update independently but share one Codex home and model catalog; use --codex-version only for the CLI or Desktop surface you will fully restart')
}

function Get-JsonProperties($Object){
    $result=@{};foreach($property in $Object.PSObject.Properties){$result[$property.Name]=$property.Value};return $result
}

function Add-JsonDifferences($Left,$Right,[string]$Path,[Collections.Generic.List[string]]$Differences){
    if($null -eq $Left -or $null -eq $Right){if(-not($null -eq $Left -and $null -eq $Right)){$Differences.Add($Path)};return}
    $leftArray=$Left -is [Array] -or $Left -is [Collections.IList];$rightArray=$Right -is [Array] -or $Right -is [Collections.IList]
    if($leftArray -or $rightArray){if(-not($leftArray -and $rightArray)){$Differences.Add($Path);return};if($Left.Count -ne $Right.Count){$Differences.Add($Path+'.length');return};for($i=0;$i -lt $Left.Count;$i++){Add-JsonDifferences $Left[$i] $Right[$i] "$Path[$i]" $Differences};return}
    $leftObject=$Left -is [pscustomobject];$rightObject=$Right -is [pscustomobject]
    if($leftObject -or $rightObject){if(-not($leftObject -and $rightObject)){$Differences.Add($Path);return};$lp=Get-JsonProperties $Left;$rp=Get-JsonProperties $Right;$names=@($lp.Keys+$rp.Keys|Sort-Object -Unique);foreach($name in $names){if(-not $lp.ContainsKey($name)-or-not $rp.ContainsKey($name)){$Differences.Add("$Path.$name")}else{Add-JsonDifferences $lp[$name] $rp[$name] "$Path.$name" $Differences}};return}
    if($Left -is [string] -or $Right -is [string]){if(-not([string]$Left).Equals([string]$Right,[StringComparison]::Ordinal)){$Differences.Add($Path)};return}
    if($Left.GetType() -ne $Right.GetType() -or $Left -ne $Right){$Differences.Add($Path)}
}

function ConvertFrom-CatalogJson([string]$Raw,[string]$SourceSha){
    try{$original=$Raw|ConvertFrom-Json;$patched=$Raw|ConvertFrom-Json}catch{throw "invalid or truncated catalog JSON: $($_.Exception.Message)"}
    if($null -eq $original -or $original -isnot [pscustomobject] -or $null -eq $original.models){throw 'catalog must be an object with a models array'}
    $models=@($original.models);$patchedModels=@($patched.models)
    if($models.Count -lt $script:MinCatalogModels){throw "catalog has $($models.Count) models; at least $script:MinCatalogModels are required"}
    $nonTargets=@($models|Where-Object{[string]$_.slug -notin $script:TargetModels})
    if($nonTargets.Count -lt $script:MinNonTargetModels){throw "catalog has only $($nonTargets.Count) non-target models; refusing a minimal catalog"}
    $indices=New-Object 'Collections.Generic.Dictionary[string,int]' ([StringComparer]::Ordinal)
    for($i=0;$i -lt $models.Count;$i++){$model=$models[$i];if($null -eq $model -or $model -isnot [pscustomobject] -or [string]::IsNullOrWhiteSpace([string]$model.slug)){throw 'every model must be an object with a non-empty slug'};$slug=[string]$model.slug;if($indices.ContainsKey($slug)){throw "duplicate model slug: $slug"};$indices.Add($slug,$i)}
    $states=[ordered]@{};$allowed=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach($target in $script:TargetModels){if(-not $indices.ContainsKey($target)){throw "target model missing: $target"};$index=$indices[$target];$value=$models[$index].use_responses_lite;if($value -isnot [bool]){throw "use_responses_lite for $target must be boolean"};$states[$target]=$value;if($value -eq $true){[void]$allowed.Add("$.models[$index].use_responses_lite")};$patchedModels[$index].use_responses_lite=$false}
    $differences=New-Object 'Collections.Generic.List[string]';Add-JsonDifferences $original $patched '$' $differences
    foreach($difference in $differences){if(-not $allowed.Contains($difference)){throw "catalog patch changed an unexpected semantic path: $difference"}}
    if($differences.Count -ne $allowed.Count){throw 'catalog patch did not produce exactly the expected target changes'}
    $patchedJson=($patched|ConvertTo-Json -Depth 100)+"`n";$roundTrip=$patchedJson|ConvertFrom-Json;$roundDiff=New-Object 'Collections.Generic.List[string]';Add-JsonDifferences $patched $roundTrip '$' $roundDiff;if($roundDiff.Count -gt 0){throw "serialized catalog changed semantics at $($roundDiff[0])"}
    $otherLite=@($models|Where-Object{[string]$_.slug -notin $script:TargetModels -and $_.use_responses_lite -eq $true}|ForEach-Object{[string]$_.slug})
    return [pscustomobject]@{Raw=$Raw;PatchedJson=$patchedJson;PatchedBytes=(ConvertTo-Utf8Bytes $patchedJson $false);ModelCount=$models.Count;SourceSha256=$SourceSha;OriginalStates=$states;OtherLite=$otherLite;AllTargetsAlreadyFalse=(-not($states.Values -contains $true))}
}

function Read-CatalogFile([string]$Path){
    if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){throw "catalog not found: $Path"};$bytes=[IO.File]::ReadAllBytes($Path);if($bytes.Length -eq 0){throw 'catalog is empty'};if($bytes.Length -gt $script:MaxCatalogBytes){throw "catalog exceeds $script:MaxCatalogBytes bytes"};$encoding=New-Object Text.UTF8Encoding($false,$true);try{$raw=$encoding.GetString($bytes)}catch{throw 'catalog is not valid UTF-8'};return ConvertFrom-CatalogJson $raw (Get-BytesSha256 $bytes)
}

function Download-OfficialCatalog([string]$Version){
    $url="https://raw.githubusercontent.com/openai/codex/rust-v$Version/codex-rs/models-manager/models.json"
    $uri=New-Object Uri($url)
    if($uri.Scheme -ne 'https' -or $uri.Host -ne 'raw.githubusercontent.com' -or $uri.Query -or $uri.AbsolutePath -ne "/openai/codex/rust-v$Version/codex-rs/models-manager/models.json"){throw 'refusing a non-official catalog URL'}
    $requestUri=$uri;$timeoutMilliseconds=30000
    $transportEnabled=$env:CODEX_PROVIDER_COMPAT_INTERNAL_TEST_TRANSPORT -eq 'localhost-only-v1' -and $env:CODEX_PROVIDER_COMPAT_INTERNAL_TEST_CONFIRM -eq 'I-understand-this-is-test-only'
    if($transportEnabled){
        if([string]::IsNullOrWhiteSpace($env:CODEX_PROVIDER_COMPAT_INTERNAL_TEST_URL)){throw 'internal test transport URL is missing'}
        try{$candidate=New-Object Uri($env:CODEX_PROVIDER_COMPAT_INTERNAL_TEST_URL)}catch{throw 'internal test transport URL is invalid'}
        if($candidate.Scheme-ne'http' -or $candidate.Host-ne'127.0.0.1' -or $candidate.Port-lt1024 -or $candidate.Port-gt65535 -or $candidate.UserInfo -or $candidate.Query -or $candidate.AbsolutePath-ne$uri.AbsolutePath){throw 'internal test transport is restricted to an exact-path 127.0.0.1 endpoint'}
        $requestUri=$candidate
        if($env:CODEX_PROVIDER_COMPAT_INTERNAL_TEST_TIMEOUT_MS){$parsedTimeout=0;if(-not[int]::TryParse($env:CODEX_PROVIDER_COMPAT_INTERNAL_TEST_TIMEOUT_MS,[ref]$parsedTimeout)-or$parsedTimeout-lt100-or$parsedTimeout-gt5000){throw 'internal test timeout must be between 100 and 5000 ms'};$timeoutMilliseconds=$parsedTimeout}
    }elseif($env:CODEX_PROVIDER_COMPAT_INTERNAL_TEST_URL -or $env:CODEX_PROVIDER_COMPAT_INTERNAL_TEST_TIMEOUT_MS -or $env:CODEX_PROVIDER_COMPAT_INTERNAL_TEST_TRANSPORT){throw 'incomplete or invalid internal test transport authorization'}
    $mode=$env:CODEX_PROVIDER_COMPAT_TEST_DOWNLOAD_MODE
    if($mode){switch($mode){'404'{throw 'HTTP 404 from official catalog'}'500'{throw 'HTTP 500 from official catalog'}'timeout'{throw 'official catalog download timed out'}'redirect'{throw 'official catalog returned a redirect, which is not allowed'}'truncated'{throw 'official catalog response was truncated'}'slow'{throw 'official catalog download timed out'}'empty'{$bytes=[byte[]]@()}'oversize'{$bytes=New-Object byte[] ($script:MaxCatalogBytes+1)}'invalid-schema'{$bytes=[Text.Encoding]::UTF8.GetBytes('{"models":[]}')}'malformed'{$bytes=[Text.Encoding]::UTF8.GetBytes('{"models":[')}default{throw "unknown test download mode: $mode"}}}
    else{
        $handler=New-Object Net.Http.HttpClientHandler;$handler.AllowAutoRedirect=$false;$client=New-Object Net.Http.HttpClient($handler);$client.Timeout=[Threading.Timeout]::InfiniteTimeSpan;$response=$null;$stream=$null;$memory=$null;$cts=New-Object Threading.CancellationTokenSource
        $cts.CancelAfter($timeoutMilliseconds)
        try{
            $response=$client.GetAsync($requestUri,[Net.Http.HttpCompletionOption]::ResponseHeadersRead,$cts.Token).GetAwaiter().GetResult()
            if([int]$response.StatusCode -ge 300 -and [int]$response.StatusCode -lt 400){throw 'official catalog returned a redirect, which is not allowed'}
            if(-not $response.IsSuccessStatusCode){throw "HTTP $([int]$response.StatusCode) from official catalog"}
            $declared=$response.Content.Headers.ContentLength;if($declared -and $declared -gt $script:MaxCatalogBytes){throw 'official catalog response is too large'}
            $stream=$response.Content.ReadAsStreamAsync().GetAwaiter().GetResult();$memory=New-Object IO.MemoryStream;$buffer=New-Object byte[] 65536
            while(($read=$stream.ReadAsync($buffer,0,$buffer.Length,$cts.Token).GetAwaiter().GetResult()) -gt 0){$memory.Write($buffer,0,$read);if($memory.Length -gt $script:MaxCatalogBytes){throw 'official catalog response is too large'}}
            $bytes=$memory.ToArray();if($declared -ne $null -and $bytes.Length -ne [long]$declared){throw 'official catalog response was truncated'}
        }catch [OperationCanceledException]{throw 'official catalog download timed out'}
        finally{if($memory){$memory.Dispose()};if($stream){$stream.Dispose()};if($response){$response.Dispose()};$cts.Dispose();$client.Dispose();$handler.Dispose()}
    }
    if($bytes.Length -eq 0){throw 'official catalog response is empty'};if($bytes.Length -gt $script:MaxCatalogBytes){throw 'official catalog response is too large'}
    $encoding=New-Object Text.UTF8Encoding($false,$true);try{$raw=$encoding.GetString($bytes)}catch{throw 'official catalog is not valid UTF-8'}
    return [pscustomobject]@{Kind='official-github-tag';Url=$url;Path=$null;Raw=$raw;Sha256=(Get-BytesSha256 $bytes)}
}

function Get-CatalogSource([string]$CatalogFile,[string]$Version){if(-not[string]::IsNullOrWhiteSpace($CatalogFile)){if(-not(Test-IsFullyQualifiedWindowsPath $CatalogFile)){throw '--catalog-file must be a fully qualified absolute path'};return [pscustomobject]@{Kind='local-file';Url=$null;Path=(Get-AbsolutePath $CatalogFile);Raw=$null;Sha256=$null}};return Download-OfficialCatalog $Version}
function Read-CatalogSource($Source){if($Source.Kind -eq 'local-file'){return Read-CatalogFile $Source.Path};return ConvertFrom-CatalogJson $Source.Raw $Source.Sha256}

function Acquire-Lock([string]$CodexRoot, [string]$RequestedNonce = $null){
    if($RequestedNonce){Assert-OperationNonce $RequestedNonce 'requested lock nonce'}
    $path=Assert-SafeOwnedPath $CodexRoot (Join-Path $CodexRoot 'provider-compat.lock')
    $nonce=if($RequestedNonce){$RequestedNonce}else{[guid]::NewGuid().ToString('N')}
    if(Test-Path -LiteralPath $path){
        $item=Get-Item -LiteralPath $path -Force
        if(($item.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){throw 'lock is a reparse point'}
        $parsed=$false;$old=$null
        try{$raw=[IO.File]::ReadAllText($path,[Text.Encoding]::UTF8);$old=$raw|ConvertFrom-Json;$parsed=$true}catch{}
        if(-not$parsed){
            if(([DateTime]::UtcNow-$item.LastWriteTimeUtc).TotalMinutes-lt5){throw 'provider-compat lock is unreadable and may still be active'}
        }else{
            if(-not$old.pid-or-not$old.created_at){throw 'invalid lock metadata'}
            try{$created=[DateTimeOffset]::Parse([string]$old.created_at)}catch{throw 'invalid lock timestamp'}
            $process=Get-Process -Id ([int]$old.pid) -ErrorAction SilentlyContinue
            if($process){throw 'another provider-compat process holds the lock'}
            $oldNonce=[string]$old.nonce
            if($oldNonce){
                Assert-OperationNonce $oldNonce 'stale lock nonce'
                if($RequestedNonce-and-not$oldNonce.Equals($RequestedNonce,[StringComparison]::Ordinal)){throw 'stale lock nonce does not match the transaction journal'}
                if(-not(Test-Path -LiteralPath (Get-TransactionPath $CodexRoot))){Remove-AtomicTemp $CodexRoot (Get-TransactionPath $CodexRoot) $oldNonce}
            }elseif(([DateTimeOffset]::UtcNow-$created).TotalMinutes-lt30){throw 'legacy lock metadata is too recent to reclaim safely'}
        }
        [IO.File]::Delete($path)
    }
    $stream=[IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{$payload=([ordered]@{schema_version=1;pid=$PID;nonce=$nonce;created_at=[DateTimeOffset]::Now.ToString('o')}|ConvertTo-Json -Compress);$bytes=[Text.Encoding]::UTF8.GetBytes($payload);$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
    return [pscustomobject]@{Path=$path;Nonce=$nonce}
}

function Release-Lock($Lock){if(-not $Lock){return};try{if(Test-Path -LiteralPath $Lock.Path){$raw=[IO.File]::ReadAllText($Lock.Path,[Text.Encoding]::UTF8);$current=$raw|ConvertFrom-Json;if([string]$current.nonce -eq [string]$Lock.Nonce){[IO.File]::Delete($Lock.Path)}}}catch{Write-Warn 'lock ownership changed or lock metadata is unreadable; preserved the lock'} }

function Assert-BackupPath([string]$CodexRoot,[string]$Path,[string]$Pattern,[string]$Label,[bool]$AllowNull=$false){if($AllowNull -and [string]::IsNullOrEmpty($Path)){return};$safe=Assert-SafeOwnedPath $CodexRoot $Path;if(-not(Test-PathEqual (Split-Path -Parent $safe) $CodexRoot)){throw "$Label must be directly inside Codex home"};if([IO.Path]::GetFileName($safe) -notmatch $Pattern){throw "$Label has an invalid filename"}}

function Assert-JsonObject($Value,[string]$Label){
    if($null -eq $Value -or ($Value -isnot [Collections.IDictionary] -and $Value -isnot [pscustomobject])){throw "$Label must be a JSON object"}
}
function Assert-JsonBoolean($Value,[string]$Label){if($Value -isnot [bool]){throw "$Label must be a JSON boolean"}}
function Assert-JsonString($Value,[string]$Label,[bool]$AllowEmpty=$true){if($Value -isnot [string] -or (-not$AllowEmpty -and $Value.Length-eq0)){throw "$Label must be a JSON string"}}
function Assert-JsonInteger($Value,[string]$Label){
    if($null -eq $Value -or $Value -is [bool]){throw "$Label must be a JSON integer"}
    $integerCodes=@([TypeCode]::SByte,[TypeCode]::Byte,[TypeCode]::Int16,[TypeCode]::UInt16,[TypeCode]::Int32,[TypeCode]::UInt32,[TypeCode]::Int64,[TypeCode]::UInt64)
    if($integerCodes -notcontains [Type]::GetTypeCode($Value.GetType())){throw "$Label must be a JSON integer"}
}
function Assert-JsonArray($Value,[string]$Label){if($Value -isnot [Array]){throw "$Label must be a JSON array"}}
function Assert-JsonNull($Value,[string]$Label){if($null -ne $Value){throw "$Label must be null"}}
function Assert-JsonTimestamp($Value,[string]$Label){Assert-JsonString $Value $Label $false;try{[DateTimeOffset]::Parse($Value)|Out-Null}catch{throw "$Label must be a timestamp string"}}

function ConvertFrom-CompatJson([string]$Json){
    $command=Get-Command ConvertFrom-Json
    if($command.Parameters.ContainsKey('DateKind')){return $Json|ConvertFrom-Json -DateKind String}
    return $Json|ConvertFrom-Json
}

function Assert-MapKeys($Map,[string[]]$Expected,[string]$Label){
    Assert-JsonObject $Map $Label
    if($Map -is [Collections.IDictionary]){$actual=@($Map.Keys)}else{$actual=@($Map.PSObject.Properties.Name)}
    $actualText=@($actual|Sort-Object)-join',';$expectedText=@($Expected|Sort-Object)-join','
    if(-not $actualText.Equals($expectedText,[StringComparison]::Ordinal)){throw "$Label fields do not match schema 1"}
}

function Assert-RestoreLiteral([string]$Literal,[string]$Key,$ExpectedValue){
    if($null -eq $Literal -or $Literal.Contains("`r") -or $Literal.Contains("`n")){throw "state contains an unsafe previous $Key literal"}
    $analysis=Get-ConfigAnalysisFromText '<state-literal>' $true "$Key = $Literal" $false "`n" $null $null
    if($analysis.Keys[$Key].Count -ne 1 -or -not([string]$analysis.Keys[$Key][0].Value).Equals([string]$ExpectedValue,[StringComparison]::Ordinal)){throw "state previous $Key literal does not match its recorded value"}
}

function Assert-ValidState([string]$CodexRoot,$State){
    Assert-MapKeys $State @('schema_version','patch_version','patch_id','codex_version','source_catalog','generated_catalog','config','cache','other_lite_models','applied_at') 'state'
    Assert-MapKeys $State.source_catalog @('kind','url','path','sha256','model_count') 'state source_catalog'
    Assert-MapKeys $State.generated_catalog @('path','sha256') 'state generated_catalog'
    Assert-MapKeys $State.config @('path','backup_path','before_sha256','existed','had_bom','newline','original_mode','previous_model_catalog_json_present','previous_model_catalog_json','previous_model_catalog_json_literal','web_search_modified','previous_web_search_present','previous_web_search','previous_web_search_literal') 'state config'
    Assert-MapKeys $State.cache @('original_path','backup_path','sha256') 'state cache'
    Assert-JsonInteger $State.schema_version 'state schema_version';if($State.schema_version-ne1){throw 'state schema_version is not supported'}
    Assert-JsonString $State.patch_version 'state patch_version' $false;if($State.patch_version-notmatch '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$'){throw 'state patch_version is invalid'}
    Assert-JsonString $State.patch_id 'state patch_id' $false;if($State.patch_id-ne$script:PatchId){throw 'state patch_id is not supported'}
    Assert-JsonString $State.codex_version 'state codex_version' $false;$version=$State.codex_version;if($version-notmatch '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$'){throw 'state has an invalid Codex version'}
    Assert-JsonString $State.applied_at 'state applied_at' $false;Assert-JsonTimestamp $State.applied_at 'state applied_at'
    Assert-JsonArray $State.other_lite_models 'state other_lite_models';foreach($slug in @($State.other_lite_models)){Assert-JsonString $slug 'state other_lite_models item' $false}
    Assert-JsonString $State.source_catalog.kind 'state source_catalog.kind' $false;if($State.source_catalog.kind-notin@('local-file','official-github-tag')){throw 'state source catalog kind is invalid'}
    Assert-JsonString $State.source_catalog.sha256 'state source_catalog.sha256' $false;Assert-HashString $State.source_catalog.sha256 'source catalog hash'
    Assert-JsonInteger $State.source_catalog.model_count 'state source_catalog.model_count';if($State.source_catalog.model_count-lt$script:MinCatalogModels){throw 'state source catalog model_count is too small'}
    if($State.source_catalog.kind-eq'official-github-tag'){
        Assert-JsonNull $State.source_catalog.path 'state official source path';Assert-JsonString $State.source_catalog.url 'state official source URL' $false
        $expectedUrl="https://raw.githubusercontent.com/openai/codex/rust-v$version/codex-rs/models-manager/models.json";if($State.source_catalog.url-ne$expectedUrl){throw 'state official source URL is invalid'}
    }else{
        Assert-JsonNull $State.source_catalog.url 'state local source URL';Assert-JsonString $State.source_catalog.path 'state local source path' $false
    }
    Assert-JsonString $State.generated_catalog.path 'state generated catalog path' $false;Assert-JsonString $State.generated_catalog.sha256 'state generated catalog hash' $false;Assert-HashString $State.generated_catalog.sha256 'generated catalog hash'
    Assert-JsonString $State.config.path 'state config path' $false;Assert-JsonBoolean $State.config.existed 'state config.existed';Assert-JsonBoolean $State.config.had_bom 'state config.had_bom';Assert-JsonString $State.config.newline 'state config.newline' $false;if($State.config.newline-notin@('lf','crlf')){throw 'state config newline is invalid'}
    if($null-ne$State.config.original_mode){Assert-JsonString $State.config.original_mode 'state config.original_mode' $false;if($State.config.original_mode-notmatch '^[0-7]{3,4}$'){throw 'state config original_mode is invalid'}}
    foreach($flag in @('previous_model_catalog_json_present','web_search_modified','previous_web_search_present')){Assert-JsonBoolean $State.config.$flag "state config.$flag"}
    Assert-JsonString $State.cache.original_path 'state cache original path' $false
    $expectedConfig=Join-Path $CodexRoot 'config.toml';$expectedCatalog=Join-Path (Join-Path $CodexRoot 'model-catalogs') "models-$version.standard-responses-compat.json";$expectedCache=Join-Path $CodexRoot 'models_cache.json'
    Assert-ExpectedPath $State.config.path $expectedConfig 'state config path';Assert-SafeOwnedPath $CodexRoot $expectedConfig|Out-Null
    Assert-ExpectedPath $State.generated_catalog.path $expectedCatalog 'state generated catalog path';Assert-SafeOwnedPath $CodexRoot $expectedCatalog|Out-Null
    Assert-ExpectedPath $State.cache.original_path $expectedCache 'state cache path';Assert-SafeOwnedPath $CodexRoot $expectedCache|Out-Null
    if($State.config.existed){Assert-JsonString $State.config.backup_path 'state config backup path' $false;Assert-HashString $State.config.before_sha256 'config before hash';Assert-BackupPath $CodexRoot $State.config.backup_path '^config\.toml\.bak-provider-compat-\d{8}-\d{6}(?:\.\d+)?$' 'config backup'}else{Assert-JsonNull $State.config.backup_path 'state config backup path';Assert-JsonNull $State.config.before_sha256 'state config before hash'}
    if($State.config.previous_model_catalog_json_present){Assert-JsonString $State.config.previous_model_catalog_json 'state previous model_catalog_json';Assert-JsonString $State.config.previous_model_catalog_json_literal 'state previous model_catalog_json literal';Assert-RestoreLiteral $State.config.previous_model_catalog_json_literal 'model_catalog_json' $State.config.previous_model_catalog_json}else{Assert-JsonNull $State.config.previous_model_catalog_json 'state previous model_catalog_json';Assert-JsonNull $State.config.previous_model_catalog_json_literal 'state previous model_catalog_json literal'}
    if($State.config.previous_web_search_present){Assert-JsonString $State.config.previous_web_search 'state previous web_search';Assert-JsonString $State.config.previous_web_search_literal 'state previous web_search literal';Assert-RestoreLiteral $State.config.previous_web_search_literal 'web_search' $State.config.previous_web_search}else{Assert-JsonNull $State.config.previous_web_search 'state previous web_search';Assert-JsonNull $State.config.previous_web_search_literal 'state previous web_search literal'}
    if($null-eq$State.cache.backup_path){Assert-JsonNull $State.cache.sha256 'state cache hash'}else{Assert-JsonString $State.cache.backup_path 'state cache backup path' $false;Assert-HashString $State.cache.sha256 'cache hash';Assert-BackupPath $CodexRoot $State.cache.backup_path '^models_cache\.json\.bak-provider-compat-\d{8}-\d{6}(?:\.\d+)?$' 'cache backup'}
}

function Read-State([string]$CodexRoot){$path=Assert-SafeOwnedPath $CodexRoot (Join-Path $CodexRoot 'provider-compat-state.json');if(-not(Test-Path -LiteralPath $path -PathType Leaf)){return $null};try{$state=ConvertFrom-CompatJson ([IO.File]::ReadAllText($path,[Text.Encoding]::UTF8))}catch{throw "state file is corrupt: $($_.Exception.Message)"};Assert-ValidState $CodexRoot $state;return $state}

function Get-TransactionPath([string]$CodexRoot){return Assert-SafeOwnedPath $CodexRoot (Join-Path $CodexRoot 'provider-compat-transaction.json')}

function Assert-ValidTransaction([string]$CodexRoot,$Transaction){
    Assert-MapKeys $Transaction @('schema_version','operation','phase','nonce','created_at','updated_at','codex_version','root','paths','hashes','flags') 'transaction top level'
    Assert-MapKeys $Transaction.paths @('config','config_backup','config_snapshot','generated_catalog','generated_catalog_pending','cache_original','cache_backup','state','state_archive') 'transaction paths'
    Assert-MapKeys $Transaction.hashes @('config_before','config_after','generated_catalog','cache','state') 'transaction hashes'
    Assert-MapKeys $Transaction.flags @('config_existed','config_should_delete','generated_catalog_owned','cache_should_restore') 'transaction flags'
    Assert-JsonInteger $Transaction.schema_version 'transaction schema_version';if($Transaction.schema_version-ne1){throw 'transaction schema_version is not supported'}
    Assert-JsonString $Transaction.operation 'transaction operation' $false;if($Transaction.operation-notin@('apply','rollback')){throw 'transaction operation is invalid'}
    Assert-JsonString $Transaction.phase 'transaction phase' $false;Assert-JsonString $Transaction.nonce 'transaction nonce' $false;if($Transaction.nonce-notmatch '^[0-9a-f]{32}$'){throw 'transaction nonce is invalid'}
    Assert-JsonTimestamp $Transaction.created_at 'transaction created_at';if($null-eq$Transaction.updated_at){}else{Assert-JsonTimestamp $Transaction.updated_at 'transaction updated_at'}
    Assert-JsonString $Transaction.codex_version 'transaction codex_version' $false;if($Transaction.codex_version-notmatch '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$'){throw 'transaction Codex version is invalid'}
    Assert-JsonString $Transaction.root 'transaction root' $false;Assert-ExpectedPath $Transaction.root $CodexRoot 'transaction root';Assert-CodexHomeSafe $Transaction.root|Out-Null
    $nonce=$Transaction.nonce;$paths=$Transaction.paths;$hashes=$Transaction.hashes;$flags=$Transaction.flags
    foreach($name in @('config','generated_catalog','cache_original','state')){Assert-JsonString $paths.$name "transaction path $name" $false}
    foreach($name in @('config_backup','config_snapshot','generated_catalog_pending','cache_backup','state_archive')){if($null-ne$paths.$name){Assert-JsonString $paths.$name "transaction path $name" $false}}
    foreach($name in @('config_before','config_after','generated_catalog','cache','state')){Assert-HashString $hashes.$name "transaction hash $name" $true}
    foreach($name in @('config_existed','config_should_delete','generated_catalog_owned','cache_should_restore')){Assert-JsonBoolean $flags.$name "transaction flag $name"}
    Assert-ExpectedPath $paths.config (Join-Path $CodexRoot 'config.toml') 'transaction config path';Assert-ExpectedPath $paths.state (Join-Path $CodexRoot 'provider-compat-state.json') 'transaction state path';Assert-ExpectedPath $paths.cache_original (Join-Path $CodexRoot 'models_cache.json') 'transaction cache path'
    foreach($p in @($paths.config,$paths.state,$paths.cache_original)){Assert-SafeOwnedPath $CodexRoot $p|Out-Null}
    if($Transaction.operation -eq 'apply'){
        $version=$Transaction.codex_version;Assert-ExpectedPath $paths.generated_catalog (Join-Path (Join-Path $CodexRoot 'model-catalogs') "models-$version.standard-responses-compat.json") 'transaction generated catalog path';Assert-SafeOwnedPath $CodexRoot $paths.generated_catalog|Out-Null
        if($flags.config_existed){if($null-eq$paths.config_backup){throw 'apply transaction config backup is missing'};Assert-BackupPath $CodexRoot $paths.config_backup '^config\.toml\.bak-provider-compat-\d{8}-\d{6}(?:\.\d+)?$' 'transaction config backup';Assert-HashString $hashes.config_before 'apply config_before hash'}else{Assert-JsonNull $paths.config_backup 'apply transaction config backup';Assert-JsonNull $hashes.config_before 'apply transaction config_before hash'}
        if($null-eq$paths.cache_backup){Assert-JsonNull $hashes.cache 'apply transaction cache hash'}else{Assert-BackupPath $CodexRoot $paths.cache_backup '^models_cache\.json\.bak-provider-compat-\d{8}-\d{6}(?:\.\d+)?$' 'transaction cache backup';Assert-HashString $hashes.cache 'apply cache hash'}
        Assert-JsonNull $paths.config_snapshot 'apply transaction config snapshot';Assert-JsonNull $paths.generated_catalog_pending 'apply transaction pending catalog';Assert-JsonNull $paths.state_archive 'apply transaction state archive'
        if($flags.config_should_delete -or $flags.generated_catalog_owned -or $flags.cache_should_restore){throw 'apply transaction flags are invalid'}
        Assert-HashString $hashes.config_after 'apply config_after hash';Assert-HashString $hashes.generated_catalog 'apply generated catalog hash';Assert-HashString $hashes.state 'apply state hash'
        if($Transaction.phase -notin @('prepared','config-backed-up','generated-catalog-written','cache-backed-up','config-written','state-written')){throw 'apply transaction phase is invalid'}
    }else{
        $version=$Transaction.codex_version
        $expectedCatalog=Join-Path (Join-Path $CodexRoot 'model-catalogs') "models-$version.standard-responses-compat.json"
        Assert-ExpectedPath $paths.generated_catalog $expectedCatalog 'rollback transaction generated catalog path';Assert-ExpectedPath $paths.generated_catalog_pending "$expectedCatalog.rollback-pending-$nonce" 'rollback transaction pending catalog path'
        Assert-SafeOwnedPath $CodexRoot $paths.generated_catalog|Out-Null;Assert-SafeOwnedPath $CodexRoot $paths.generated_catalog_pending|Out-Null
        Assert-ExpectedPath $paths.config_snapshot (Join-Path $CodexRoot ".provider-compat-rollback-$nonce.config") 'transaction config snapshot';Assert-SafeOwnedPath $CodexRoot $paths.config_snapshot|Out-Null
        Assert-JsonNull $paths.config_backup 'rollback transaction config backup';if($null-ne$paths.cache_backup){Assert-BackupPath $CodexRoot $paths.cache_backup '^models_cache\.json\.bak-provider-compat-\d{8}-\d{6}(?:\.\d+)?$' 'transaction cache backup'};Assert-BackupPath $CodexRoot $paths.state_archive '^provider-compat-state\.json\.rolled-back-\d{8}-\d{6}(?:\.\d+)?$' 'transaction state archive'
        if(-not$flags.config_existed){throw 'rollback transaction must begin with an existing config'}
        Assert-HashString $hashes.config_before 'rollback config_before hash';Assert-HashString $hashes.state 'rollback state hash';if($flags.generated_catalog_owned){Assert-HashString $hashes.generated_catalog 'rollback generated catalog hash'}
        if($null-eq$paths.cache_backup){Assert-JsonNull $hashes.cache 'rollback cache hash'}else{Assert-HashString $hashes.cache 'rollback cache hash'};if($flags.cache_should_restore-and$null-eq$paths.cache_backup){throw 'rollback cache restore flag requires a cache backup'}
        if($flags.config_should_delete){Assert-JsonNull $hashes.config_after 'rollback config_after hash'}else{Assert-HashString $hashes.config_after 'rollback config_after hash'}
        if($Transaction.phase -notin @('prepared','config-snapshotted','generated-catalog-pending','cache-restored','config-written','state-archived')){throw 'rollback transaction phase is invalid'}
    }
}

function Read-Transaction([string]$CodexRoot){$path=Get-TransactionPath $CodexRoot;if(-not(Test-Path -LiteralPath $path -PathType Leaf)){return $null};try{$transaction=ConvertFrom-CompatJson ([IO.File]::ReadAllText($path,[Text.Encoding]::UTF8))}catch{throw "transaction journal is corrupt: $($_.Exception.Message)"};Assert-ValidTransaction $CodexRoot $transaction;return $transaction}
function Write-Transaction([string]$CodexRoot,$Transaction,[bool]$SuppressFault=$false){Assert-ValidTransaction $CodexRoot $Transaction;Write-AtomicText $CodexRoot (Get-TransactionPath $CodexRoot) (($Transaction|ConvertTo-Json -Depth 12)+"`n") $false ([string]$Transaction.nonce) $SuppressFault}
function Set-TransactionPhase([string]$CodexRoot,$Transaction,[string]$Phase){$Transaction.phase=$Phase;$Transaction.updated_at=[DateTimeOffset]::Now.ToString('o');Write-Transaction $CodexRoot $Transaction}

function Remove-VerifiedOwnedFile([string]$CodexRoot,[string]$Path,[string]$ExpectedHash){$safe=Assert-SafeOwnedPath $CodexRoot $Path;if(-not(Test-Path -LiteralPath $safe)){return};if($ExpectedHash -and (Get-Sha256 $safe) -ne $ExpectedHash.ToUpperInvariant()){throw "refusing to remove a drifted tool-owned file: $safe"};[IO.File]::Delete($safe)}

function Remove-TransactionAtomicTemps([string]$CodexRoot,$Transaction){
    Assert-ValidTransaction $CodexRoot $Transaction
    $destinations=New-Object 'Collections.Generic.List[string]'
    foreach($candidate in @((Get-TransactionPath $CodexRoot),[string]$Transaction.paths.config,[string]$Transaction.paths.generated_catalog,[string]$Transaction.paths.state)){
        if([string]::IsNullOrWhiteSpace($candidate)){continue}
        $alreadyPresent=$false
        foreach($existing in $destinations){if(Test-PathEqual $existing $candidate){$alreadyPresent=$true;break}}
        if(-not$alreadyPresent){$destinations.Add((Assert-SafeOwnedPath $CodexRoot $candidate))}
    }
    foreach($destination in $destinations){Remove-AtomicTemp $CodexRoot $destination ([string]$Transaction.nonce)}
}

function Recover-ApplyTransaction([string]$CodexRoot,$Transaction,[bool]$PreferRestore=$false){
    $paths=$Transaction.paths;$hashes=$Transaction.hashes
    $stateComplete=$false
    if(Test-Path -LiteralPath $paths.state){try{$state=Read-State $CodexRoot;$stateComplete=(Get-Sha256 $paths.state)-eq([string]$hashes.state).ToUpperInvariant() -and (Get-Sha256 $paths.generated_catalog)-eq([string]$hashes.generated_catalog).ToUpperInvariant() -and (Get-Sha256 $paths.config)-eq([string]$hashes.config_after).ToUpperInvariant()}catch{$stateComplete=$false}}
    if($stateComplete-and-not$PreferRestore){Remove-VerifiedOwnedFile $CodexRoot (Get-TransactionPath $CodexRoot) $null;return 'committed'}
    if(Test-Path -LiteralPath $paths.state){Remove-VerifiedOwnedFile $CodexRoot $paths.state ([string]$hashes.state)}
    $currentConfig=Get-Sha256 $paths.config
    $configMayHaveBeenWritten=$Transaction.phase -in @('config-written','state-written') -or ($currentConfig -and $currentConfig -eq([string]$hashes.config_after).ToUpperInvariant())
    if([bool]$Transaction.flags.config_existed){
        $backupExists=Test-Path -LiteralPath $paths.config_backup
        if(-not $backupExists -and $Transaction.phase -ne 'prepared'){throw 'cannot recover apply: config backup is missing'}
        if($backupExists -and (Get-Sha256 $paths.config_backup)-ne([string]$hashes.config_before).ToUpperInvariant()){if($Transaction.phase-eq'prepared'){[IO.File]::Delete((Assert-SafeOwnedPath $CodexRoot $paths.config_backup));$backupExists=$false}else{throw 'cannot recover apply: config backup drifted'}}
        if($currentConfig -ne([string]$hashes.config_before).ToUpperInvariant() -and $configMayHaveBeenWritten){if($currentConfig -and $currentConfig -ne([string]$hashes.config_after).ToUpperInvariant()){throw 'cannot recover apply: config changed after tool write'};if(-not $backupExists){throw 'cannot recover apply: config changed but its backup is missing'};Write-AtomicBytes $CodexRoot $paths.config ([IO.File]::ReadAllBytes($paths.config_backup)) ([string]$Transaction.nonce) $true}
    }elseif($currentConfig -and $configMayHaveBeenWritten){if($currentConfig -ne([string]$hashes.config_after).ToUpperInvariant()){throw 'cannot recover apply: newly created config changed after tool write'};[IO.File]::Delete((Assert-SafeOwnedPath $CodexRoot $paths.config))}
    if($paths.cache_backup -and (Test-Path -LiteralPath $paths.cache_backup)){if(Test-Path -LiteralPath $paths.cache_original){throw 'cannot recover apply: both original and backup cache exist'};if((Get-Sha256 $paths.cache_backup)-ne([string]$hashes.cache).ToUpperInvariant()){throw 'cannot recover apply: cache backup drifted'};[IO.File]::Move($paths.cache_backup,$paths.cache_original)}
    if(Test-Path -LiteralPath $paths.generated_catalog){Remove-VerifiedOwnedFile $CodexRoot $paths.generated_catalog ([string]$hashes.generated_catalog)}
    if($paths.config_backup -and (Test-Path -LiteralPath $paths.config_backup)){Remove-VerifiedOwnedFile $CodexRoot $paths.config_backup ([string]$hashes.config_before)}
    Remove-VerifiedOwnedFile $CodexRoot (Get-TransactionPath $CodexRoot) $null
    return 'restored'
}

function Recover-RollbackTransaction([string]$CodexRoot,$Transaction,[bool]$PreferRestore=$false){
    $p=$Transaction.paths;$h=$Transaction.hashes
    $archiveComplete=(Test-Path -LiteralPath $p.state_archive) -and -not(Test-Path -LiteralPath $p.state) -and (Get-Sha256 $p.state_archive)-eq([string]$h.state).ToUpperInvariant()
    if($archiveComplete-and-not$PreferRestore){if(Test-Path -LiteralPath $p.generated_catalog_pending){Remove-VerifiedOwnedFile $CodexRoot $p.generated_catalog_pending ([string]$h.generated_catalog)};if(Test-Path -LiteralPath $p.config_snapshot){Remove-VerifiedOwnedFile $CodexRoot $p.config_snapshot ([string]$h.config_before)};Remove-VerifiedOwnedFile $CodexRoot (Get-TransactionPath $CodexRoot) $null;return 'committed'}
    if(Test-Path -LiteralPath $p.state_archive){if(Test-Path -LiteralPath $p.state){throw 'cannot recover rollback: state and archive both exist'};if((Get-Sha256 $p.state_archive)-ne([string]$h.state).ToUpperInvariant()){throw 'cannot recover rollback: state archive drifted'};[IO.File]::Move($p.state_archive,$p.state)}
    $configHash=Get-Sha256 $p.config
    $configMayHaveBeenWritten=$Transaction.phase -in @('config-written','state-archived') -or (($h.config_after -and $configHash -eq([string]$h.config_after).ToUpperInvariant()) -or (-not $h.config_after -and -not $configHash))
    if($configHash -ne([string]$h.config_before).ToUpperInvariant() -and $configMayHaveBeenWritten){
        $after=[string]$h.config_after;if(($after -and $configHash -ne $after.ToUpperInvariant()) -or (-not $after -and $configHash)){throw 'cannot recover rollback: config changed after interruption'}
        if(-not(Test-Path -LiteralPath $p.config_snapshot) -or (Get-Sha256 $p.config_snapshot)-ne([string]$h.config_before).ToUpperInvariant()){throw 'cannot recover rollback: config snapshot is missing or drifted'}
        Write-AtomicBytes $CodexRoot $p.config ([IO.File]::ReadAllBytes($p.config_snapshot)) ([string]$Transaction.nonce) $true
    }
    if([bool]$Transaction.flags.cache_should_restore -and (Test-Path -LiteralPath $p.cache_original) -and -not(Test-Path -LiteralPath $p.cache_backup)){if((Get-Sha256 $p.cache_original)-ne([string]$h.cache).ToUpperInvariant()){throw 'cannot recover rollback: restored cache changed'};[IO.File]::Move($p.cache_original,$p.cache_backup)}
    if(Test-Path -LiteralPath $p.generated_catalog_pending){if(Test-Path -LiteralPath $p.generated_catalog){throw 'cannot recover rollback: catalog and pending catalog both exist'};if((Get-Sha256 $p.generated_catalog_pending)-ne([string]$h.generated_catalog).ToUpperInvariant()){throw 'cannot recover rollback: pending catalog drifted'};[IO.File]::Move($p.generated_catalog_pending,$p.generated_catalog)}
    if(Test-Path -LiteralPath $p.config_snapshot){$snapshotHash=Get-Sha256 $p.config_snapshot;if($Transaction.phase-eq'prepared'-and$snapshotHash-ne([string]$h.config_before).ToUpperInvariant()){Remove-VerifiedOwnedFile $CodexRoot $p.config_snapshot $null}else{Remove-VerifiedOwnedFile $CodexRoot $p.config_snapshot ([string]$h.config_before)}}
    Remove-VerifiedOwnedFile $CodexRoot (Get-TransactionPath $CodexRoot) $null
    return 'restored'
}

function Recover-Transaction([string]$CodexRoot,$Transaction,[bool]$PreferRestore=$false){$oldFail=$env:CODEX_PROVIDER_COMPAT_TEST_FAIL_STAGE;$oldCrash=$env:CODEX_PROVIDER_COMPAT_TEST_CRASH_STAGE;$oldPause=$env:CODEX_PROVIDER_COMPAT_TEST_PAUSE_STAGE;$env:CODEX_PROVIDER_COMPAT_TEST_FAIL_STAGE=$null;$env:CODEX_PROVIDER_COMPAT_TEST_CRASH_STAGE=$null;$env:CODEX_PROVIDER_COMPAT_TEST_PAUSE_STAGE=$null;try{Remove-TransactionAtomicTemps $CodexRoot $Transaction;if($Transaction.operation -eq 'apply'){return Recover-ApplyTransaction $CodexRoot $Transaction $PreferRestore};return Recover-RollbackTransaction $CodexRoot $Transaction $PreferRestore}finally{$env:CODEX_PROVIDER_COMPAT_TEST_FAIL_STAGE=$oldFail;$env:CODEX_PROVIDER_COMPAT_TEST_CRASH_STAGE=$oldCrash;$env:CODEX_PROVIDER_COMPAT_TEST_PAUSE_STAGE=$oldPause}}

function Invoke-PendingRecovery([string]$CodexRoot){$probe=Read-Transaction $CodexRoot;if(-not $probe){return};Write-Warn "recovering interrupted $($probe.operation) transaction";$lock=$null;try{$lock=Acquire-Lock $CodexRoot ([string]$probe.nonce);$transaction=Read-Transaction $CodexRoot;if($transaction){if(-not([string]$transaction.nonce).Equals([string]$lock.Nonce,[StringComparison]::Ordinal)){throw 'recovery lock nonce does not match the transaction journal'};$result=Recover-Transaction $CodexRoot $transaction;Write-Info "transaction_recovery=$result"}}finally{Release-Lock $lock}}

function Test-StateHealth([string]$CodexRoot,$State,[string]$CurrentVersion){
    $problems=New-Object Collections.ArrayList
    try{Assert-ValidState $CodexRoot $State}catch{[void]$problems.Add('state-unsafe');return @($problems)}
    if($CurrentVersion -and $State.codex_version -ne $CurrentVersion){[void]$problems.Add('codex-version-stale')}
    $generated=[string]$State.generated_catalog.path
    if(-not(Test-Path -LiteralPath $generated -PathType Leaf)){[void]$problems.Add('catalog-missing')}
    elseif((Get-Sha256 $generated)-ne([string]$State.generated_catalog.sha256).ToUpperInvariant()){[void]$problems.Add('catalog-hash-drift')}
    else{try{$catalog=Read-CatalogFile $generated;if(-not $catalog.AllTargetsAlreadyFalse){[void]$problems.Add('catalog-target-drift')};if($catalog.ModelCount -ne [int]$State.source_catalog.model_count){[void]$problems.Add('catalog-model-count-drift')};if($catalog.OtherLite.Count){Write-Warn('unverified Lite models (reported only): '+($catalog.OtherLite -join ', '))}}catch{[void]$problems.Add('catalog-invalid')}}
    if([bool]$State.config.existed){$configBackup=[string]$State.config.backup_path;if(-not(Test-Path -LiteralPath $configBackup -PathType Leaf)){[void]$problems.Add('config-backup-missing')}elseif((Get-Sha256 $configBackup)-ne([string]$State.config.before_sha256).ToUpperInvariant()){[void]$problems.Add('config-backup-hash-drift')}}
    if($State.cache.backup_path){$cacheBackup=[string]$State.cache.backup_path;if(-not(Test-Path -LiteralPath $cacheBackup -PathType Leaf)){[void]$problems.Add('cache-backup-missing')}elseif((Get-Sha256 $cacheBackup)-ne([string]$State.cache.sha256).ToUpperInvariant()){[void]$problems.Add('cache-backup-hash-drift')}}
    try{$analysis=Get-ConfigAnalysis (Join-Path $CodexRoot 'config.toml');Assert-NoDuplicateOwnedKeys $analysis;if($analysis.Keys.model_catalog_json.Count-ne1 -or -not([string]$analysis.Keys.model_catalog_json[0].Value).Replace('\','/').Equals($generated.Replace('\','/'),[StringComparison]::OrdinalIgnoreCase)){[void]$problems.Add('config-catalog-drift')};if($State.config.web_search_modified -eq $true -and ($analysis.Keys.web_search.Count-ne1 -or $analysis.Keys.web_search[0].Value-ne'live')){[void]$problems.Add('config-web-search-drift')}}catch{[void]$problems.Add('config-unsafe')}
    return @($problems)
}

function Parse-Arguments([string[]]$InputArgs) {
    if ($InputArgs.Count -lt 1) { throw 'usage: codex-provider-compat.ps1 doctor|apply|status|rollback [options]' }
    $result = [ordered]@{
        Command = $InputArgs[0].ToLowerInvariant()
        Yes = $false
        DryRun = $false
        CodexHome = $null
        CodexHomeSet = $false
        CodexVersion = $null
        CodexVersionSet = $false
        CatalogFile = $null
        CatalogFileSet = $false
    }
    for ($i = 1; $i -lt $InputArgs.Count; $i++) {
        switch ($InputArgs[$i]) {
            '--yes' { $result.Yes = $true }
            '--dry-run' { $result.DryRun = $true }
            '--codex-home' {
                if (++$i -ge $InputArgs.Count) { throw '--codex-home requires a value' }
                $result.CodexHomeSet = $true
                $result.CodexHome = $InputArgs[$i]
            }
            '--codex-version' {
                if (++$i -ge $InputArgs.Count) { throw '--codex-version requires a value' }
                $result.CodexVersionSet = $true
                $result.CodexVersion = $InputArgs[$i]
            }
            '--catalog-file' {
                if (++$i -ge $InputArgs.Count) { throw '--catalog-file requires a value' }
                $result.CatalogFileSet = $true
                $result.CatalogFile = $InputArgs[$i]
            }
            default { throw "unknown argument: $($InputArgs[$i])" }
        }
    }
    if ($result.Command -notin @('doctor','apply','status','rollback')) { throw "unknown command: $($result.Command)" }
    return [pscustomobject]$result
}
function Show-Versions($Versions){foreach($v in $Versions){if($v.Version){Write-Info "version source: $($v.Source) -> $($v.Version) [$($v.Path)]"}else{Write-Warn "version source unresolved: $($v.Source) [$($v.Path)] ($($v.Error))"}}}
function Confirm-Write($Options,[string]$Summary){if($Options.DryRun-or$Options.Yes){return $true};$answer=Read-Host "$Summary Continue? [y/N]";return $answer-match'^(y|yes)$'}
function Test-RecoveryRequired([string]$CodexRoot){try{$transaction=Read-Transaction $CodexRoot}catch{Write-Warn $_.Exception.Message;Write-Info 'result=unsafe';return $true};if($transaction){Write-Warn "interrupted $($transaction.operation) transaction requires recovery; run apply or rollback";Write-Info 'result=recovery-required';return $true};return $false}

function Show-ProfileWarnings([string]$CodexRoot){
    $profileFiles=@();if(Test-Path -LiteralPath $CodexRoot){$profileFiles=@(Get-ChildItem -LiteralPath $CodexRoot -Filter '*.config.toml' -File -ErrorAction SilentlyContinue|Sort-Object Name)}
    Write-Info ('profile_files_found='+$(if($profileFiles.Count){@($profileFiles.Name)-join','}else{'<none>'}))
    foreach($profileFile in $profileFiles){try{$pa=Get-ConfigAnalysis $profileFile.FullName;$overridden=@('model','model_provider','model_catalog_json')|Where-Object{$pa.Keys[$_].Count-gt0};if($overridden.Count-gt0){Write-Warn "profile file can override $($overridden -join ', ') only when selected with --profile: $($profileFile.Name)"}}catch{Write-Warn "profile file could not be safely analyzed and may override runtime configuration if selected: $($profileFile.Name)"}}
}

function Invoke-Doctor($Options,[string]$CodexRoot){
    try{Assert-CodexHomeSafe $CodexRoot|Out-Null}catch{Write-Warn $_.Exception.Message;Write-Info 'result=unsafe';return $script:ExitUnsafe}
    Write-Info "tool_version=$script:ToolVersion patch_id=$script:PatchId";Write-Info "os=$([Environment]::OSVersion.VersionString) codex_home=$CodexRoot"
    if(Test-RecoveryRequired $CodexRoot){return $script:ExitUnsafe}
    $versions=Discover-CodexVersions $CodexRoot;Show-Versions $versions;try{$version=Select-CodexVersion $Options.CodexVersion $versions $false}catch{Write-Warn $_.Exception.Message;Write-Info 'result=unsafe';return $script:ExitUnsafe}
    try{$state=Read-State $CodexRoot}catch{Write-Warn $_.Exception.Message;Write-Info 'result=unsafe';return $script:ExitUnsafe}
    if($state){$health=Test-StateHealth $CodexRoot $state $version;if($health.Count-eq0){Write-Info 'result=already-applied';return $script:ExitSuccess};if($health-contains'codex-version-stale'){Write-Warn('status problems: '+($health-join', '));Write-Info 'result=stale';return $script:ExitStale};Write-Warn('status problems: '+($health-join', '));Write-Info 'result=unsafe';return $script:ExitUnsafe}
    $configPath=Join-Path $CodexRoot 'config.toml';try{$analysis=Get-ConfigAnalysis $configPath;Assert-NoDuplicateOwnedKeys $analysis;foreach($key in @('model','model_provider','model_catalog_json')){if($analysis.Keys[$key].Count-eq1){Write-Info "$key=$($analysis.Keys[$key][0].Value)"}else{Write-Info "$key=<unset>"}}}catch{Write-Warn $_.Exception.Message;Write-Info 'result=unsafe';return $script:ExitUnsafe}
    Show-ProfileWarnings $CodexRoot
    if(-not $version-and-not$Options.CatalogFile){Write-Info 'result=unknown';return $script:ExitUnsafe}
    try{$source=Get-CatalogSource $Options.CatalogFile $version}catch{Write-Warn $_.Exception.Message;Write-Info 'result=unknown';if($Options.CatalogFile){return $script:ExitUnsafe};return $script:ExitNetwork}
    try{$catalog=Read-CatalogSource $source}catch{Write-Warn $_.Exception.Message;if($source.Kind-eq'official-github-tag'){Write-Info 'result=stale';return $script:ExitStale};Write-Info 'result=unsafe';return $script:ExitUnsafe}
    Write-Info "catalog_source=$($source.Kind) models=$($catalog.ModelCount) sha256=$($catalog.SourceSha256)";foreach($target in $script:TargetModels){Write-Info "$target use_responses_lite=$($catalog.OriginalStates[$target])"};if($catalog.OtherLite.Count){Write-Warn('unverified Lite models (reported only): '+($catalog.OtherLite-join', '))};Write-Info 'capability_risk=exec-shell,code-mode,function-mcp,dynamic-tools,collaboration,image-extension,hosted-web-search'
    if($catalog.AllTargetsAlreadyFalse){Write-Info 'result=not-needed';return $script:ExitNotApplicable}
    if($analysis.Keys.model.Count-ne1-or$analysis.Keys.model_provider.Count-ne1){Write-Info 'result=unknown (model or model_provider is unset)';return $script:ExitUnsafe}
    if($analysis.Keys.model[0].Value-notin$script:TargetModels){Write-Info 'result=not-needed (current model is not a verified target)';return $script:ExitNotApplicable}
    $provider=[string]$analysis.Keys.model_provider[0].Value;if($provider-eq'openai'){if($analysis.UnknownTableHeaders){Write-Warn 'could not safely determine whether a table overrides model_providers.openai';Write-Info 'result=unknown';return $script:ExitUnsafe};if($analysis.Keys.openai_base_url.Count-gt0-or$analysis.ModelProvidersOpenAiTable){Write-Warn 'model_provider=openai has a local provider/base URL override; the endpoint cannot be treated as the default official path';Write-Info 'result=unknown';return $script:ExitUnsafe};Write-Info 'result=not-needed (default built-in openai provider path normally supports Responses Lite)';return $script:ExitNotApplicable}
    Write-Info 'result=applicable';return $script:ExitSuccess
}

function Invoke-Status($Options,[string]$CodexRoot){
    try{Assert-CodexHomeSafe $CodexRoot|Out-Null}catch{Write-Warn $_.Exception.Message;return $script:ExitUnsafe};if(Test-RecoveryRequired $CodexRoot){return $script:ExitUnsafe}
    Show-ProfileWarnings $CodexRoot
    try{$state=Read-State $CodexRoot}catch{Write-Warn $_.Exception.Message;Write-Info 'result=unsafe';return $script:ExitUnsafe};if(-not$state){Write-Info 'result=not-applied';return $script:ExitNotApplicable}
    $versions=Discover-CodexVersions $CodexRoot;Show-Versions $versions;try{$version=Select-CodexVersion $Options.CodexVersion $versions $false}catch{Write-Warn $_.Exception.Message;return $script:ExitUnsafe};if(-not$version){Write-Warn 'could not detect the current Codex version; status cannot rule out a stale catalog';Write-Info 'result=unknown';return $script:ExitUnsafe};$problems=Test-StateHealth $CodexRoot $state $version
    if($problems-contains'codex-version-stale'){Write-Warn('status problems: '+($problems-join', '));Write-Info 'result=stale';return $script:ExitStale};if($problems.Count-gt0){Write-Warn('status problems: '+($problems-join', '));Write-Info 'result=unsafe';return $script:ExitUnsafe};Write-Info "result=healthy patch_id=$($state.patch_id) codex_version=$($state.codex_version)";return $script:ExitSuccess
}

function Invoke-Apply($Options,[string]$CodexRoot){
    try{Assert-CodexHomeSafe $CodexRoot|Out-Null}catch{Write-Warn $_.Exception.Message;return $script:ExitUnsafe}
    if($Options.DryRun){if(Test-RecoveryRequired $CodexRoot){return $script:ExitUnsafe}}else{try{Invoke-PendingRecovery $CodexRoot}catch{Write-Warn $_.Exception.Message;return $script:ExitUnsafe}}
    $versions=Discover-CodexVersions $CodexRoot;Show-Versions $versions;try{$version=Select-CodexVersion $Options.CodexVersion $versions $true}catch{Write-Warn $_.Exception.Message;return $script:ExitUnsafe}
    try{$existing=Read-State $CodexRoot}catch{Write-Warn $_.Exception.Message;return $script:ExitUnsafe};if($existing){$problems=Test-StateHealth $CodexRoot $existing $version;if($problems.Count-eq0){Write-Info 'result=already-applied';return $script:ExitSuccess};if($problems.Count-eq1-and$problems-contains'codex-version-stale'){Write-Warn 'existing patch belongs to a different Codex version; run rollback, then apply for the new version';return $script:ExitStale};Write-Warn('existing patch state is not healthy: '+($problems-join', ')+'; rollback before applying again');return $script:ExitUnsafe}
    try{$source=Get-CatalogSource $Options.CatalogFile $version}catch{Write-Warn $_.Exception.Message;if($Options.CatalogFile){return $script:ExitUnsafe};return $script:ExitNetwork}
    try{$catalog=Read-CatalogSource $source}catch{Write-Warn $_.Exception.Message;if($source.Kind-eq'official-github-tag'){return $script:ExitStale};return $script:ExitUnsafe}
    if($catalog.AllTargetsAlreadyFalse){Write-Info 'result=not-needed (official/source catalog already uses standard Responses)';return $script:ExitNotApplicable}
    $configPath=Join-Path $CodexRoot 'config.toml';$catalogDir=Join-Path $CodexRoot 'model-catalogs';$generatedPath=Join-Path $catalogDir "models-$version.standard-responses-compat.json"
    try{Assert-SafeOwnedPath $CodexRoot $configPath|Out-Null;Assert-SafeOwnedPath $CodexRoot $catalogDir|Out-Null;Assert-SafeOwnedPath $CodexRoot $generatedPath|Out-Null;$plan=Get-ConfigPlan $configPath $generatedPath}catch{Write-Warn $_.Exception.Message;return $script:ExitUnsafe}
    Write-Info "plan: generate $generatedPath";Write-Info "plan: backup and update $configPath";if(Test-Path -LiteralPath (Join-Path $CodexRoot 'models_cache.json')){Write-Info 'plan: rename-backup models_cache.json'}
    if($Options.DryRun){Write-Info 'result=dry-run (zero writes)';return $script:ExitSuccess}
    for($attempt=0;$attempt-lt2;$attempt++){
        if(-not(Confirm-Write $Options 'Apply responses-lite-standard-tools?')){Write-Info 'cancelled';return $script:ExitError};Invoke-TestConfigMutation $configPath
        $lock=$null;$interruptScope=$false;$transaction=$null;$commitPointReached=$false
        try{
            $interruptScope=Enter-OperationInterruptScope
            if(-not(Test-Path -LiteralPath $CodexRoot)){[IO.Directory]::CreateDirectory($CodexRoot)|Out-Null};Assert-CodexHomeSafe $CodexRoot|Out-Null;$lock=Acquire-Lock $CodexRoot;Assert-OperationNotCancelled
            if(Read-Transaction $CodexRoot){throw 'another transaction appeared while acquiring the lock'}
            $stateNow=Read-State $CodexRoot;if($stateNow){$health=Test-StateHealth $CodexRoot $stateNow $version;if($health.Count-eq0){Write-Info 'result=already-applied';return $script:ExitSuccess};throw 'patch state appeared while waiting for the lock'}
            $current=Get-ConfigAnalysis $configPath;$fingerprint=if($current.Exists){$current.Sha256}else{'<missing>'}
            if($fingerprint-ne$plan.Fingerprint){if($attempt-eq0){Write-Warn 'config.toml changed after confirmation; rebuilding the plan once';$plan=Get-ConfigPlan $configPath $generatedPath;continue};throw 'config.toml changed repeatedly while applying; refusing to overwrite it'}
            if($current.Exists -and ((Get-Item -LiteralPath $configPath -Force).Attributes -band [IO.FileAttributes]::ReadOnly)){throw 'config.toml is read-only'}
            if(-not(Test-Path -LiteralPath $catalogDir)){[IO.Directory]::CreateDirectory($catalogDir)|Out-Null};Assert-SafeOwnedPath $CodexRoot $catalogDir|Out-Null;if(Test-Path -LiteralPath $generatedPath){throw "generated catalog already exists without a healthy state file: $generatedPath"}
            $stamp=Get-Date -Format 'yyyyMMdd-HHmmss';$nonce=[string]$lock.Nonce;Assert-OperationNonce $nonce 'operation lock nonce';$configBackup=if($plan.Analysis.Exists){Get-UniquePath(Join-Path $CodexRoot "config.toml.bak-provider-compat-$stamp")}else{$null};$cachePath=Join-Path $CodexRoot 'models_cache.json';Assert-SafeOwnedPath $CodexRoot $cachePath|Out-Null;$cacheExists=Test-Path -LiteralPath $cachePath -PathType Leaf;$cacheBackup=if($cacheExists){Get-UniquePath(Join-Path $CodexRoot "models_cache.json.bak-provider-compat-$stamp")}else{$null};$cacheHash=if($cacheExists){Get-Sha256 $cachePath}else{$null}
            $previousCatalog=$plan.Analysis.Keys.model_catalog_json;$configBeforeHash=if($plan.Analysis.Exists){$plan.Analysis.Sha256}else{$null}
            $state=[ordered]@{schema_version=1;patch_version=$script:ToolVersion;patch_id=$script:PatchId;codex_version=$version;source_catalog=[ordered]@{kind=$source.Kind;url=$source.Url;path=if($source.Kind-eq'local-file'){$source.Path}else{$null};sha256=$catalog.SourceSha256;model_count=$catalog.ModelCount};generated_catalog=[ordered]@{path=$generatedPath;sha256=(Get-BytesSha256 $catalog.PatchedBytes)};config=[ordered]@{path=$configPath;backup_path=$configBackup;before_sha256=$configBeforeHash;existed=$plan.Analysis.Exists;had_bom=$plan.Analysis.Bom;newline=if($plan.Analysis.Newline-eq"`r`n"){'crlf'}else{'lf'};original_mode=$null;previous_model_catalog_json_present=($previousCatalog.Count-eq1);previous_model_catalog_json=if($previousCatalog.Count-eq1){$previousCatalog[0].Value}else{$null};previous_model_catalog_json_literal=if($previousCatalog.Count-eq1){$previousCatalog[0].Raw}else{$null};web_search_modified=$false;previous_web_search_present=$false;previous_web_search=$null;previous_web_search_literal=$null};cache=[ordered]@{original_path=$cachePath;backup_path=$cacheBackup;sha256=$cacheHash};other_lite_models=@($catalog.OtherLite);applied_at=[DateTimeOffset]::Now.ToString('o')}
            $stateText=($state|ConvertTo-Json -Depth 12)+"`n";$stateBytes=ConvertTo-Utf8Bytes $stateText $false
            $transaction=[ordered]@{schema_version=1;operation='apply';phase='prepared';nonce=$nonce;created_at=[DateTimeOffset]::Now.ToString('o');updated_at=$null;codex_version=$version;root=$CodexRoot;paths=[ordered]@{config=$configPath;config_backup=$configBackup;config_snapshot=$null;generated_catalog=$generatedPath;generated_catalog_pending=$null;cache_original=$cachePath;cache_backup=$cacheBackup;state=(Join-Path $CodexRoot 'provider-compat-state.json');state_archive=$null};hashes=[ordered]@{config_before=$configBeforeHash;config_after=(Get-BytesSha256 $plan.AfterBytes);generated_catalog=(Get-BytesSha256 $catalog.PatchedBytes);cache=$cacheHash;state=(Get-BytesSha256 $stateBytes)};flags=[ordered]@{config_existed=$plan.Analysis.Exists;config_should_delete=$false;generated_catalog_owned=$false;cache_should_restore=$false}}
            Write-Transaction $CodexRoot ([pscustomobject]$transaction);Invoke-TestFault 'apply-prepared'
            if($configBackup){Copy-VerifiedFileWithAcl $CodexRoot $configPath $configBackup $plan.Analysis.Sha256 'config backup'};Set-TransactionPhase $CodexRoot $transaction 'config-backed-up';Invoke-TestFault 'after-backup'
            Write-AtomicBytes $CodexRoot $generatedPath $catalog.PatchedBytes $nonce;Set-TransactionPhase $CodexRoot $transaction 'generated-catalog-written';Invoke-TestFault 'after-catalog'
            if($cacheBackup){[IO.File]::Move($cachePath,$cacheBackup);if((Get-Sha256 $cacheBackup)-ne$cacheHash){throw 'cache backup verification failed'}};Set-TransactionPhase $CodexRoot $transaction 'cache-backed-up';Invoke-TestFault 'after-cache'
            if($env:CODEX_PROVIDER_COMPAT_TEST_MUTATE_CONFIG_BEFORE_WRITE){[IO.File]::AppendAllText($configPath,"# late-external-change`r`n",(New-Object Text.UTF8Encoding($false)))}
            $immediateConfigHash=Get-Sha256 $configPath;if(($plan.Analysis.Exists-and$immediateConfigHash-ne$plan.Analysis.Sha256)-or(-not$plan.Analysis.Exists-and$immediateConfigHash)){throw 'config.toml changed immediately before the atomic write'}
            Invoke-TestFault 'config-write';Write-AtomicBytes $CodexRoot $configPath $plan.AfterBytes $nonce;if(-not$plan.Analysis.Exists){Set-PrivateFileAcl $configPath};if((Get-Sha256 $configPath)-ne(Get-BytesSha256 $plan.AfterBytes)){throw 'config hash verification failed'};if($plan.Analysis.Exists-and$plan.Analysis.Acl-and-not(Test-PathAclMatchesSddl $configPath $plan.Analysis.Acl)){throw 'config permissions changed unexpectedly'};$check=Get-ConfigAnalysis $configPath;Assert-NoDuplicateOwnedKeys $check;if($check.Keys.model_catalog_json.Count-ne1-or-not([string]$check.Keys.model_catalog_json[0].Value).Replace('\','/').Equals($generatedPath.Replace('\','/'),[StringComparison]::OrdinalIgnoreCase)){throw 'config verification failed'};Set-TransactionPhase $CodexRoot $transaction 'config-written';Invoke-TestFault 'after-config'
            Invoke-TestFault 'state-write';Write-AtomicBytes $CodexRoot $transaction.paths.state $stateBytes $nonce;Read-State $CodexRoot|Out-Null;Set-TransactionPhase $CodexRoot $transaction 'state-written';Invoke-TestFault 'after-state';Assert-OperationNotCancelled;$commitPointReached=$true;Invoke-TestFault 'apply-committed-before-cleanup'
            Remove-VerifiedOwnedFile $CodexRoot (Get-TransactionPath $CodexRoot) $null;Write-Info 'result=applied';Write-Info '完全退出并重新启动 Codex，然后新建任务/新 thread。';Write-Info '旧任务保留启动时的模型与工具快照，不会自动应用本次更改。';return $script:ExitSuccess
        }catch{
            $message=$_.Exception.Message;$wasInterrupted=[ProviderCompatNative]::CancellationRequested;$recovery=$null;$transaction=$null
            $preferRestore=$wasInterrupted-and-not$commitPointReached
            try{$transaction=Read-Transaction $CodexRoot;if($transaction){$recovery=Recover-Transaction $CodexRoot $transaction $preferRestore;if($recovery-eq'committed'){Write-Warn "apply completed during recovery after: $message";Write-Info 'result=applied';Write-Info '完全退出并重新启动 Codex，然后新建任务/新 thread。';Write-Info '旧任务保留启动时的模型与工具快照，不会自动应用本次更改。';return $script:ExitSuccess}}}catch{Write-Warn "automatic transaction recovery failed: $($_.Exception.Message)"}
            if($wasInterrupted){if($recovery-eq'restored'-or-not$transaction){Write-Info 'result=interrupted-restored'};Write-Warn "apply interrupted safely: $message";return $script:ExitUnsafe}
            if($attempt-eq0-and$message-like'config.toml changed after confirmation*'){continue};Write-Warn "apply failed safely: $message";return $script:ExitUnsafe
        }finally{Release-Lock $lock;if($interruptScope){Exit-OperationInterruptScope}}
    }
    return $script:ExitUnsafe
}

function Get-RollbackText($State,$Analysis){
    $catalogRestoreLiteral=if([bool]$State.config.previous_model_catalog_json_present){[string]$State.config.previous_model_catalog_json_literal}else{$null}
    $text=Set-ConfigKey $Analysis 'model_catalog_json' $catalogRestoreLiteral (-not[bool]$State.config.previous_model_catalog_json_present)
    if($State.config.web_search_modified-eq$true){
        $next=Get-ConfigAnalysisFromText $Analysis.Path $true $text $Analysis.Bom $Analysis.Newline $null $Analysis.Acl
        $webRestoreLiteral=if([bool]$State.config.previous_web_search_present){[string]$State.config.previous_web_search_literal}else{$null}
        $text=Set-ConfigKey $next 'web_search' $webRestoreLiteral (-not[bool]$State.config.previous_web_search_present)
    }
    return $text
}

function Invoke-Rollback($Options,[string]$CodexRoot){
    try{Assert-CodexHomeSafe $CodexRoot|Out-Null}catch{Write-Warn $_.Exception.Message;return $script:ExitUnsafe}
    if($Options.DryRun){if(Test-RecoveryRequired $CodexRoot){return $script:ExitUnsafe}}else{try{Invoke-PendingRecovery $CodexRoot}catch{Write-Warn $_.Exception.Message;return $script:ExitUnsafe}}
    try{$state=Read-State $CodexRoot}catch{Write-Warn $_.Exception.Message;return $script:ExitUnsafe};if(-not$state){Write-Info 'result=not-applied';return $script:ExitNotApplicable}
    $statePath=Join-Path $CodexRoot 'provider-compat-state.json';$stateHash=Get-Sha256 $statePath;$configPath=Join-Path $CodexRoot 'config.toml'
    try{$analysis=Get-ConfigAnalysis $configPath;Assert-NoDuplicateOwnedKeys $analysis;$generated=[string]$state.generated_catalog.path;if($analysis.Keys.model_catalog_json.Count-ne1-or-not([string]$analysis.Keys.model_catalog_json[0].Value).Replace('\','/').Equals($generated.Replace('\','/'),[StringComparison]::OrdinalIgnoreCase)){throw 'model_catalog_json drifted after apply; refusing to overwrite it'};if($state.config.web_search_modified-eq$true-and($analysis.Keys.web_search.Count-ne1-or$analysis.Keys.web_search[0].Value-ne'live')){throw 'web_search drifted after apply; refusing to overwrite it'};$text=Get-RollbackText $state $analysis;$deleteConfig=(-not[bool]$state.config.existed)-and[string]::IsNullOrWhiteSpace($text);$afterBytes=if($deleteConfig){$null}else{ConvertTo-Utf8Bytes $text ([bool]$state.config.had_bom)}}catch{Write-Warn $_.Exception.Message;return $script:ExitUnsafe}
    Write-Info "plan: restore tool-owned keys in $configPath";if($Options.DryRun){Write-Info 'result=dry-run (zero writes)';return $script:ExitSuccess}
    for($attempt=0;$attempt-lt2;$attempt++){
        if(-not(Confirm-Write $Options 'Rollback responses-lite-standard-tools?')){Write-Info 'cancelled';return $script:ExitError};Invoke-TestConfigMutation $configPath;$lock=$null;$interruptScope=$false;$transaction=$null;$commitPointReached=$false
        try{
            $interruptScope=Enter-OperationInterruptScope
            $lock=Acquire-Lock $CodexRoot;Assert-OperationNotCancelled;if(Read-Transaction $CodexRoot){throw 'another transaction appeared while acquiring the lock'};$currentState=Read-State $CodexRoot;if(-not$currentState-or(Get-Sha256 $statePath)-ne$stateHash){throw 'state changed while waiting for the lock'};$current=Get-ConfigAnalysis $configPath
            if($current.Sha256-ne$analysis.Sha256){if($attempt-eq0){Write-Warn 'config.toml changed after confirmation; rebuilding the rollback plan once';$analysis=$current;Assert-NoDuplicateOwnedKeys $analysis;if($analysis.Keys.model_catalog_json.Count-ne1-or-not([string]$analysis.Keys.model_catalog_json[0].Value).Replace('\','/').Equals($generated.Replace('\','/'),[StringComparison]::OrdinalIgnoreCase)){throw 'model_catalog_json drifted during confirmation'};if($state.config.web_search_modified-eq$true-and($analysis.Keys.web_search.Count-ne1-or$analysis.Keys.web_search[0].Value-ne'live')){throw 'web_search drifted during confirmation'};$text=Get-RollbackText $state $analysis;$deleteConfig=(-not[bool]$state.config.existed)-and[string]::IsNullOrWhiteSpace($text);$afterBytes=if($deleteConfig){$null}else{ConvertTo-Utf8Bytes $text ([bool]$state.config.had_bom)};continue};throw 'config.toml changed repeatedly while rolling back'}
            if((Get-Item -LiteralPath $configPath -Force).Attributes -band [IO.FileAttributes]::ReadOnly){throw 'config.toml is read-only'}
            $nonce=[string]$lock.Nonce;Assert-OperationNonce $nonce 'operation lock nonce';$snapshot=Join-Path $CodexRoot ".provider-compat-rollback-$nonce.config";$pending="$generated.rollback-pending-$nonce";$stamp=Get-Date -Format 'yyyyMMdd-HHmmss';$archive=Get-UniquePath(Join-Path $CodexRoot "provider-compat-state.json.rolled-back-$stamp");$cacheOriginal=$state.cache.original_path;$cacheBackup=$state.cache.backup_path;$catalogHash=if(Test-Path -LiteralPath $generated){Get-Sha256 $generated}else{$null};$catalogShouldMove=$false
            if($catalogHash-and$catalogHash-eq([string]$state.generated_catalog.sha256).ToUpperInvariant()){try{$ownershipCatalog=Read-CatalogFile $generated;$catalogShouldMove=[bool]$ownershipCatalog.AllTargetsAlreadyFalse}catch{$catalogShouldMove=$false}}
            $cacheShouldRestore=$cacheBackup-and(Test-Path -LiteralPath $cacheBackup)-and-not(Test-Path -LiteralPath $cacheOriginal)-and(Get-Sha256 $cacheBackup)-eq([string]$state.cache.sha256).ToUpperInvariant()
            $transaction=[ordered]@{schema_version=1;operation='rollback';phase='prepared';nonce=$nonce;created_at=[DateTimeOffset]::Now.ToString('o');updated_at=$null;codex_version=$state.codex_version;root=$CodexRoot;paths=[ordered]@{config=$configPath;config_backup=$null;config_snapshot=$snapshot;generated_catalog=$generated;generated_catalog_pending=$pending;cache_original=$cacheOriginal;cache_backup=$cacheBackup;state=$statePath;state_archive=$archive};hashes=[ordered]@{config_before=$analysis.Sha256;config_after=if($deleteConfig){$null}else{Get-BytesSha256 $afterBytes};generated_catalog=$catalogHash;cache=$state.cache.sha256;state=$stateHash};flags=[ordered]@{config_existed=$true;config_should_delete=$deleteConfig;generated_catalog_owned=[bool]$catalogShouldMove;cache_should_restore=[bool]$cacheShouldRestore}}
            Write-Transaction $CodexRoot ([pscustomobject]$transaction);Invoke-TestFault 'rollback-prepared';Copy-VerifiedFileWithAcl $CodexRoot $configPath $snapshot $analysis.Sha256 'rollback config snapshot';Set-TransactionPhase $CodexRoot $transaction 'config-snapshotted';Invoke-TestFault 'rollback-after-snapshot'
            if($catalogShouldMove){[IO.File]::Move($generated,$pending)}elseif(Test-Path -LiteralPath $generated){Write-Warn 'generated catalog is drifted or invalid; preserved it'};Set-TransactionPhase $CodexRoot $transaction 'generated-catalog-pending';Invoke-TestFault 'rollback-after-catalog'
            if($cacheShouldRestore){[IO.File]::Move($cacheBackup,$cacheOriginal)}elseif($cacheBackup-and(Test-Path -LiteralPath $cacheBackup)){if(Test-Path -LiteralPath $cacheOriginal){Write-Warn 'a new models_cache.json exists; preserved both cache files'}else{Write-Warn 'cache backup hash drifted; preserved it'}};Set-TransactionPhase $CodexRoot $transaction 'cache-restored';Invoke-TestFault 'rollback-after-cache'
            if((Get-Sha256 $configPath)-ne$analysis.Sha256){throw 'config.toml changed immediately before the rollback write'}
            Invoke-TestFault 'rollback-config-write'
            if($deleteConfig){[IO.File]::Delete((Assert-SafeOwnedPath $CodexRoot $configPath))}else{Write-AtomicBytes $CodexRoot $configPath $afterBytes $nonce}
            if($deleteConfig){if(Test-Path -LiteralPath $configPath){throw 'rollback failed to restore the missing-config state'}}else{
                if((Get-Sha256 $configPath)-ne(Get-BytesSha256 $afterBytes)){throw 'rollback config hash verification failed'}
                if($analysis.Acl-and-not(Test-PathAclMatchesSddl $configPath $analysis.Acl)){throw 'rollback changed config permissions'}
                $restoredAnalysis=Get-ConfigAnalysis $configPath;Assert-NoDuplicateOwnedKeys $restoredAnalysis
                if([bool]$state.config.previous_model_catalog_json_present){if($restoredAnalysis.Keys.model_catalog_json.Count-ne1-or-not([string]$restoredAnalysis.Keys.model_catalog_json[0].Value).Equals([string]$state.config.previous_model_catalog_json,[StringComparison]::Ordinal)){throw 'rollback did not restore model_catalog_json'}}elseif($restoredAnalysis.Keys.model_catalog_json.Count-ne0){throw 'rollback did not remove model_catalog_json'}
                if($state.config.web_search_modified-eq$true){if([bool]$state.config.previous_web_search_present){if($restoredAnalysis.Keys.web_search.Count-ne1-or-not([string]$restoredAnalysis.Keys.web_search[0].Value).Equals([string]$state.config.previous_web_search,[StringComparison]::Ordinal)){throw 'rollback did not restore web_search'}}elseif($restoredAnalysis.Keys.web_search.Count-ne0){throw 'rollback did not remove web_search'}}
            }
            if($catalogShouldMove-and(-not(Test-Path -LiteralPath $pending)-or(Test-Path -LiteralPath $generated)-or(Get-Sha256 $pending)-ne([string]$state.generated_catalog.sha256).ToUpperInvariant())){throw 'rollback pending catalog verification failed'}
            if($cacheShouldRestore-and(-not(Test-Path -LiteralPath $cacheOriginal)-or(Test-Path -LiteralPath $cacheBackup)-or(Get-Sha256 $cacheOriginal)-ne([string]$state.cache.sha256).ToUpperInvariant())){throw 'rollback cache restoration verification failed'}
            Set-TransactionPhase $CodexRoot $transaction 'config-written';Invoke-TestFault 'rollback-after-config'
            [IO.File]::Move($statePath,$archive)
            if((Test-Path -LiteralPath $statePath) -or -not(Test-Path -LiteralPath $archive) -or (Get-Sha256 $archive)-ne$stateHash){throw 'rollback state archive verification failed'}
            Set-TransactionPhase $CodexRoot $transaction 'state-archived';Invoke-TestFault 'rollback-after-state';Assert-OperationNotCancelled;$commitPointReached=$true;Invoke-TestFault 'rollback-committed-before-cleanup'
            if(Test-Path -LiteralPath $pending){Remove-VerifiedOwnedFile $CodexRoot $pending ([string]$state.generated_catalog.sha256)}
            Invoke-TestFault 'rollback-after-pending-cleanup'
            Remove-VerifiedOwnedFile $CodexRoot $snapshot $analysis.Sha256;Remove-VerifiedOwnedFile $CodexRoot (Get-TransactionPath $CodexRoot) $null
            $transactionStillExists=Test-Path -LiteralPath (Get-TransactionPath $CodexRoot)
            $catalogStillExists=$catalogShouldMove -and ((Test-Path -LiteralPath $generated) -or (Test-Path -LiteralPath $pending))
            if((Test-Path -LiteralPath $statePath) -or $transactionStillExists -or (Test-Path -LiteralPath $snapshot) -or $catalogStillExists){throw 'rollback final-state verification failed'}
            Write-Info 'result=rolled-back';Write-Info '完全退出并重新启动 Codex，然后新建任务/新 thread。';Write-Info '旧任务保留启动时的模型与工具快照，不会自动应用本次更改。';return $script:ExitSuccess
        }catch{
            $message=$_.Exception.Message;$wasInterrupted=[ProviderCompatNative]::CancellationRequested;$recovery=$null;$transaction=$null;$preferRestore=$wasInterrupted-and-not$commitPointReached;try{$transaction=Read-Transaction $CodexRoot;if($transaction){$recovery=Recover-Transaction $CodexRoot $transaction $preferRestore;if($recovery-eq'committed'){Write-Warn "rollback completed during recovery after: $message";Write-Info 'result=rolled-back';Write-Info '完全退出并重新启动 Codex，然后新建任务/新 thread。';Write-Info '旧任务保留启动时的模型与工具快照，不会自动应用本次更改。';return $script:ExitSuccess}}}catch{Write-Warn "automatic transaction recovery failed: $($_.Exception.Message)"};if($wasInterrupted){if($recovery-eq'restored'-or-not$transaction){Write-Info 'result=interrupted-restored'};Write-Warn "rollback interrupted safely: $message";return $script:ExitUnsafe};if($attempt-eq0-and$message-like'config.toml changed after confirmation*'){continue};Write-Warn "rollback failed safely: $message";return $script:ExitUnsafe
        }finally{Release-Lock $lock;if($interruptScope){Exit-OperationInterruptScope}}
    }
    return $script:ExitUnsafe
}

function Invoke-Main([string[]]$InputArgs) {
    foreach($argument in @($InputArgs)){
        if([string]::Equals([string]$argument,'--enable-web-search',[StringComparison]::OrdinalIgnoreCase)){
            Write-Warn '--enable-web-search was removed; this tool no longer manages Web Search'
            return $script:ExitError
        }
    }
    try { Assert-InternalTestAuthorization }
    catch { Write-Warn $_.Exception.Message; return $script:ExitUnsafe }
    try { $options = Parse-Arguments $InputArgs }
    catch { Write-Warn $_.Exception.Message; return $script:ExitError }

    if ($options.CodexHomeSet -and [string]::IsNullOrWhiteSpace($options.CodexHome)) {
        Write-Warn '--codex-home must not be empty'
        return $script:ExitUnsafe
    }
    if ($options.CodexVersionSet -and [string]::IsNullOrWhiteSpace($options.CodexVersion)) {
        Write-Warn '--codex-version must not be empty'
        return $script:ExitError
    }
    if ($options.CatalogFileSet -and [string]::IsNullOrWhiteSpace($options.CatalogFile)) {
        Write-Warn '--catalog-file must not be empty'
        return $script:ExitError
    }

    try { $CodexRoot = Resolve-CodexHome $options.CodexHome }
    catch { Write-Warn $_.Exception.Message; return $script:ExitUnsafe }
    switch ($options.Command) {
        'doctor' { return Invoke-Doctor $options $CodexRoot }
        'apply' { return Invoke-Apply $options $CodexRoot }
        'status' { return Invoke-Status $options $CodexRoot }
        'rollback' { return Invoke-Rollback $options $CodexRoot }
    }
    return $script:ExitError
}

exit (Invoke-Main $args)
