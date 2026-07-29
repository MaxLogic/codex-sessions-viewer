[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet('SelfTest', 'InternalSelfTestChild', 'LargestAndTopEight', 'FullCorpus', 'Warm')]
  [string]$Mode,

  [string]$CorpusDirectory = '.agents\private-session-corpus',

  [string]$OutputFile,

  [string]$WorkerCounts = '1,2,4,8',

  [ValidateRange(1, 10000)]
  [int]$PersistenceBatchSize = 250,

  [ValidateRange(1, 10)]
  [int]$MatrixRepetitions = 3,

  [string]$ProbeExecutablePath,

  [ValidateRange(0, 1024)]
  [int]$ChildAllocationMb = 0,

  [ValidateRange(0, 255)]
  [int]$ChildExitCode = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-CommandLineArgument {
  param([Parameter(Mandatory = $true)][string]$Value)

  return '"' + $Value.Replace('"', '\"') + '"'
}

function Invoke-SampledProcess {
  param(
    [Parameter(Mandatory = $true)][string]$Executable,
    [Parameter(Mandatory = $true)][string[]]$Arguments,
    [Parameter(Mandatory = $true)][string]$WorkingDirectory
  )

  $argumentText = (($Arguments | ForEach-Object {
        ConvertTo-CommandLineArgument -Value $_
      }) -join ' ')
  $startInfo = [Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = $Executable
  $startInfo.Arguments = $argumentText
  $startInfo.WorkingDirectory = $WorkingDirectory
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  $process = [Diagnostics.Process]::new()
  $process.StartInfo = $startInfo
  $stopwatch = [Diagnostics.Stopwatch]::StartNew()
  if (-not $process.Start()) {
    throw "Failed to start $Executable."
  }
  $stdoutTask = $process.StandardOutput.ReadToEndAsync()
  $stderrTask = $process.StandardError.ReadToEndAsync()
  $peakPrivateBytes = [int64]0
  try {
    while (-not $process.HasExited) {
      $process.Refresh()
      if ($process.PrivateMemorySize64 -gt $peakPrivateBytes) {
        $peakPrivateBytes = $process.PrivateMemorySize64
      }
      Start-Sleep -Milliseconds 100
    }
    $process.WaitForExit()
    $process.Refresh()
    if ($process.PrivateMemorySize64 -gt $peakPrivateBytes) {
      $peakPrivateBytes = $process.PrivateMemorySize64
    }
    $stopwatch.Stop()
    $exitCode = $process.ExitCode
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    return [pscustomobject]@{
      ExitCode = $exitCode
      ElapsedMilliseconds = $stopwatch.ElapsedMilliseconds
      PeakPrivateBytes = $peakPrivateBytes
      Stdout = $stdout
      Stderr = $stderr
    }
  }
  finally {
    if (-not $process.HasExited) {
      Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    }
    $process.Dispose()
  }
}

function Get-MetadataManifestHash {
  param([Parameter(Mandatory = $true)][IO.FileInfo[]]$Files)

  $lines = foreach ($file in $Files) {
    $file.Refresh()
    '{0}|{1}|{2}' -f $file.FullName.ToLowerInvariant(), $file.Length, $file.LastWriteTimeUtc.Ticks
  }
  $text = (($lines | Sort-Object) -join "`n") + "`n"
  $bytes = [Text.UTF8Encoding]::new($false).GetBytes($text)
  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
  }
  finally {
    $sha.Dispose()
  }
}

function Get-PeArchitecture {
  param([Parameter(Mandatory = $true)][string]$Executable)

  $stream = [IO.File]::OpenRead($Executable)
  $reader = [IO.BinaryReader]::new($stream)
  try {
    $stream.Position = 0x3c
    $peOffset = $reader.ReadInt32()
    $stream.Position = $peOffset
    if ($reader.ReadUInt32() -ne 0x00004550) {
      throw 'The benchmark executable does not have a valid PE signature.'
    }
    $machine = $reader.ReadUInt16()
    $architecture = switch ($machine) {
      '34404' { 'x64' }
      '332' { 'x86' }
      '43620' { 'arm64' }
      default { 'unknown_0x{0:x4}' -f $machine }
    }
    return $architecture
  }
  finally {
    $reader.Dispose()
    $stream.Dispose()
  }
}

