[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$buildScript = Join-Path $PSScriptRoot 'build_windows.ps1'
$packageScript = Join-Path $PSScriptRoot 'package_release.ps1'

function Assert-True {
    param(
        [Parameter(Mandatory = $true)]
        [bool] $Condition,

        [Parameter(Mandatory = $true)]
        [string] $Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Get-ContentHash {
    param([string] $Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $stream = [IO.File]::OpenRead($Path)
        try {
            return [BitConverter]::ToString($sha.ComputeHash($stream))
        }
        finally {
            $stream.Dispose()
        }
    }
    finally {
        $sha.Dispose()
    }
}

Assert-True (Test-Path -LiteralPath $buildScript -PathType Leaf) 'Missing scripts/build_windows.ps1'
Assert-True (Test-Path -LiteralPath $packageScript -PathType Leaf) 'Missing scripts/package_release.ps1'

$buildText = Get-Content -LiteralPath $buildScript -Raw
$packageText = Get-Content -LiteralPath $packageScript -Raw

foreach ($needle in @(
        'flutter pub get',
        'dart format --set-exit-if-changed .',
        'flutter analyze',
        'flutter test',
        'flutter test integration_test',
        'flutter build windows',
        'cargo build --locked --release',
        'codex-sessions-collector.exe',
        'codex-sessions-hub.exe',
        'codex-sessions-scan-launcher.exe',
        'codex_session_viewer.exe',
        'flutter_windows.dll',
        'data',
        'settings.sample.toml',
        'README.md',
        'sql',
        'assets'
    )) {
    Assert-True ($buildText.Contains($needle)) "build_windows.ps1 must include '$needle'"
}

foreach ($needle in @(
        'build_windows.ps1',
        'codex-sessions-collector.exe',
        'codex-sessions-hub.exe',
        'codex-sessions-scan-launcher.exe',
        'codex_session_viewer.exe',
        'flutter_windows.dll',
        'data',
        'README.md',
        'settings.sample.toml',
        'sql',
        'assets',
        'Compress-Archive',
        '-Path'
    )) {
    Assert-True ($packageText.Contains($needle)) "package_release.ps1 must include '$needle'"
}

$requiredRoots = @('app', 'collector', 'sql')
foreach ($root in $requiredRoots) {
    Assert-True (Test-Path -LiteralPath (Join-Path $repoRoot $root)) "Missing required repo folder '$root'"
}

$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('release-settings-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $fixtureRoot 'scripts') -Force | Out-Null
try {
    $fixtureScripts = Join-Path $fixtureRoot 'scripts'
    Copy-Item -LiteralPath $packageScript -Destination $fixtureScripts
    $sampleSettings = Join-Path $repoRoot 'settings.sample.toml'
    Assert-True (Test-Path -LiteralPath $sampleSettings -PathType Leaf) 'Missing settings.sample.toml'
    Copy-Item -LiteralPath $sampleSettings -Destination $fixtureRoot
    # Isolate package behavior from the expensive compiler/test pipeline.
    @'
param([string] $OutputDirectory)
if (-not (Test-Path -LiteralPath $OutputDirectory)) { throw 'Missing fixture build' }
$global:LASTEXITCODE = 0
'@ | Set-Content -LiteralPath (Join-Path $fixtureScripts 'build_windows.ps1') -Encoding utf8
    $fixtureBuild = Join-Path $fixtureRoot 'windows'
    $fixturePackage = Join-Path $fixtureRoot 'package'
    $fixtureArchive = Join-Path $fixtureRoot 'release.zip'
    New-Item -ItemType Directory -Path $fixtureBuild | Out-Null
    foreach ($name in @('codex_session_viewer.exe', 'codex-sessions-collector.exe', 'codex-sessions-hub.exe', 'codex-sessions-scan-launcher.exe', 'flutter_windows.dll', 'README.md')) {
        Set-Content -LiteralPath (Join-Path $fixtureBuild $name) -Value 'fixture'
    }
    foreach ($name in @('data', 'sql', 'assets')) {
        New-Item -ItemType Directory -Path (Join-Path $fixtureBuild $name) | Out-Null
        Set-Content -LiteralPath (Join-Path $fixtureBuild "$name\fixture.txt") -Value 'fixture'
    }
    $localSettings = Join-Path $fixtureBuild 'settings.toml'
    Set-Content -LiteralPath $localSettings -Value '[pricing.openrouter]', 'api_key = "private-test-marker"'
    Copy-Item -LiteralPath $sampleSettings -Destination (Join-Path $fixtureBuild 'settings.sample.toml')
    $localHash = Get-ContentHash $localSettings
    $sampleHash = Get-ContentHash $sampleSettings
    & (Join-Path $fixtureScripts 'package_release.ps1') -BuildOutputDirectory $fixtureBuild -PackageDirectory $fixturePackage -ArchivePath $fixtureArchive
    Assert-True ((Get-ContentHash $localSettings) -eq $localHash) 'Packaging changed local settings'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixturePackage 'settings.toml'))) 'Package contains runtime settings'
    Assert-True ((Get-ContentHash (Join-Path $fixturePackage 'settings.sample.toml')) -eq $sampleHash) 'Package sample differs from safe sample'
    $expanded = Join-Path $fixtureRoot 'expanded'
    Expand-Archive -LiteralPath $fixtureArchive -DestinationPath $expanded
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $expanded 'settings.toml'))) 'ZIP contains runtime settings'
    Assert-True ((Get-ContentHash (Join-Path $expanded 'settings.sample.toml')) -eq $sampleHash) 'ZIP sample differs from safe sample'
    $overlapRejected = $false
    try {
        & (Join-Path $fixtureScripts 'package_release.ps1') -BuildOutputDirectory $fixtureBuild -PackageDirectory $fixtureBuild -ArchivePath $fixtureArchive
    }
    catch {
        $overlapRejected = $_.Exception.Message -like '*separate, non-nested*'
    }
    Assert-True $overlapRejected 'Packaging must reject overlapping build/package directories'
    Assert-True ((Get-ContentHash $localSettings) -eq $localHash) 'Overlap rejection changed local settings'
}
finally {
    $resolvedFixture = [IO.Path]::GetFullPath($fixtureRoot)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $resolvedFixture.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Refusing cleanup outside the temporary directory.'
    }
    Remove-Item -LiteralPath $resolvedFixture -Recurse -Force
}

Write-Output 'Release script validation passed.'
