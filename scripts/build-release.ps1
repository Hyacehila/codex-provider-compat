#!/usr/bin/env pwsh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 codex-provider-compat contributors

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Version,

    [string]$OutputDirectory = (Join-Path (Split-Path -Parent $PSScriptRoot) 'dist')
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop

function Get-AbsolutePath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw 'path must not be empty'
    }
    return [IO.Path]::GetFullPath($Path)
}

function Assert-SafeOutputDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = Get-AbsolutePath $Path
    $root = [IO.Path]::GetPathRoot($fullPath)
    if ([string]::IsNullOrEmpty($root) -or
        $fullPath.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) -eq
        $root.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)) {
        throw "refusing to use a filesystem root as the output directory: $fullPath"
    }

    if (Test-Path -LiteralPath $fullPath) {
        $item = Get-Item -LiteralPath $fullPath -Force
        if (-not $item.PSIsContainer) {
            throw "output path exists and is not a directory: $fullPath"
        }
        if (@(Get-ChildItem -LiteralPath $fullPath -Force).Count -ne 0) {
            throw "output directory must be empty: $fullPath"
        }
    }
    else {
        $null = New-Item -ItemType Directory -Path $fullPath
    }

    return $fullPath
}

function Get-StrictUtf8Text {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][string]$Label,
        [int]$Offset = 0
    )

    try {
        $encoding = New-Object Text.UTF8Encoding($false, $true)
        return $encoding.GetString($Bytes, $Offset, $Bytes.Length - $Offset)
    }
    catch {
        throw "$Label is not valid UTF-8: $($_.Exception.Message)"
    }
}

function Assert-SourceEncoding {
    param(
        [Parameter(Mandatory = $true)][string]$PowerShellPath,
        [Parameter(Mandatory = $true)][string]$ShellPath,
        [Parameter(Mandatory = $true)][string[]]$LfPaths
    )

    $psBytes = [IO.File]::ReadAllBytes($PowerShellPath)
    if ($psBytes.Length -lt 3 -or $psBytes[0] -ne 0xEF -or $psBytes[1] -ne 0xBB -or $psBytes[2] -ne 0xBF) {
        throw 'codex-provider-compat.ps1 must be UTF-8 with BOM'
    }
    $psText = Get-StrictUtf8Text -Bytes $psBytes -Label 'codex-provider-compat.ps1' -Offset 3
    if ([regex]::IsMatch($psText, '(?<!\r)\n|\r(?!\n)')) {
        throw 'codex-provider-compat.ps1 must use CRLF line endings only'
    }
    if (-not $psText.StartsWith("#!/usr/bin/env pwsh`r`n")) {
        throw 'codex-provider-compat.ps1 has an unexpected shebang'
    }

    $shBytes = [IO.File]::ReadAllBytes($ShellPath)
    $shText = Get-StrictUtf8Text -Bytes $shBytes -Label 'codex-provider-compat.sh'
    if ($shBytes.Length -ge 3 -and $shBytes[0] -eq 0xEF -and $shBytes[1] -eq 0xBB -and $shBytes[2] -eq 0xBF) {
        throw 'codex-provider-compat.sh must not have a UTF-8 BOM'
    }
    if ([Array]::IndexOf($shBytes, [byte]0x0D) -ge 0) {
        throw 'codex-provider-compat.sh must use LF line endings only'
    }
    if (-not $shText.StartsWith("#!/bin/sh`n")) {
        throw 'codex-provider-compat.sh has an unexpected shebang'
    }

    foreach ($path in $LfPaths) {
        $bytes = [IO.File]::ReadAllBytes($path)
        $null = Get-StrictUtf8Text -Bytes $bytes -Label ([IO.Path]::GetFileName($path))
        if ([Array]::IndexOf($bytes, [byte]0x0D) -ge 0) {
            throw "$([IO.Path]::GetFileName($path)) must use LF line endings only"
        }
    }

    return [pscustomobject]@{
        PowerShellBytes = $psBytes
        PowerShellText = $psText
        ShellBytes = $shBytes
        ShellText = $shText
    }
}