function Expand-FilesToCount {
  param(
    [Parameter(Mandatory = $true)][IO.FileInfo[]]$Files,
    [Parameter(Mandatory = $true)][int]$Count
  )

  if ($Files.Count -eq 0) {
    throw 'Cannot expand an empty file set.'
  }
  return @(
    for ($index = 0; $index -lt $Count; $index++) {
      $Files[$index % $Files.Count]
    }
  )
}

function Initialize-HardLinkCorpus {
  param(
    [Parameter(Mandatory = $true)][IO.FileInfo[]]$Files,
    [Parameter(Mandatory = $true)][string]$ParentDirectory
  )

  $directory = Join-Path $ParentDirectory ('scan-memory-input-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $directory | Out-Null
  for ($index = 0; $index -lt $Files.Count; $index++) {
    $name = '{0:D8}.jsonl' -f $index
    New-Item -ItemType HardLink -Path (Join-Path $directory $name) -Target $Files[$index].FullName | Out-Null
  }
  return $directory
}

function Close-HardLinkCorpus {
  param(
    [Parameter(Mandatory = $true)][string]$Directory,
    [Parameter(Mandatory = $true)][string]$ExpectedParent
  )

  $resolvedDirectory = [IO.Path]::GetFullPath($Directory)
  $resolvedParent = [IO.Path]::GetFullPath($ExpectedParent).TrimEnd('\') + '\'
  if (-not $resolvedDirectory.StartsWith($resolvedParent, [StringComparison]::OrdinalIgnoreCase) -or
      -not ([IO.Path]::GetFileName($resolvedDirectory)).StartsWith('scan-memory-input-', [StringComparison]::Ordinal)) {
    throw "Refusing to remove an unsafe benchmark directory."
  }
  if (Test-Path -LiteralPath $resolvedDirectory) {
    Remove-Item -LiteralPath $resolvedDirectory -Recurse -Force
  }
}

function Close-BenchmarkWorkDirectory {
  param(
    [Parameter(Mandatory = $true)][string]$Directory,
    [Parameter(Mandatory = $true)][string]$ExpectedParent
  )

  $resolvedDirectory = [IO.Path]::GetFullPath($Directory)
  $resolvedParent = [IO.Path]::GetFullPath($ExpectedParent).TrimEnd('\') + '\'
  if (-not $resolvedDirectory.StartsWith($resolvedParent, [StringComparison]::OrdinalIgnoreCase) -or
      -not ([IO.Path]::GetFileName($resolvedDirectory)).StartsWith('scan-memory-work-', [StringComparison]::Ordinal)) {
    throw 'Refusing to remove an unsafe benchmark work directory.'
  }
  if (Test-Path -LiteralPath $resolvedDirectory) {
    Remove-Item -LiteralPath $resolvedDirectory -Recurse -Force
  }
}

function Invoke-ProbeRun {
  param(
    [Parameter(Mandatory = $true)][string]$ProbeExecutable,
    [Parameter(Mandatory = $true)][string]$AppDirectory,
    [Parameter(Mandatory = $true)][string]$InputDirectory,
    [Parameter(Mandatory = $true)][string]$WorkDirectory,
    [Parameter(Mandatory = $true)][string]$SqlRoot,
    [Parameter(Mandatory = $true)][ValidateSet('runtime', 'warm')][string]$Phase,
    [Parameter(Mandatory = $true)][int]$Workers,
    [Parameter(Mandatory = $true)][int]$BatchSize
  )

  $resultFile = Join-Path $WorkDirectory 'result.json'
  $sample = Invoke-SampledProcess `
    -Executable $ProbeExecutable `
    -Arguments @(
      '--benchmark-scan-memory',
      '--root', $InputDirectory,
      '--workers', $Workers.ToString([Globalization.CultureInfo]::InvariantCulture),
      '--batch-size', $BatchSize.ToString([Globalization.CultureInfo]::InvariantCulture),
      '--work', $WorkDirectory,
      '--sql-root', $SqlRoot,
      '--result', $resultFile
    ) `
    -WorkingDirectory $AppDirectory
  if ($sample.ExitCode -ne 0) {
    throw "Memory probe failed with exit code $($sample.ExitCode). $($sample.Stderr.Trim())"
  }
  if (-not (Test-Path -LiteralPath $resultFile -PathType Leaf)) {
    throw 'The memory probe did not produce a JSON result file.'
  }
  $probe = Get-Content -LiteralPath $resultFile -Raw | ConvertFrom-Json
  $phaseScope = switch ($Phase) {
    'runtime' { 'actual_runtime_persistence' }
    'warm' { 'actual_runtime_warm' }
  }
  return [ordered]@{
    phase = $Phase
    phase_scope = $phaseScope
    parser_version = $probe.parser_version
    workers = $Workers
    sample_interval_ms = 100
    elapsed_ms = $probe.elapsed_ms
    process_elapsed_ms = $sample.ElapsedMilliseconds
    peak_private_bytes = $sample.PeakPrivateBytes
    files = $probe.files
    total_bytes = $probe.total_bytes
    files_parsed = $probe.files_parsed
    files_skipped = $probe.files_skipped
    files_failed = $probe.files_failed
    persistence_flush_count = $probe.persistence_flush_count
    rows_available = $probe.rows_available
    cancelled = $probe.cancelled
    persistence_batch_size = $probe.batch_size
    persistence_batch_source_bytes = $probe.batch_source_bytes
    cache_repair_precompleted = $probe.cache_repair_precompleted
    exit_code = $sample.ExitCode
  }
}

function Invoke-CorpusBenchmark {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][IO.FileInfo[]]$Files,
    [Parameter(Mandatory = $true)][object[]]$RunDefinitions,
    [Parameter(Mandatory = $true)][string]$ProbeExecutable,
    [Parameter(Mandatory = $true)][string]$AppDirectory,
    [Parameter(Mandatory = $true)][string]$ScratchDirectory,
    [Parameter(Mandatory = $true)][int]$BatchSize
  )

  $manifestBefore = Get-MetadataManifestHash -Files $Files
  $totalBytesBefore = [int64](($Files | Measure-Object -Property Length -Sum).Sum)
  $inputDirectory = Initialize-HardLinkCorpus -Files $Files -ParentDirectory $ScratchDirectory
  try {
    $runs = foreach ($definition in $RunDefinitions) {
      $workDirectory = Join-Path $ScratchDirectory ('scan-memory-work-' + [guid]::NewGuid().ToString('N'))
      New-Item -ItemType Directory -Path $workDirectory | Out-Null
      try {
        if ($definition.Phase -eq 'warm') {
          Invoke-ProbeRun `
            -ProbeExecutable $ProbeExecutable `
            -AppDirectory $AppDirectory `
            -InputDirectory $inputDirectory `
            -WorkDirectory $workDirectory `
            -SqlRoot (Join-Path ([IO.Path]::GetFullPath((Join-Path $AppDirectory '..'))) 'sql') `
            -Phase 'runtime' `
            -Workers $definition.Workers `
            -BatchSize $BatchSize | Out-Null
        }
        Invoke-ProbeRun `
          -ProbeExecutable $ProbeExecutable `
          -AppDirectory $AppDirectory `
          -InputDirectory $inputDirectory `
          -WorkDirectory $workDirectory `
          -SqlRoot (Join-Path ([IO.Path]::GetFullPath((Join-Path $AppDirectory '..'))) 'sql') `
          -Phase $definition.Phase `
          -Workers $definition.Workers `
          -BatchSize $BatchSize
      }
      finally {
        Close-BenchmarkWorkDirectory -Directory $workDirectory -ExpectedParent $ScratchDirectory
      }
    }
    $manifestAfter = Get-MetadataManifestHash -Files $Files
    if ($manifestAfter -ne $manifestBefore) {
      throw 'The benchmark corpus changed while the matrix was running.'
    }
    return [ordered]@{
      name = $Name
      manifest_sha256 = $manifestBefore
      manifest_stable = $true
      files = $Files.Count
      total_bytes = $totalBytesBefore
      runs = @($runs)
    }
  }
  finally {
    Close-HardLinkCorpus -Directory $inputDirectory -ExpectedParent $ScratchDirectory
  }
}

if ($Mode -eq 'InternalSelfTestChild') {
  $buffer = New-Object byte[] ($ChildAllocationMb * 1024 * 1024)
  for ($index = 0; $index -lt $buffer.Length; $index += 4096) {
    $buffer[$index] = 1
  }
  Start-Sleep -Milliseconds 350
  exit $ChildExitCode
}

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$resultsDirectory = Join-Path $repoRoot '.agents\benchmark-results'
New-Item -ItemType Directory -Path $resultsDirectory -Force | Out-Null

if ($Mode -eq 'SelfTest') {
  $hostExecutable = (Get-Process -Id $PID).Path
  $baseline = Invoke-SampledProcess `
    -Executable $hostExecutable `
    -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-Mode', 'InternalSelfTestChild', '-ChildExitCode', '0', '-ChildAllocationMb', '0') `
    -WorkingDirectory $repoRoot
  $allocated = Invoke-SampledProcess `
    -Executable $hostExecutable `
    -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-Mode', 'InternalSelfTestChild', '-ChildExitCode', '0', '-ChildAllocationMb', '32') `
    -WorkingDirectory $repoRoot
  $failure = Invoke-SampledProcess `
    -Executable $hostExecutable `
    -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-Mode', 'InternalSelfTestChild', '-ChildExitCode', '7') `
    -WorkingDirectory $repoRoot
  $allocationDelta = $allocated.PeakPrivateBytes - $baseline.PeakPrivateBytes
  if ($baseline.ExitCode -ne 0 -or $allocated.ExitCode -ne 0 -or $allocationDelta -lt 24MB -or $failure.ExitCode -ne 7) {
    throw (
      'Memory sampler self-test failed. baseline_exit={0}, allocated_exit={1}, delta={2}, failed_exit={3}.' -f
      $baseline.ExitCode,
      $allocated.ExitCode,
      $allocationDelta,
      $failure.ExitCode
    )
  }
  [ordered]@{
    mode = 'SelfTest'
    sample_interval_ms = 100
    baseline_exit_code = $baseline.ExitCode
    baseline_peak_private_bytes = $baseline.PeakPrivateBytes
    allocated_exit_code = $allocated.ExitCode
    allocated_peak_private_bytes = $allocated.PeakPrivateBytes
    allocation_delta_bytes = $allocationDelta
    failed_exit_code = $failure.ExitCode
    result = 'pass'
  } | ConvertTo-Json
  exit 0
}

$corpusPath = if ([IO.Path]::IsPathRooted($CorpusDirectory)) {
  [IO.Path]::GetFullPath($CorpusDirectory)
} else {
  [IO.Path]::GetFullPath((Join-Path $repoRoot $CorpusDirectory))
}
if (-not (Test-Path -LiteralPath $corpusPath -PathType Container)) {
  throw 'The private benchmark corpus directory does not exist.'
}
$allFiles = @(
  Get-ChildItem -LiteralPath $corpusPath -Recurse -File -Filter '*.jsonl' |
    Sort-Object `
      @{ Expression = 'Length'; Descending = $true },
      @{ Expression = 'FullName'; Descending = $false }
)
if ($allFiles.Count -eq 0) {
  throw 'The private benchmark corpus contains no JSONL files.'
}
$workers = @($WorkerCounts -split ',' | ForEach-Object {
    $value = 0
    if (-not [int]::TryParse($_.Trim(), [ref]$value) -or $value -le 0) {
      throw 'WorkerCounts must contain positive comma-separated integers.'
    }
    $value
  } | Select-Object -Unique)
$appDirectory = Join-Path $repoRoot 'app'
$probeExecutable = if ([string]::IsNullOrWhiteSpace($ProbeExecutablePath)) {
  $flutterExecutable = (Get-Command flutter -ErrorAction Stop).Source
  Push-Location $appDirectory
  try {
    & $flutterExecutable build windows --release
    if ($LASTEXITCODE -ne 0) {
      throw 'Failed to build the benchmark executable.'
    }
  }
  finally {
    Pop-Location
  }
  Join-Path $appDirectory 'build\windows\x64\runner\Release\codex_sessions_viewer.exe'
} elseif ([IO.Path]::IsPathRooted($ProbeExecutablePath)) {
  [IO.Path]::GetFullPath($ProbeExecutablePath)
} else {
  [IO.Path]::GetFullPath((Join-Path $repoRoot $ProbeExecutablePath))
}
if (-not (Test-Path -LiteralPath $probeExecutable -PathType Leaf)) {
  throw 'The benchmark executable does not exist.'
}
$probeArchitecture = Get-PeArchitecture -Executable $probeExecutable
if ($probeArchitecture -ne 'x64') {
  throw "The benchmark executable must be x64; detected $probeArchitecture."
}
$corpora = @()

if ($Mode -eq 'LargestAndTopEight') {
  $corpora += Invoke-CorpusBenchmark `
    -Name 'largest' `
    -Files @($allFiles[0]) `
    -RunDefinitions @([pscustomobject]@{ Phase = 'runtime'; Workers = 1 }) `
    -ProbeExecutable $probeExecutable `
    -AppDirectory $appDirectory `
    -ScratchDirectory $resultsDirectory `
    -BatchSize $PersistenceBatchSize
  $matrix = @(foreach ($worker in $workers) {
      $repetitions = if ($worker -eq 4 -or $worker -eq 8) {
        $MatrixRepetitions
      } else {
        1
      }
      for ($repetition = 1; $repetition -le $repetitions; $repetition++) {
        [pscustomobject]@{ Phase = 'runtime'; Workers = $worker }
      }
    })
  $corpora += Invoke-CorpusBenchmark `
    -Name 'top_eight' `
    -Files @($allFiles | Select-Object -First 8) `
    -RunDefinitions @($matrix) `
    -ProbeExecutable $probeExecutable `
    -AppDirectory $appDirectory `
    -ScratchDirectory $resultsDirectory `
    -BatchSize $PersistenceBatchSize
  $corpora += Invoke-CorpusBenchmark `
    -Name 'persistence_batch' `
    -Files @(Expand-FilesToCount -Files $allFiles -Count ($PersistenceBatchSize + 1)) `
    -RunDefinitions @([pscustomobject]@{ Phase = 'runtime'; Workers = 8 }) `
    -ProbeExecutable $probeExecutable `
    -AppDirectory $appDirectory `
    -ScratchDirectory $resultsDirectory `
    -BatchSize $PersistenceBatchSize
}
elseif ($Mode -eq 'FullCorpus') {
  $corpora += Invoke-CorpusBenchmark `
    -Name 'full_corpus' `
    -Files $allFiles `
    -RunDefinitions @(
      [pscustomobject]@{ Phase = 'runtime'; Workers = 4 }
      [pscustomobject]@{ Phase = 'runtime'; Workers = 8 }
    ) `
    -ProbeExecutable $probeExecutable `
    -AppDirectory $appDirectory `
    -ScratchDirectory $resultsDirectory `
    -BatchSize $PersistenceBatchSize
}
else {
  $corpora += Invoke-CorpusBenchmark `
    -Name 'warm_corpus' `
    -Files $allFiles `
    -RunDefinitions @([pscustomobject]@{ Phase = 'warm'; Workers = 8 }) `
    -ProbeExecutable $probeExecutable `
    -AppDirectory $appDirectory `
    -ScratchDirectory $resultsDirectory `
    -BatchSize $PersistenceBatchSize
}

$report = [ordered]@{
  schema_version = 1
  mode = $Mode
  generated_at_utc = [DateTime]::UtcNow.ToString('o')
  process_architecture = $probeArchitecture
  probe_executable = [IO.Path]::GetFileName($probeExecutable)
  probe_executable_sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $probeExecutable).Hash.ToLowerInvariant()
  sampler = 'PrivateMemorySize64'
  sample_interval_ms = 100
  parser_version = $corpora[0].runs[0].parser_version
  corpora = @($corpora)
}
$resolvedOutput = if ([string]::IsNullOrWhiteSpace($OutputFile)) {
  Join-Path $resultsDirectory ('scan-memory-' + $Mode.ToLowerInvariant() + '.json')
} elseif ([IO.Path]::IsPathRooted($OutputFile)) {
  [IO.Path]::GetFullPath($OutputFile)
} else {
  [IO.Path]::GetFullPath((Join-Path $repoRoot $OutputFile))
}
$outputParent = Split-Path -Parent $resolvedOutput
New-Item -ItemType Directory -Path $outputParent -Force | Out-Null
$json = $report | ConvertTo-Json -Depth 8
[IO.File]::WriteAllText($resolvedOutput, $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
$json
