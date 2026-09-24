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
        'codex_session_viewer.exe',
        'flutter_windows.dll',
        'data',
        'settings.toml',
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
        'codex_session_viewer.exe',
        'flutter_windows.dll',
        'data',
        'README.md',
        'settings.toml',
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
    foreach ($name in @('codex_session_viewer.exe', 'codex-sessions-collector.exe', 'codex-sessions-hub.exe', 'flutter_windows.dll', 'README.md')) {
        Set-Content -LiteralPath (Join-Path $fixtureBuild $name) -Value 'fixture'
    }
    foreach ($name in @('data', 'sql', 'assets')) {
        New-Item -ItemType Directory -Path (Join-Path $fixtureBuild $name) | Out-Null
        Set-Content -LiteralPath (Join-Path $fixtureBuild "$name\fixture.txt") -Value 'fixture'
    }
    $localSettings = Join-Path $fixtureBuild 'settings.toml'
    Set-Content -LiteralPath $localSettings -Value '[pricing.openrouter]', 'api_key = "private-test-marker"'
    $localHash = (Get-FileHash -LiteralPath $localSettings).Hash
    $sampleHash = (Get-FileHash -LiteralPath $sampleSettings).Hash
    & (Join-Path $fixtureScripts 'package_release.ps1') -BuildOutputDirectory $fixtureBuild -PackageDirectory $fixturePackage -ArchivePath $fixtureArchive
    Assert-True ((Get-FileHash -LiteralPath $localSettings).Hash -eq $localHash) 'Packaging changed local settings'
    Assert-True ((Get-FileHash -LiteralPath (Join-Path $fixturePackage 'settings.toml')).Hash -eq $sampleHash) 'Package settings differ from safe sample'
    $expanded = Join-Path $fixtureRoot 'expanded'
    Expand-Archive -LiteralPath $fixtureArchive -DestinationPath $expanded
    Assert-True ((Get-FileHash -LiteralPath (Join-Path $expanded 'settings.toml')).Hash -eq $sampleHash) 'ZIP settings differ from safe sample'
    $overlapRejected = $false
    try {
        & (Join-Path $fixtureScripts 'package_release.ps1') -BuildOutputDirectory $fixtureBuild -PackageDirectory $fixtureBuild -ArchivePath $fixtureArchive
    }
    catch {
        $overlapRejected = $_.Exception.Message -like '*separate, non-nested*'
    }
    Assert-True $overlapRejected 'Packaging must reject overlapping build/package directories'
    Assert-True ((Get-FileHash -LiteralPath $localSettings).Hash -eq $localHash) 'Overlap rejection changed local settings'
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