function Get-Sha256Hex {
    param([Parameter(Mandatory = $true)][string]$Path)

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-OrdinalSortedStrings {
    param([Parameter(Mandatory = $true)][string[]]$Values)

    $copy = [string[]]@($Values)
    [Array]::Sort($copy, [StringComparer]::Ordinal)
    return $copy
}

function ConvertTo-SignedExternalAttributes {
    param([Parameter(Mandatory = $true)][int]$UnixMode)

    $unsigned = ([uint32]$UnixMode) -shl 16
    return [BitConverter]::ToInt32([BitConverter]::GetBytes($unsigned), 0)
}

function New-Crc32Table {
    $table = New-Object 'uint32[]' 256
    for ($i = 0; $i -lt $table.Length; $i++) {
        $value = [uint32]$i
        for ($bit = 0; $bit -lt 8; $bit++) {
            if (($value -band 1) -ne 0) {
                $value = [uint32](($value -shr 1) -bxor [uint32]3988292384)
            }
            else {
                $value = [uint32]($value -shr 1)
            }
        }
        $table[$i] = $value
    }
    return $table
}

function Get-Crc32 {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

    $crc = [uint32]4294967295
    foreach ($byte in $Bytes) {
        $index = [int](($crc -bxor [uint32]$byte) -band 255)
        $crc = [uint32](($crc -shr 8) -bxor $script:Crc32Table[$index])
    }
    return [uint32]($crc -bxor [uint32]4294967295)
}

$script:Crc32Table = New-Crc32Table

function New-DeterministicZip {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object[]]$Entries
    )

    $utf8NoBom = New-Object Text.UTF8Encoding($false)
    $stream = New-Object IO.FileStream($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    $writer = New-Object IO.BinaryWriter($stream)
    try {
        $records = @()
        $entriesByName = @{}
        foreach ($definition in $Entries) {
            $candidateName = [string]$definition.Name
            if ($entriesByName.ContainsKey($candidateName)) {
                throw "duplicate ZIP entry name: $candidateName"
            }
            $entriesByName[$candidateName] = $definition
        }
        $sortedNames = @(Get-OrdinalSortedStrings -Values ([string[]]@($entriesByName.Keys)))
        foreach ($name in $sortedNames) {
            $definition = $entriesByName[$name]
            $nameBytes = $utf8NoBom.GetBytes($name)
            $bytes = [byte[]]$definition.Bytes
            if ($nameBytes.Length -gt [uint16]::MaxValue) {
                throw "ZIP entry name is too long: $name"
            }
            if ([uint64]$bytes.LongLength -gt [uint32]::MaxValue) {
                throw "ZIP entry is too large for the release archive: $name"
            }
            if ([uint64]$stream.Position -gt [uint32]::MaxValue) {
                throw 'ZIP archive exceeds the supported non-ZIP64 size'
            }

            $crc = Get-Crc32 $bytes
            $offset = [uint32]$stream.Position

            # Local file header. Entries are stored rather than deflated so the
            # bytes are identical across Windows PowerShell and PowerShell 7.
            $writer.Write([uint32]0x04034B50)
            $writer.Write([uint16]20)
            $writer.Write([uint16]0x0800)
            $writer.Write([uint16]0)
            $writer.Write([uint16]0)
            $writer.Write([uint16]33)
            $writer.Write([uint32]$crc)
            $writer.Write([uint32]$bytes.Length)
            $writer.Write([uint32]$bytes.Length)
            $writer.Write([uint16]$nameBytes.Length)
            $writer.Write([uint16]0)
            $writer.Write([byte[]]$nameBytes)
            $writer.Write([byte[]]$bytes)

            $records += [pscustomobject]@{
                Name = $name
                NameBytes = $nameBytes
                Crc32 = [uint32]$crc
                Size = [uint32]$bytes.Length
                Mode = [int]$definition.Mode
                Offset = $offset
            }
        }

        if ($records.Count -gt [uint16]::MaxValue) {
            throw 'ZIP archive contains too many entries'
        }
        if ([uint64]$stream.Position -gt [uint32]::MaxValue) {
            throw 'ZIP archive exceeds the supported non-ZIP64 size'
        }
        $centralOffset = [uint32]$stream.Position

        foreach ($record in $records) {
            $writer.Write([uint32]0x02014B50)
            $writer.Write([uint16]0x0314)
            $writer.Write([uint16]20)
            $writer.Write([uint16]0x0800)
            $writer.Write([uint16]0)
            $writer.Write([uint16]0)
            $writer.Write([uint16]33)
            $writer.Write([uint32]$record.Crc32)
            $writer.Write([uint32]$record.Size)
            $writer.Write([uint32]$record.Size)
            $writer.Write([uint16]$record.NameBytes.Length)
            $writer.Write([uint16]0)
            $writer.Write([uint16]0)
            $writer.Write([uint16]0)
            $writer.Write([uint16]0)
            $writer.Write([uint32](([uint32]$record.Mode) -shl 16))
            $writer.Write([uint32]$record.Offset)
            $writer.Write([byte[]]$record.NameBytes)
        }

        $centralSize64 = [uint64]$stream.Position - [uint64]$centralOffset
        if ($centralSize64 -gt [uint32]::MaxValue) {
            throw 'ZIP central directory exceeds the supported non-ZIP64 size'
        }

        $writer.Write([uint32]0x06054B50)
        $writer.Write([uint16]0)
        $writer.Write([uint16]0)
        $writer.Write([uint16]$records.Count)
        $writer.Write([uint16]$records.Count)
        $writer.Write([uint32]$centralSize64)
        $writer.Write([uint32]$centralOffset)
        $writer.Write([uint16]0)
        $writer.Flush()
    }
    finally {
        $writer.Dispose()
    }
}

