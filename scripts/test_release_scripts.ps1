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
        'flutter build windows',
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

$requiredRoots = @('app', 'sql')
foreach ($root in $requiredRoots) {
    Assert-True (Test-Path -LiteralPath (Join-Path $repoRoot $root)) "Missing required repo folder '$root'"
}

Write-Output 'Release script validation passed.'
