#!/usr/bin/env pwsh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 codex-provider-compat contributors

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Assert-BytesEqual {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Expected,
        [Parameter(Mandatory = $true)][byte[]]$Actual,
        [Parameter(Mandatory = $true)][string]$Label
    )

    Assert-True ($Expected.Length -eq $Actual.Length) "$Label length mismatch"
    for ($i = 0; $i -lt $Expected.Length; $i++) {
        if ($Expected[$i] -ne $Actual[$i]) {
            throw "$Label differs at byte $i"
        }
    }
}

function Get-ZipEntryBytes {
    param(
        [Parameter(Mandatory = $true)][IO.Compression.ZipArchive]$Archive,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $entry = $Archive.GetEntry($Name)
    if ($null -eq $entry) {
        throw "missing ZIP entry: $Name"
    }
    $memory = New-Object IO.MemoryStream
    $stream = $entry.Open()
    try {
        $stream.CopyTo($memory)
    }
    finally {
        $stream.Dispose()
    }
    try {
        return $memory.ToArray()
    }
    finally {
        $memory.Dispose()
    }
}

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$builder = Join-Path $repoRoot 'scripts/build-release.ps1'
$version = '0.1.0'
$prefix = "codex-provider-compat-v$version"
$expectedAssets = @(
    'codex-provider-compat.ps1',
    'codex-provider-compat.sh',
    "$prefix-macos.zip",
    "$prefix-windows.zip",
    'SHA256SUMS.txt'
) | Sort-Object

$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
$tempRoot = Join-Path $tempBase ("codex-provider-compat-release-test-{0}" -f [Guid]::NewGuid().ToString('N'))
$first = Join-Path $tempRoot 'first'
$second = Join-Path $tempRoot 'second'
$legacy = Join-Path $tempRoot 'legacy-powershell'

try {
    $null = New-Item -ItemType Directory -Path $first -Force
    $null = New-Item -ItemType Directory -Path $second -Force

    & $builder -Version $version -OutputDirectory $first
    & $builder -Version "v$version" -OutputDirectory $second

    $firstNames = @(Get-ChildItem -LiteralPath $first -File | Select-Object -ExpandProperty Name | Sort-Object)
    $secondNames = @(Get-ChildItem -LiteralPath $second -File | Select-Object -ExpandProperty Name | Sort-Object)
    Assert-True (($firstNames -join "`n") -eq ($expectedAssets -join "`n")) 'first build produced an unexpected asset set'
    Assert-True (($secondNames -join "`n") -eq ($expectedAssets -join "`n")) 'second build produced an unexpected asset set'

    foreach ($name in $expectedAssets) {
        Assert-BytesEqual -Expected ([IO.File]::ReadAllBytes((Join-Path $first $name))) -Actual ([IO.File]::ReadAllBytes((Join-Path $second $name))) -Label "reproducibility check for $name"
    }

    if ($PSVersionTable.PSVersion.Major -ge 7 -and
        [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT -and
        $null -ne (Get-Command powershell.exe -ErrorAction SilentlyContinue)) {
        $null = New-Item -ItemType Directory -Path $legacy -Force
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $builder -Version $version -OutputDirectory $legacy
        if ($LASTEXITCODE -ne 0) {
            throw "Windows PowerShell release build failed with exit code $LASTEXITCODE"
        }
        foreach ($name in $expectedAssets) {
            Assert-BytesEqual -Expected ([IO.File]::ReadAllBytes((Join-Path $first $name))) -Actual ([IO.File]::ReadAllBytes((Join-Path $legacy $name))) -Label "cross-runtime reproducibility check for $name"
        }
    }

    $mismatchOutput = Join-Path $tempRoot 'version-mismatch'
    $null = New-Item -ItemType Directory -Path $mismatchOutput
    $mismatchFailed = $false
    try {
        & $builder -Version '0.1.1' -OutputDirectory $mismatchOutput
    }
    catch {
        $mismatchFailed = $true
    }
    Assert-True $mismatchFailed 'release builder must reject a version that differs from the scripts'
    Assert-True (@(Get-ChildItem -LiteralPath $mismatchOutput -Force).Count -eq 0) 'version mismatch must not leave release assets'

    $nonEmptyOutput = Join-Path $tempRoot 'non-empty-output'
    $null = New-Item -ItemType Directory -Path $nonEmptyOutput
    $sentinel = Join-Path $nonEmptyOutput 'sentinel.txt'
    [IO.File]::WriteAllText($sentinel, 'preserve', (New-Object Text.UTF8Encoding($false)))
    $nonEmptyFailed = $false
    try {
        & $builder -Version $version -OutputDirectory $nonEmptyOutput
    }
    catch {
        $nonEmptyFailed = $true
    }
    Assert-True $nonEmptyFailed 'release builder must reject a non-empty output directory'
    Assert-True ([IO.File]::ReadAllText($sentinel) -eq 'preserve') 'release builder changed a non-empty output directory'

    Assert-BytesEqual -Expected ([IO.File]::ReadAllBytes((Join-Path $repoRoot 'codex-provider-compat.ps1'))) -Actual ([IO.File]::ReadAllBytes((Join-Path $first 'codex-provider-compat.ps1'))) -Label 'standalone Windows script'
    Assert-BytesEqual -Expected ([IO.File]::ReadAllBytes((Join-Path $repoRoot 'codex-provider-compat.sh'))) -Actual ([IO.File]::ReadAllBytes((Join-Path $first 'codex-provider-compat.sh'))) -Label 'standalone macOS script'

    $checksumPath = Join-Path $first 'SHA256SUMS.txt'
    $checksumBytes = [IO.File]::ReadAllBytes($checksumPath)
    Assert-True ([Array]::IndexOf($checksumBytes, [byte]0x0D) -lt 0) 'SHA256SUMS.txt must use LF only'
    $checksumText = (New-Object Text.UTF8Encoding($false, $true)).GetString($checksumBytes)
    $checksumLines = @($checksumText.TrimEnd("`n").Split("`n"))
    Assert-True ($checksumLines.Count -eq 4) 'SHA256SUMS.txt must contain exactly four asset hashes'
    $seen = @{}
    foreach ($line in $checksumLines) {
        $match = [regex]::Match($line, '^([0-9a-f]{64})  ([A-Za-z0-9._-]+)$')
        Assert-True $match.Success "invalid checksum line: $line"
        $name = $match.Groups[2].Value
        Assert-True ($name -ne 'SHA256SUMS.txt') 'SHA256SUMS.txt must not hash itself'
        Assert-True (-not $seen.ContainsKey($name)) "duplicate checksum entry: $name"
        $seen[$name] = $true
        $actual = (Get-FileHash -LiteralPath (Join-Path $first $name) -Algorithm SHA256).Hash.ToLowerInvariant()
        Assert-True ($actual -eq $match.Groups[1].Value) "checksum mismatch for $name"
    }
    Assert-True ($seen.Count -eq 4) 'checksum manifest did not cover all four distributable assets'

    $windowsZipPath = Join-Path $first "$prefix-windows.zip"
    $windowsArchive = [IO.Compression.ZipFile]::OpenRead($windowsZipPath)
    try {
        $windowsNames = @($windowsArchive.Entries | Select-Object -ExpandProperty FullName | Sort-Object)
        $windowsRoot = "$prefix-windows"
        $expectedWindowsNames = @(
            "$windowsRoot/LICENSE",
            "$windowsRoot/README.md",
            "$windowsRoot/README.zh-CN.md",
            "$windowsRoot/THIRD_PARTY_NOTICES.md",
            "$windowsRoot/codex-provider-compat.ps1"
        ) | Sort-Object
        Assert-True (($windowsNames -join "`n") -eq ($expectedWindowsNames -join "`n")) 'Windows ZIP contents are incorrect'
        Assert-BytesEqual -Expected ([IO.File]::ReadAllBytes((Join-Path $repoRoot 'codex-provider-compat.ps1'))) -Actual (Get-ZipEntryBytes -Archive $windowsArchive -Name "$windowsRoot/codex-provider-compat.ps1") -Label 'Windows ZIP script'
    }
    finally {
        $windowsArchive.Dispose()
    }

    $macosZipPath = Join-Path $first "$prefix-macos.zip"
    $macosArchive = [IO.Compression.ZipFile]::OpenRead($macosZipPath)
    try {
        $macosNames = @($macosArchive.Entries | Select-Object -ExpandProperty FullName | Sort-Object)
        $macosRoot = "$prefix-macos"
        $expectedMacosNames = @(
            "$macosRoot/LICENSE",
            "$macosRoot/README.md",
            "$macosRoot/README.zh-CN.md",
            "$macosRoot/THIRD_PARTY_NOTICES.md",
            "$macosRoot/codex-provider-compat.sh"
        ) | Sort-Object
        Assert-True (($macosNames -join "`n") -eq ($expectedMacosNames -join "`n")) 'macOS ZIP contents are incorrect'
        Assert-BytesEqual -Expected ([IO.File]::ReadAllBytes((Join-Path $repoRoot 'codex-provider-compat.sh'))) -Actual (Get-ZipEntryBytes -Archive $macosArchive -Name "$macosRoot/codex-provider-compat.sh") -Label 'macOS ZIP script'
        $scriptEntry = $macosArchive.GetEntry("$macosRoot/codex-provider-compat.sh")
        $unsignedAttributes = [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$scriptEntry.ExternalAttributes), 0)
        $mode = ($unsignedAttributes -shr 16) -band 0xFFFF
        Assert-True (($mode -band 0x1FF) -eq 0x1ED) 'macOS ZIP script must carry mode 0755'
    }
    finally {
        $macosArchive.Dispose()
    }

    $windowsExtract = Join-Path $tempRoot 'windows-extract'
    $macosExtract = Join-Path $tempRoot 'macos-extract'
    Expand-Archive -LiteralPath $windowsZipPath -DestinationPath $windowsExtract
    Expand-Archive -LiteralPath $macosZipPath -DestinationPath $macosExtract
    Assert-BytesEqual -Expected ([IO.File]::ReadAllBytes((Join-Path $repoRoot 'codex-provider-compat.ps1'))) -Actual ([IO.File]::ReadAllBytes((Join-Path $windowsExtract "$prefix-windows/codex-provider-compat.ps1"))) -Label 'extracted Windows script'
    Assert-BytesEqual -Expected ([IO.File]::ReadAllBytes((Join-Path $repoRoot 'codex-provider-compat.sh'))) -Actual ([IO.File]::ReadAllBytes((Join-Path $macosExtract "$prefix-macos/codex-provider-compat.sh"))) -Label 'extracted macOS script'

    Write-Host 'Release packaging tests passed.'
}
finally {
    $fullTempRoot = [IO.Path]::GetFullPath($tempRoot)
    if (-not $fullTempRoot.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase)) {
        throw "refusing to clean an unexpected path: $fullTempRoot"
    }
    if (Test-Path -LiteralPath $fullTempRoot) {
        Remove-Item -LiteralPath $fullTempRoot -Recurse -Force
    }
}
