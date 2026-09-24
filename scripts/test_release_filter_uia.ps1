#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$ReleaseDirectory = '',
    [ValidateRange(5, 120)][int]$TimeoutSeconds = 120
)
$ErrorActionPreference = 'Stop'


if (-not $ReleaseDirectory) { $ReleaseDirectory = Join-Path $PSScriptRoot '..\release\package' }
$python = Get-Command python -ErrorAction SilentlyContinue
if ($null -eq $python) { throw 'Windows Python with the uiautomation package is required.' }
& $python.Source -c "import sys; assert sys.platform == 'win32'; import uiautomation" 2>$null
if ($LASTEXITCODE -ne 0) { throw 'Windows Python with the uiautomation package is required. Install it in the Python environment used by this command.' }
$release = (Resolve-Path -LiteralPath $ReleaseDirectory).Path
$sourceExe = Join-Path $release 'codex_session_viewer.exe'
if (-not (Test-Path -LiteralPath $sourceExe)) { throw "Missing packaged executable: $sourceExe" }
$runRoot = Join-Path ([IO.Path]::GetTempPath()) ('csv-uia-smoke-' + [guid]::NewGuid().ToString('N'))
$appDirectory = Join-Path $runRoot 'app'
$process = $null
try {
    New-Item -ItemType Directory -Path $appDirectory -Force | Out-Null
    Get-ChildItem -LiteralPath $release | Where-Object { $_.Name -notin @('settings.toml', 'logs') } | Copy-Item -Destination $appDirectory -Recurse
    $emptySource = Join-Path $runRoot 'empty-sessions'
    New-Item -ItemType Directory -Path $emptySource | Out-Null
    $settings = @"
[app]
first_run = false
start_with_windows = false
[paths]
windows_codex_path = '$emptySource'
wsl_codex_unc_path = '$emptySource'
[scanner]
background_rescan_enabled = false
[voice_over]
enabled = false
"@
    [IO.File]::WriteAllText((Join-Path $appDirectory 'settings.toml'), $settings, (New-Object Text.UTF8Encoding($false)))
    $start = New-Object System.Diagnostics.ProcessStartInfo
    $start.FileName = Join-Path $appDirectory 'codex_session_viewer.exe'
    $start.WorkingDirectory = $appDirectory
    $start.UseShellExecute = $false
    $start.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $start.EnvironmentVariables['APPDATA'] = Join-Path $runRoot 'roaming'
    $start.EnvironmentVariables['LOCALAPPDATA'] = Join-Path $runRoot 'local'
    $start.EnvironmentVariables['USERPROFILE'] = Join-Path $runRoot 'profile'
    $process = [System.Diagnostics.Process]::Start($start)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $process.Refresh()
        if ($process.HasExited) { throw 'Packaged application exited during startup.' }
        if ($process.MainWindowHandle -ne 0) { break }
        Start-Sleep -Milliseconds 150
    } while ([DateTime]::UtcNow -lt $deadline)
    if ($process.MainWindowHandle -eq 0) { throw 'No application window appeared.' }
    $probePath = Join-Path $runRoot 'probe.py'
    $probeSource = @'
import sys, time
import uiautomation as uia
root = uia.ControlFromHandle(int(sys.argv[1]))
timeout = int(sys.argv[2])
def find(name):
    pending = [(root, 0)]
    while pending:
        node, depth = pending.pop()
        if node.Name == name:
            return node
        if depth < 30:
            pending.extend((child, depth + 1) for child in node.GetChildren())
    return None
def wait(name, absent=False):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        node = find(name)
        if absent and node is None:
            return
        if not absent and node is not None:
            return node
        time.sleep(.15)
    raise RuntimeError(f'Timed out waiting for {name!r} (absent={absent})')
for name, value in [('Project filter', 'All projects'), ('Model filter', 'All models'),
                    ('Platform filter', 'Windows only'), ('Origin filter', 'Subagents only')]:
    button = wait(name)
    assert button.ControlTypeName == 'ButtonControl', (name, button.ControlTypeName)
    assert button.IsEnabled, (name, 'disabled')
    assert not button.IsOffscreen, (name, 'offscreen')
    button.GetInvokePattern().Invoke()
    wait('Popup menu')
    option = wait(value)
    assert option.IsEnabled, (value, 'disabled')
    option.GetInvokePattern().Invoke()
    wait('Popup menu', absent=True)
    button = wait(name)
    actual = button.GetLegacyIAccessiblePattern().Value
    assert actual == value, (name, 'unexpected value', actual, value)
    print(f'PASS: {name}; Button; enabled; onscreen; Invoke opened menu; selection closed menu; value={actual}', flush=True)
'@
    [IO.File]::WriteAllText($probePath, $probeSource, (New-Object Text.UTF8Encoding($false)))
    & $python.Source -E $probePath $process.MainWindowHandle $TimeoutSeconds
    if ($LASTEXITCODE -ne 0) { throw "UIA probe failed with exit code $LASTEXITCODE." }
    Write-Output "PASS: packaged executable SHA256=$((Get-FileHash -LiteralPath $start.FileName -Algorithm SHA256).Hash)"
    Write-Output "PASS: packaged Dart payload SHA256=$((Get-FileHash -LiteralPath (Join-Path $appDirectory 'data\app.so') -Algorithm SHA256).Hash)"
}
finally {
    if ($null -ne $process -and -not $process.HasExited) { Stop-Process -Id $process.Id -Force; $process.WaitForExit() }
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    $resolvedRun = [IO.Path]::GetFullPath($runRoot)
    if (-not $resolvedRun.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Refusing cleanup outside temporary directory.' }
    if (Test-Path -LiteralPath $resolvedRun) {
        for ($attempt = 0; $attempt -lt 20; $attempt++) {
            try { Remove-Item -LiteralPath $resolvedRun -Recurse -Force; break }
            catch { if ($attempt -eq 19) { Write-Warning "Temporary cleanup incomplete: $resolvedRun : $_" }; Start-Sleep -Milliseconds 250 }
        }
    }
}




