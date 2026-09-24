[CmdletBinding()]
param(
    [string] $BuildOutputDirectory,
    [string] $PackageDirectory,
    [string] $ArchivePath
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$buildScript = Join-Path $PSScriptRoot 'build_windows.ps1'

if ([string]::IsNullOrWhiteSpace($BuildOutputDirectory)) {
    $BuildOutputDirectory = Join-Path $repoRoot 'release\windows'
}
if ([string]::IsNullOrWhiteSpace($PackageDirectory)) {
    $PackageDirectory = Join-Path $repoRoot 'release\package'
}
if ([string]::IsNullOrWhiteSpace($ArchivePath)) {
    $ArchivePath = Join-Path $repoRoot 'release\codex_session_viewer_windows.zip'
}

if (-not (Test-Path -LiteralPath $buildScript -PathType Leaf)) {
    throw "Build script not found at '$buildScript'."
}

& $buildScript -OutputDirectory $BuildOutputDirectory
if ($LASTEXITCODE -ne 0) {
    throw "build_windows.ps1 failed with exit code $LASTEXITCODE."
}

if (Test-Path -LiteralPath $PackageDirectory) {
    Remove-Item -LiteralPath $PackageDirectory -Recurse -Force
}
New-Item -ItemType Directory -Path $PackageDirectory -Force | Out-Null
Copy-Item -Path (Join-Path $BuildOutputDirectory '*') -Destination $PackageDirectory -Recurse -Force

foreach ($item in @(
        'codex_session_viewer.exe',
        'codex-sessions-collector.exe',
        'flutter_windows.dll',
        'data',
        'README.md',
        'settings.toml',
        'sql',
        'assets'
    )) {
    $source = Join-Path $BuildOutputDirectory $item
    if (-not (Test-Path -LiteralPath $source)) {
        throw "Required package source missing: '$source'."
    }
}

$archiveParent = Split-Path -Parent $ArchivePath
if (-not [string]::IsNullOrWhiteSpace($archiveParent)) {
    New-Item -ItemType Directory -Path $archiveParent -Force | Out-Null
}
if (Test-Path -LiteralPath $ArchivePath) {
    Remove-Item -LiteralPath $ArchivePath -Force
}

Compress-Archive -Path (Join-Path $PackageDirectory '*') -DestinationPath $ArchivePath -Force

if (-not (Test-Path -LiteralPath $ArchivePath -PathType Leaf)) {
    throw "Release archive was not created at '$ArchivePath'."
}

Write-Output "Release package prepared at $PackageDirectory"
Write-Output "Release archive created at $ArchivePath"