function Assert-ByteArraysEqual {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Expected,
        [Parameter(Mandatory = $true)][byte[]]$Actual,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if ($Expected.Length -ne $Actual.Length) {
        throw "$Label length mismatch: expected $($Expected.Length), got $($Actual.Length)"
    }
    for ($i = 0; $i -lt $Expected.Length; $i++) {
        if ($Expected[$i] -ne $Actual[$i]) {
            throw "$Label differs at byte $i"
        }
    }
}

function Assert-ZipContents {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object[]]$ExpectedEntries
    )

    $archive = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $expected = @{}
        foreach ($definition in $ExpectedEntries) {
            $expected[[string]$definition.Name] = $definition
        }
        if ($archive.Entries.Count -ne $expected.Count) {
            throw "$([IO.Path]::GetFileName($Path)) contains $($archive.Entries.Count) entries; expected $($expected.Count)"
        }

        foreach ($entry in $archive.Entries) {
            if ($entry.FullName.StartsWith('/') -or $entry.FullName.StartsWith('\\') -or
                $entry.FullName -match '(^|/)\.\.(/|$)') {
                throw "unsafe ZIP entry path: $($entry.FullName)"
            }
            if (-not $expected.ContainsKey($entry.FullName)) {
                throw "unexpected ZIP entry: $($entry.FullName)"
            }

            $memory = New-Object IO.MemoryStream
            $entryStream = $entry.Open()
            try {
                $entryStream.CopyTo($memory)
            }
            finally {
                $entryStream.Dispose()
            }
            try {
                Assert-ByteArraysEqual -Expected ([byte[]]$expected[$entry.FullName].Bytes) -Actual $memory.ToArray() -Label $entry.FullName
            }
            finally {
                $memory.Dispose()
            }

            $expectedAttributes = ConvertTo-SignedExternalAttributes -UnixMode ([int]$expected[$entry.FullName].Mode)
            if ($entry.ExternalAttributes -ne $expectedAttributes) {
                throw "unexpected mode metadata for ZIP entry $($entry.FullName)"
            }
            if ($entry.CompressedLength -ne $entry.Length) {
                throw "ZIP entry must use stored, reproducible bytes: $($entry.FullName)"
            }
            if ($entry.LastWriteTime.Year -ne 1980 -or $entry.LastWriteTime.Month -ne 1 -or
                $entry.LastWriteTime.Day -ne 1 -or $entry.LastWriteTime.Hour -ne 0 -or
                $entry.LastWriteTime.Minute -ne 0 -or $entry.LastWriteTime.Second -ne 0) {
                throw "ZIP entry has an unexpected timestamp: $($entry.FullName)"
            }
        }
    }
    finally {
        $archive.Dispose()
    }
}

$normalizedVersion = $Version.Trim()
if ($normalizedVersion.StartsWith('v', [StringComparison]::OrdinalIgnoreCase)) {
    $normalizedVersion = $normalizedVersion.Substring(1)
}
if ($normalizedVersion -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$') {
    throw "version must be a stable semantic version such as 0.1.0: $Version"
}

$repoRoot = Get-AbsolutePath (Join-Path $PSScriptRoot '..')
$sourcePowerShell = Join-Path $repoRoot 'codex-provider-compat.ps1'
$sourceShell = Join-Path $repoRoot 'codex-provider-compat.sh'
$sourceReadme = Join-Path $repoRoot 'README.md'
$sourceReadmeZh = Join-Path $repoRoot 'README.zh-CN.md'
$sourceLicense = Join-Path $repoRoot 'LICENSE'
$sourceNotices = Join-Path $repoRoot 'THIRD_PARTY_NOTICES.md'
$requiredSources = @($sourcePowerShell, $sourceShell, $sourceReadme, $sourceReadmeZh, $sourceLicense, $sourceNotices)
foreach ($path in $requiredSources) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "required release source is missing: $path"
    }
}

$source = Assert-SourceEncoding -PowerShellPath $sourcePowerShell -ShellPath $sourceShell -LfPaths @(
    $sourceReadme, $sourceReadmeZh, $sourceLicense, $sourceNotices
)
if ($source.PowerShellText -notmatch '(?m)^# SPDX-License-Identifier: MIT\r?$' -or
    $source.ShellText -notmatch '(?m)^# SPDX-License-Identifier: MIT$') {
    throw 'both standalone scripts must contain an SPDX MIT license header'
}

