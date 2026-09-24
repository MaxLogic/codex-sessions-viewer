[CmdletBinding()]
param(
    [string] $OutputDirectory
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$appRoot = Join-Path $repoRoot 'app'
$collectorRoot = Join-Path $repoRoot 'collector'
$collectorManifest = Join-Path $collectorRoot 'Cargo.toml'
$collectorExeName = 'codex-sessions-collector.exe'
$sqlRoot = Join-Path $repoRoot 'sql'
$assetsRoot = Join-Path $repoRoot 'assets'
$settingsFile = Join-Path $repoRoot 'settings.toml'
$readmeFile = Join-Path $repoRoot 'README.md'

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $repoRoot 'release\windows'
}

function Resolve-Tool {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name,

        [string] $FallbackPath
    )

    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return $command.Source
    }

    if (-not [string]::IsNullOrWhiteSpace($FallbackPath) -and
        (Test-Path -LiteralPath $FallbackPath -PathType Leaf)) {
        return $FallbackPath
    }

    throw "Required tool '$Name' was not found. Add C:\tools\flutter\bin and the Rust toolchain (cargo) to PATH."
}

function Invoke-Step {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name,

        [Parameter(Mandatory = $true)]
        [scriptblock] $ScriptBlock
    )

    Write-Output "==> $Name"
    & $ScriptBlock
    if ($LASTEXITCODE -ne 0) {
        throw "$Name failed with exit code $LASTEXITCODE."
    }
}

function Copy-DirectoryClean {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Source,

        [Parameter(Mandatory = $true)]
        [string] $Destination
    )

    if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
        throw "Required folder '$Source' does not exist."
    }

    if (Test-Path -LiteralPath $Destination) {
        Remove-Item -LiteralPath $Destination -Recurse -Force
    }

    Copy-Item -LiteralPath $Source -Destination $Destination -Recurse -Force
}

function Write-FallbackReadme {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Destination
    )

    @'
# Codex Session Viewer

This package was generated before the full README was written.
See the project documentation in `docs/` for current implementation notes.
'@ | Set-Content -LiteralPath $Destination -Encoding utf8
}

if (-not (Test-Path -LiteralPath $appRoot -PathType Container)) {
    throw "Flutter app folder not found at '$appRoot'."
}
if (-not (Test-Path -LiteralPath $sqlRoot -PathType Container)) {
    throw "SQL folder not found at '$sqlRoot'."
}
if (-not (Test-Path -LiteralPath $settingsFile -PathType Leaf)) {
    throw "Default settings file not found at '$settingsFile'."
}

if (-not (Test-Path -LiteralPath $collectorManifest -PathType Leaf)) {
    throw "Collector manifest not found at '$collectorManifest'."
}

$flutter = Resolve-Tool -Name 'flutter' -FallbackPath 'C:\tools\flutter\bin\flutter.bat'
$dart = Resolve-Tool -Name 'dart' -FallbackPath 'C:\tools\flutter\bin\dart.bat'
$cargo = Resolve-Tool -Name 'cargo' -FallbackPath (Join-Path $env:USERPROFILE '.cargo\bin\cargo.exe')

Invoke-Step 'Check Flutter installation' { & $flutter --version }

# The collector links the C runtime statically (collector/.cargo/config.toml),
# so the release needs neither a Rust toolchain nor a VC++ redistributable.
Push-Location $collectorRoot
try {
    Invoke-Step 'Check collector formatting' { & $cargo fmt --check }
    Invoke-Step 'Lint collector' { & $cargo clippy --locked --all-targets -- -D warnings }
    Invoke-Step 'Test collector' { & $cargo test --locked --no-fail-fast }
    Invoke-Step 'Build collector release' { & $cargo build --locked --release }
}
finally {
    Pop-Location
}
$collectorBuildExe = Join-Path $collectorRoot "target\release\$collectorExeName"
if (-not (Test-Path -LiteralPath $collectorBuildExe -PathType Leaf)) {
    throw "Expected collector build output not found at '$collectorBuildExe'."
}

Push-Location $appRoot
try {
    Invoke-Step 'Install Flutter dependencies' { & $flutter pub get }
    Invoke-Step 'Check Dart formatting' { & $dart format --set-exit-if-changed . }
    Invoke-Step 'Analyze Flutter app' { & $flutter analyze }
    Invoke-Step 'Run Flutter tests' { & $flutter test }
    Invoke-Step 'Build Windows release' { & $flutter build windows }
}
finally {
    Pop-Location
}

$buildReleaseRoot = Join-Path $appRoot 'build\windows\x64\runner\Release'
$buildExe = Join-Path $buildReleaseRoot 'codex_sessions_viewer.exe'
if (-not (Test-Path -LiteralPath $buildExe -PathType Leaf)) {
    throw "Expected build output not found at '$buildExe'."
}

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
Copy-Item -Path (Join-Path $buildReleaseRoot '*') -Destination $OutputDirectory -Recurse -Force

$releaseExe = Join-Path $OutputDirectory 'codex_session_viewer.exe'
Copy-Item -LiteralPath $buildExe -Destination $releaseExe -Force
$originalReleaseExe = Join-Path $OutputDirectory 'codex_sessions_viewer.exe'
if (Test-Path -LiteralPath $originalReleaseExe -PathType Leaf) {
    Remove-Item -LiteralPath $originalReleaseExe -Force
}

$releaseCollector = Join-Path $OutputDirectory $collectorExeName
Copy-Item -LiteralPath $collectorBuildExe -Destination $releaseCollector -Force

$releaseReadme = Join-Path $OutputDirectory 'README.md'
if (Test-Path -LiteralPath $readmeFile -PathType Leaf) {
    Copy-Item -LiteralPath $readmeFile -Destination $releaseReadme -Force
}
else {
    Write-FallbackReadme -Destination $releaseReadme
}

$releaseSettings = Join-Path $OutputDirectory 'settings.toml'
$hasUsableReleaseSettings = (Test-Path -LiteralPath $releaseSettings -PathType Leaf) -and
    ((Get-Item -LiteralPath $releaseSettings).Length -gt 0)
if (-not $hasUsableReleaseSettings) {
    Copy-Item -LiteralPath $settingsFile -Destination $releaseSettings -Force
}

Copy-DirectoryClean -Source $sqlRoot -Destination (Join-Path $OutputDirectory 'sql')
Copy-DirectoryClean -Source $assetsRoot -Destination (Join-Path $OutputDirectory 'assets')

foreach ($requiredOutput in @(
        $releaseExe,
        $releaseCollector,
        (Join-Path $OutputDirectory 'flutter_windows.dll'),
        (Join-Path $OutputDirectory 'data'),
        $releaseReadme,
        $releaseSettings,
        (Join-Path $OutputDirectory 'sql'),
        (Join-Path $OutputDirectory 'assets')
    )) {
    if (-not (Test-Path -LiteralPath $requiredOutput)) {
        throw "Required release output missing: '$requiredOutput'."
    }
}

Write-Output "Windows release prepared at $OutputDirectory"
