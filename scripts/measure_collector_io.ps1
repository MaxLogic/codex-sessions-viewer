<#
.SYNOPSIS
Measures the bytes a collector build reads and writes per collection cycle.

.DESCRIPTION
Copies a database snapshot into a fresh work folder and runs one collector
build against it with process-level I/O accounting (GetProcessIoCounters).
Never point -SourceDatabase at the live database: make a snapshot first, for
example `sqlite3 "file:///<live>?mode=ro" "VACUUM INTO '<snapshot>'"`.

Phases:
- catch_up: one `codex scan` and one `claude scan` that bring the copy up to
  date with the session files on this machine (not compared between builds).
- idle: -IdleCycles repetitions of the same two scans with nothing changed,
  which is what the resident's five-minute background rescan does most of the
  time.
- active: when -ActiveFile is given, a copy of that session file under a new
  session id grows by -ActiveStepLines lines per step and is ingested after
  each step, which is what a Codex notify or Claude Stop hook does after a turn.

The session files on this machine are only read. The hook queue is isolated
in the work folder. Results go to -OutputFile as JSON and to the console.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Collector,
  [Parameter(Mandatory = $true)][string]$SourceDatabase,
  [Parameter(Mandatory = $true)][string]$Settings,
  [Parameter(Mandatory = $true)][string]$WorkRoot,
  [ValidateRange(0, 100)][int]$IdleCycles = 3,
  [string]$ActiveFile,
  [ValidateSet('codex', 'claude')][string]$ActiveHarness = 'claude',
  [ValidateRange(1, 100000)][int]$ActiveStepLines = 20,
  [ValidateRange(1, 100)][int]$ActiveSteps = 5,
  [string]$OutputFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not ('CollectorIo.Native' -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace CollectorIo {
  [StructLayout(LayoutKind.Sequential)]
  public struct IoCounters {
    public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount;
    public ulong ReadTransferCount, WriteTransferCount, OtherTransferCount;
  }
  public static class Native {
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetProcessIoCounters(IntPtr process, out IoCounters counters);
  }
}
'@
}