$psVersionMatch = [regex]::Match($source.PowerShellText, '(?m)^\$script:ToolVersion\s*=\s*''([^'']+)''\s*$')
$shVersionMatch = [regex]::Match($source.ShellText, '(?m)^TOOL_VERSION=([^\s]+)\s*$')
if (-not $psVersionMatch.Success -or -not $shVersionMatch.Success) {
    throw 'could not read the tool version from both platform scripts'
}
if ($psVersionMatch.Groups[1].Value -ne $normalizedVersion -or $shVersionMatch.Groups[1].Value -ne $normalizedVersion) {
    throw "release version $normalizedVersion does not match script versions $($psVersionMatch.Groups[1].Value) and $($shVersionMatch.Groups[1].Value)"
}

$outputRoot = Assert-SafeOutputDirectory $OutputDirectory
$prefix = "codex-provider-compat-v$normalizedVersion"
$standalonePowerShellName = 'codex-provider-compat.ps1'
$standaloneShellName = 'codex-provider-compat.sh'
$windowsZipName = "$prefix-windows.zip"
$macosZipName = "$prefix-macos.zip"

$standalonePowerShellPath = Join-Path $outputRoot $standalonePowerShellName
$standaloneShellPath = Join-Path $outputRoot $standaloneShellName
[IO.File]::WriteAllBytes($standalonePowerShellPath, [byte[]]$source.PowerShellBytes)
[IO.File]::WriteAllBytes($standaloneShellPath, [byte[]]$source.ShellBytes)

$commonFiles = @(
    [pscustomobject]@{ RelativeName = 'README.md'; Bytes = [IO.File]::ReadAllBytes($sourceReadme); Mode = 33188 },
    [pscustomobject]@{ RelativeName = 'README.zh-CN.md'; Bytes = [IO.File]::ReadAllBytes($sourceReadmeZh); Mode = 33188 },
    [pscustomobject]@{ RelativeName = 'LICENSE'; Bytes = [IO.File]::ReadAllBytes($sourceLicense); Mode = 33188 },
    [pscustomobject]@{ RelativeName = 'THIRD_PARTY_NOTICES.md'; Bytes = [IO.File]::ReadAllBytes($sourceNotices); Mode = 33188 }
)

$windowsRoot = "$prefix-windows"
$windowsEntries = @(
    [pscustomobject]@{ Name = "$windowsRoot/codex-provider-compat.ps1"; Bytes = [byte[]]$source.PowerShellBytes; Mode = 33188 }
)
foreach ($file in $commonFiles) {
    $windowsEntries += [pscustomobject]@{ Name = "$windowsRoot/$($file.RelativeName)"; Bytes = [byte[]]$file.Bytes; Mode = [int]$file.Mode }
}

$macosRoot = "$prefix-macos"
$macosEntries = @(
    [pscustomobject]@{ Name = "$macosRoot/codex-provider-compat.sh"; Bytes = [byte[]]$source.ShellBytes; Mode = 33261 }
)
foreach ($file in $commonFiles) {
    $macosEntries += [pscustomobject]@{ Name = "$macosRoot/$($file.RelativeName)"; Bytes = [byte[]]$file.Bytes; Mode = [int]$file.Mode }
}

$windowsZipPath = Join-Path $outputRoot $windowsZipName
$macosZipPath = Join-Path $outputRoot $macosZipName
New-DeterministicZip -Path $windowsZipPath -Entries $windowsEntries
New-DeterministicZip -Path $macosZipPath -Entries $macosEntries
Assert-ZipContents -Path $windowsZipPath -ExpectedEntries $windowsEntries
Assert-ZipContents -Path $macosZipPath -ExpectedEntries $macosEntries

$assetNames = @(Get-OrdinalSortedStrings -Values @($standalonePowerShellName, $standaloneShellName, $windowsZipName, $macosZipName))
$checksumLines = foreach ($name in $assetNames) {
    '{0}  {1}' -f (Get-Sha256Hex (Join-Path $outputRoot $name)), $name
}
$checksumPath = Join-Path $outputRoot 'SHA256SUMS.txt'
$utf8NoBom = New-Object Text.UTF8Encoding($false)
[IO.File]::WriteAllText($checksumPath, (($checksumLines -join "`n") + "`n"), $utf8NoBom)

foreach ($name in @($assetNames + 'SHA256SUMS.txt')) {
    $path = Join-Path $outputRoot $name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-Item -LiteralPath $path).Length -eq 0) {
        throw "release asset is missing or empty: $name"
    }
}

Write-Host "Release assets created in $outputRoot"
foreach ($name in @($assetNames + 'SHA256SUMS.txt')) {
    Write-Host ("{0}  {1}" -f (Get-Sha256Hex (Join-Path $outputRoot $name)), $name)
}
