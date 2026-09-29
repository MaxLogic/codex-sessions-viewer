[CmdletBinding()]
param(
    [string] $BuildOutputDirectory,
    [string] $PackageDirectory,
    [string] $ArchivePath
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$buildScript = Join-Path $PSScriptRoot 'build_windows.ps1'
$sampleSettings = Join-Path $repoRoot 'settings.sample.toml'

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
if (-not (Test-Path -LiteralPath $sampleSettings -PathType Leaf)) {
    throw "Sample settings file not found at '$sampleSettings'."
}

$buildFullPath = [IO.Path]::GetFullPath($BuildOutputDirectory).TrimEnd('\', '/')
$packageFullPath = [IO.Path]::GetFullPath($PackageDirectory).TrimEnd('\', '/')
if ($buildFullPath.Equals($packageFullPath, [StringComparison]::OrdinalIgnoreCase) -or
    $buildFullPath.StartsWith($packageFullPath + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
    $packageFullPath.StartsWith($buildFullPath + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Build and package directories must be separate, non-nested folders.'
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
# Local build settings belong to this machine. Always replace the packaged copy.
Copy-Item -LiteralPath $sampleSettings -Destination (Join-Path $PackageDirectory 'settings.toml') -Force

foreach ($item in @(
        'codex_session_viewer.exe',
        'codex-sessions-collector.exe',
        'codex-sessions-hub.exe',
        'codex-sessions-scan-launcher.exe',
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
