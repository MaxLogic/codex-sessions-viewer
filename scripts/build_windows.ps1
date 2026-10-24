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
$hubExeName = 'codex-sessions-hub.exe'
$launcherExeName = 'codex-sessions-scan-launcher.exe'
$sqlRoot = Join-Path $repoRoot 'sql'
$assetsRoot = Join-Path $repoRoot 'assets'
$settingsFile = Join-Path $repoRoot 'settings.sample.toml'
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

function Resolve-ReleaseFinalPath {
    param([string] $LiteralPath)
    if (-not ('CxvReleaseFinalPath' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
public static class CxvReleaseFinalPath {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFile(string path, uint access, uint share,
        IntPtr security, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint GetFinalPathNameByHandle(SafeFileHandle handle,
        StringBuilder path, uint length, uint flags);
    public static string Resolve(string path) {
        // Follow all reparse points. BACKUP_SEMANTICS also permits directories.
        using (var handle = CreateFile(path, 0, 7, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero)) {
            if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
            var buffer = new StringBuilder(512);
            uint length = GetFinalPathNameByHandle(handle, buffer, (uint)buffer.Capacity, 0);
            if (length == 0) throw new Win32Exception(Marshal.GetLastWin32Error());
            if (length >= buffer.Capacity) {
                buffer = new StringBuilder(checked((int)length + 1));
                length = GetFinalPathNameByHandle(handle, buffer, (uint)buffer.Capacity, 0);
                if (length == 0 || length >= buffer.Capacity)
                    throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            return buffer.ToString();
        }
    }
}
'@
    }
    return [CxvReleaseFinalPath]::Resolve([IO.Path]::GetFullPath($LiteralPath))
}

function Test-ReleaseProcessPath {
    param([string] $ImagePath, [string] $ReleaseDirectory)
    if ([string]::IsNullOrWhiteSpace($ImagePath)) { return $false }
    try {
        $output = Resolve-ReleaseFinalPath -LiteralPath $ReleaseDirectory
        $image = Resolve-ReleaseFinalPath -LiteralPath $ImagePath
        $prefix = $output.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
        $owned = $image.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
        $lexicalPrefix = [IO.Path]::GetFullPath($ReleaseDirectory).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
        if (-not $owned -and [IO.Path]::GetFullPath($ImagePath).StartsWith($lexicalPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            Write-Warning "Image '$ImagePath' resolves outside the output folder; leaving it running."
        }
        return $owned
    } catch {
        Write-Warning "Cannot establish physical output-folder ownership for '$ImagePath'; leaving it running: $_"
        return $false
    }
}

function Get-ReleaseResidentEndpoint {
    param([string] $CollectorPath, [string] $Database)
    $outputFile = [IO.Path]::GetTempFileName()
    $probe = $null
    try {
        $probe = Start-Process -FilePath $CollectorPath -WindowStyle Hidden -PassThru `
            -ArgumentList @('resident', 'info', '--db', ('"' + $Database + '"')) -RedirectStandardOutput $outputFile
        if (-not $probe.WaitForExit(2000)) {
            $probe.Kill()
            [void] $probe.WaitForExit(1000)
            throw 'Resident endpoint query timed out.'
        }
        if ($probe.ExitCode -ne 0) { throw "Resident endpoint query returned $($probe.ExitCode)." }
        $info = Get-Content -LiteralPath $outputFile -Raw | ConvertFrom-Json -ErrorAction Stop
        if ($info.v -ne 1 -or -not $info.endpoint.StartsWith('\\.\pipe\', [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Resident endpoint query returned an invalid local pipe.'
        }
        return $info.endpoint.Substring(9)
    } finally {
        if ($null -ne $probe) { $probe.Dispose() }
        Remove-Item -LiteralPath $outputFile -Force -ErrorAction Stop
    }
}

function Open-ReleaseResidentConnection {
    param([string] $Endpoint)
    $pipe = [IO.Pipes.NamedPipeClientStream]::new('.', $Endpoint, [IO.Pipes.PipeDirection]::InOut, [IO.Pipes.PipeOptions]::Asynchronous)
    try {
        $pipe.Connect(2000)
        $encoding = [Text.UTF8Encoding]::new($false)
        $reader = [IO.StreamReader]::new($pipe, $encoding, $false, 1024, $true)
        $writer = [IO.StreamWriter]::new($pipe, $encoding, 1024, $true)
        $writer.NewLine = "`n"
        $writer.AutoFlush = $true
        return [pscustomobject]@{ Pipe = $pipe; Reader = $reader; Writer = $writer }
    } catch {
        $pipe.Dispose()
        throw
    }
}

function Send-ReleaseResidentRequest {
    param($Connection, [ValidateSet('status', 'shutdown')][string] $Operation)
    $requestId = "build-$Operation"
    $Connection.Writer.WriteLine((@{v=1; id=$requestId; op=$Operation} | ConvertTo-Json -Compress))
    $read = $Connection.Reader.ReadLineAsync()
    if (-not $read.Wait(2000)) { throw 'Resident control reply timed out.' }
    if ($null -eq $read.Result -or $read.Result.Length -gt 1048576) { throw 'Resident control reply was missing or oversized.' }
    $reply = $read.Result | ConvertFrom-Json -ErrorAction Stop
    if ($reply.v -ne 1 -or $reply.id -ne $requestId -or $reply.event -eq 'error') { throw 'Resident refused the control request.' }
    return $reply
}

function Invoke-ReleaseResidentStop {
    param([string] $CollectorPath, [string] $Database, [string] $ReleaseDirectory)
    $connection = $null
    $owner = $null
    $checkedOwner = $null
    try {
        $endpoint = Get-ReleaseResidentEndpoint -CollectorPath $CollectorPath -Database $Database
        if ([string]::IsNullOrWhiteSpace($endpoint)) { return }
        $connection = Open-ReleaseResidentConnection -Endpoint $endpoint
        $status = Send-ReleaseResidentRequest -Connection $connection -Operation status
        if ($status.event -ne 'status' -or $status.pid -le 0) { throw 'Resident status did not identify its process.' }
        $owner = Get-Process -Id $status.pid -ErrorAction SilentlyContinue
        if ($null -eq $owner -or -not (Test-ReleaseProcessPath $owner.Path $ReleaseDirectory)) { return }
        $started = $owner.StartTime
        $image = $owner.Path
        # Recheck image and creation time immediately before acting. Shutdown is
        # sent on this SAME connection: a replacement endpoint cannot receive it.
        $checkedOwner = Get-Process -Id $status.pid -ErrorAction SilentlyContinue
        if ($null -eq $checkedOwner -or $checkedOwner.StartTime -ne $started -or $checkedOwner.Path -ne $image -or
            -not (Test-ReleaseProcessPath $checkedOwner.Path $ReleaseDirectory)) { return }
        [void] (Send-ReleaseResidentRequest -Connection $connection -Operation shutdown)
        if (-not $owner.WaitForExit(10000)) { Write-Warning 'Resident shutdown timed out; stopping remaining output-folder processes.' }
    } catch {
        Write-Warning "Scoped resident shutdown unavailable: $_. Stopping only output-folder processes."
    } finally {
        if ($null -ne $connection) {
            foreach ($stream in @($connection.Reader, $connection.Writer, $connection.Pipe)) {
                if ($null -ne $stream) { $stream.Dispose() }
            }
        }
        foreach ($process in @($owner, $checkedOwner)) {
            if ($process -is [IDisposable]) { $process.Dispose() }
        }
    }
}

function Stop-ReleaseProcess {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter(Mandatory = $true)][string] $ReleaseDirectory)
    $target = [IO.Path]::GetFullPath($ReleaseDirectory)
    if (-not $PSCmdlet.ShouldProcess($target, 'Stop resident and remaining output-folder processes')) { return }
    $collectorPath = Join-Path $target 'codex-sessions-collector.exe'
    if (Test-Path -LiteralPath $collectorPath -PathType Leaf) {
        $dataRoot = if ([string]::IsNullOrWhiteSpace($env:APPDATA)) { $target } else {
            Join-Path $env:APPDATA 'CodexSessionViewer'
        }
        $database = Join-Path $dataRoot 'codex_sessions_viewer.sqlite'
        Invoke-ReleaseResidentStop -CollectorPath $collectorPath -Database $database -ReleaseDirectory $target
    }
    # Refresh and recheck each PID's image immediately before stopping it.
    foreach ($candidate in @(Get-CimInstance Win32_Process)) {
        if (-not (Test-ReleaseProcessPath -ImagePath $candidate.ExecutablePath -ReleaseDirectory $target)) { continue }
        $process = Get-Process -Id $candidate.ProcessId -ErrorAction SilentlyContinue
        if ($null -ne $process -and (Test-ReleaseProcessPath -ImagePath $process.Path -ReleaseDirectory $target)) {
            Stop-Process -InputObject $process -Force -ErrorAction Stop
            if (-not $process.WaitForExit(10000)) { throw "Output-folder process $($candidate.ProcessId) did not stop." }
        }
    }
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
. (Join-Path $PSScriptRoot 'test_support/TestEnvironment.ps1')
$testEnvironment = New-TestEnvironment
Push-Location $collectorRoot
try {
    Invoke-Step 'Check collector formatting' { & $cargo fmt --check }
    Invoke-Step 'Lint collector' { & $cargo clippy --locked --all-targets -- -D warnings }
    Invoke-Step 'Test collector' { Invoke-TestProcess -Context $testEnvironment -FilePath $cargo -ArgumentList @('test', '--locked', '--no-fail-fast') -WorkingDirectory $collectorRoot }
    Invoke-Step 'Build collector and hub release' { & $cargo build --locked --release --bins }
}
finally {
    Pop-Location
}
$collectorBuildExe = Join-Path $collectorRoot "target\release\$collectorExeName"
if (-not (Test-Path -LiteralPath $collectorBuildExe -PathType Leaf)) {
    throw "Expected collector build output not found at '$collectorBuildExe'."
}
$hubBuildExe = Join-Path $collectorRoot "target\release\$hubExeName"
if (-not (Test-Path -LiteralPath $hubBuildExe -PathType Leaf)) {
    throw "Expected hub build output not found at '$hubBuildExe'."
}
$launcherBuildExe = Join-Path $collectorRoot "target\release\$launcherExeName"
if (-not (Test-Path -LiteralPath $launcherBuildExe -PathType Leaf)) {
    throw "Expected scan launcher build output not found at '$launcherBuildExe'."
}

Push-Location $appRoot
try {
    Invoke-Step 'Install Flutter dependencies' { & $flutter pub get }
    Invoke-Step 'Check Dart formatting' { & $dart format --set-exit-if-changed . }
    Invoke-Step 'Analyze Flutter app' { & $flutter analyze }
    $testEnvironment.Variables['CODEX_SESSIONS_COLLECTOR_EXE'] = $collectorBuildExe
    $testEnvironment.Variables['CODEX_SESSIONS_HUB_EXE'] = $hubBuildExe
    Invoke-Step 'Run Flutter tests' { Invoke-TestProcess -Context $testEnvironment -FilePath $flutter -ArgumentList @('test') -WorkingDirectory $appRoot }
    Invoke-Step 'Run Flutter integration tests' { Invoke-TestProcess -Context $testEnvironment -FilePath $flutter -ArgumentList @('test', 'integration_test') -WorkingDirectory $appRoot }
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

Stop-ReleaseProcess -ReleaseDirectory $OutputDirectory
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
Get-ChildItem -LiteralPath $buildReleaseRoot -Force |
    Where-Object { $_.Name -ne 'settings.toml' } |
    ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $OutputDirectory -Recurse -Force }

$releaseExe = Join-Path $OutputDirectory 'codex_session_viewer.exe'
Copy-Item -LiteralPath $buildExe -Destination $releaseExe -Force
$originalReleaseExe = Join-Path $OutputDirectory 'codex_sessions_viewer.exe'
if (Test-Path -LiteralPath $originalReleaseExe -PathType Leaf) {
    Remove-Item -LiteralPath $originalReleaseExe -Force
}

$releaseCollector = Join-Path $OutputDirectory $collectorExeName
Copy-Item -LiteralPath $collectorBuildExe -Destination $releaseCollector -Force
$releaseHub = Join-Path $OutputDirectory $hubExeName
Copy-Item -LiteralPath $hubBuildExe -Destination $releaseHub -Force
$releaseLauncher = Join-Path $OutputDirectory $launcherExeName
Copy-Item -LiteralPath $launcherBuildExe -Destination $releaseLauncher -Force

$releaseReadme = Join-Path $OutputDirectory 'README.md'
if (Test-Path -LiteralPath $readmeFile -PathType Leaf) {
    Copy-Item -LiteralPath $readmeFile -Destination $releaseReadme -Force
}
else {
    Write-FallbackReadme -Destination $releaseReadme
}

$releaseSampleSettings = Join-Path $OutputDirectory 'settings.sample.toml'
Copy-Item -LiteralPath $settingsFile -Destination $releaseSampleSettings -Force

Copy-DirectoryClean -Source $sqlRoot -Destination (Join-Path $OutputDirectory 'sql')
Copy-DirectoryClean -Source $assetsRoot -Destination (Join-Path $OutputDirectory 'assets')

foreach ($requiredOutput in @(
        $releaseExe,
        $releaseCollector,
        $releaseHub,
        (Join-Path $OutputDirectory 'flutter_windows.dll'),
        (Join-Path $OutputDirectory 'data'),
        $releaseReadme,
        $releaseSampleSettings,
        (Join-Path $OutputDirectory 'sql'),
        (Join-Path $OutputDirectory 'assets')
    )) {
    if (-not (Test-Path -LiteralPath $requiredOutput)) {
        throw "Required release output missing: '$requiredOutput'."
    }
}

Write-Output "Windows release prepared at $OutputDirectory"