function Invoke-Measured {
  param(
    [Parameter(Mandatory = $true)][string]$Label,
    [Parameter(Mandatory = $true)][string[]]$Arguments
  )
  $info = [Diagnostics.ProcessStartInfo]::new($Collector)
  foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
  $info.RedirectStandardOutput = $true
  $info.RedirectStandardError = $true
  $info.UseShellExecute = $false
  $info.CreateNoWindow = $true
  $info.Environment['CODEX_SESSIONS_COLLECTOR_QUEUE'] = $queue
  $info.Environment['CODEX_SESSIONS_COLLECTOR_TIMINGS'] = '1'
  $watch = [Diagnostics.Stopwatch]::StartNew()
  $process = [Diagnostics.Process]::Start($info)
  try {
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    $watch.Stop()
    $counters = [CollectorIo.IoCounters]::new()
    if (-not [CollectorIo.Native]::GetProcessIoCounters($process.Handle, [ref]$counters)) {
      throw "GetProcessIoCounters failed for $Label"
    }
    $stderr = $stderrTask.GetAwaiter().GetResult()
    $null = $stdoutTask.GetAwaiter().GetResult()
    Add-Content -LiteralPath $timingsLog -Value "== $Label (exit $($process.ExitCode))`n$stderr"
    if ($process.ExitCode -ne 0) {
      throw "$Label exited $($process.ExitCode): $stderr"
    }
    $result = [pscustomobject]@{
      label = $Label
      milliseconds = $watch.ElapsedMilliseconds
      read_bytes = [int64]$counters.ReadTransferCount
      write_bytes = [int64]$counters.WriteTransferCount
      read_ops = [int64]$counters.ReadOperationCount
      write_ops = [int64]$counters.WriteOperationCount
    }
    $results.Add($result)
    '{0,-22} {1,8:N0} ms  read {2,10:N1} MB  write {3,8:N2} MB  ({4:N0} reads, {5:N0} writes)' -f `
      $Label, $result.milliseconds, ($result.read_bytes / 1MB), ($result.write_bytes / 1MB), $result.read_ops, $result.write_ops |
      Write-Information -InformationAction Continue
  }
  finally {
    $process.Dispose()
  }
}

function Invoke-Cycle {
  param([Parameter(Mandatory = $true)][string]$Label)
  Invoke-Measured "$Label codex" @('codex', 'scan', '--db', $database, '--settings', $Settings, '--json')
  Invoke-Measured "$Label claude" @('claude', 'scan', '--db', $database, '--settings', $Settings, '--json')
}

$WorkRoot = [IO.Path]::GetFullPath($WorkRoot)
if (Test-Path -LiteralPath $WorkRoot) {
  throw "Work root already exists; choose a new one: $WorkRoot"
}
$null = New-Item -ItemType Directory -Path $WorkRoot
$queue = Join-Path $WorkRoot 'queue'
$null = New-Item -ItemType Directory -Path $queue
$timingsLog = Join-Path $WorkRoot 'timings.log'
$database = Join-Path $WorkRoot 'viewer.sqlite'
Copy-Item -LiteralPath $SourceDatabase -Destination $database
$results = [Collections.Generic.List[object]]::new()

Invoke-Cycle 'catch_up'
for ($cycle = 1; $cycle -le $IdleCycles; $cycle++) {
  Invoke-Cycle "idle $cycle"
}

if ($ActiveFile) {
  $lines = [IO.File]::ReadAllLines($ActiveFile)
  $name = [IO.Path]::GetFileName($ActiveFile)
  $match = [regex]::Match($name, '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}')
  if (-not $match.Success) { throw "No session id in file name: $name" }
  $oldId = $match.Value
  $newId = [guid]::NewGuid().ToString()
  $sessionDirectory = Join-Path $WorkRoot 'active'
  $null = New-Item -ItemType Directory -Path $sessionDirectory
  $sessionFile = Join-Path $sessionDirectory $name.Replace($oldId, $newId)
  $lines = $lines | ForEach-Object { $_.Replace($oldId, $newId) }
  $start = [Math]::Max(1, $lines.Count - $ActiveSteps * $ActiveStepLines)
  [IO.File]::WriteAllLines($sessionFile, [string[]]$lines[0..($start - 1)])
  Invoke-Measured 'active initial' @($ActiveHarness, 'ingest', '--db', $database, '--settings', $Settings, $sessionFile)
  for ($step = 1; $step -le $ActiveSteps; $step++) {
    $end = [Math]::Min($lines.Count, $start + $step * $ActiveStepLines) - 1
    $from = $start + ($step - 1) * $ActiveStepLines
    if ($from -gt $end) { break }
    [IO.File]::AppendAllLines($sessionFile, [string[]]$lines[$from..$end])
    Invoke-Measured "active step $step" @($ActiveHarness, 'ingest', '--db', $database, '--settings', $Settings, $sessionFile)
  }
}

$idle = @($results | Where-Object label -like 'idle *')
$active = @($results | Where-Object label -like 'active step *')
$summary = [ordered]@{
  collector = $Collector
  source_database = $SourceDatabase
  database_bytes_after = (Get-Item -LiteralPath $database).Length
  idle_cycle_mean = if ($idle.Count) {
    [ordered]@{
      milliseconds = [int64](($idle | Measure-Object milliseconds -Sum).Sum / $IdleCycles)
      read_bytes = [int64](($idle | Measure-Object read_bytes -Sum).Sum / $IdleCycles)
      write_bytes = [int64](($idle | Measure-Object write_bytes -Sum).Sum / $IdleCycles)
    }
  }
  active_step_mean = if ($active.Count) {
    [ordered]@{
      milliseconds = [int64](($active | Measure-Object milliseconds -Average).Average)
      read_bytes = [int64](($active | Measure-Object read_bytes -Average).Average)
      write_bytes = [int64](($active | Measure-Object write_bytes -Average).Average)
    }
  }
  runs = $results
}
$json = $summary | ConvertTo-Json -Depth 5
if ($OutputFile) { Set-Content -LiteralPath $OutputFile -Value $json }
$json
