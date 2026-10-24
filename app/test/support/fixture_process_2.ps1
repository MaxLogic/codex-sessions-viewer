$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$deadline = [DateTime]::UtcNow.AddSeconds(5)
foreach ($processId in $env:CSV_TEST_FIXTURE_PIDS.Split(',')) {
  $ownedProcess = Get-Process -Id ([int]$processId) -ErrorAction SilentlyContinue
  if ($null -eq $ownedProcess) { continue }
  try {
    $remainingMs = [Math]::Max(0, [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds)
    if (-not $ownedProcess.WaitForExit($remainingMs)) {
      throw "Fixture leaked process $processId; dispose its client before teardown."
    }
  } finally { $ownedProcess.Dispose() }
}
exit 0
