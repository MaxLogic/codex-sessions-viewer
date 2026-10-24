$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$root = $env:CSV_TEST_FIXTURE_ROOT.Replace('/', '\').ToLowerInvariant() + '\'
@(Get-CimInstance Win32_Process |
  Where-Object { $_.CommandLine -and $_.CommandLine.Replace('/', '\').ToLowerInvariant().Contains($root) } |
  ForEach-Object { @{pid = [int]$_.ProcessId; resident = ($_.CommandLine -match '\sserve(?:-replacement)?\s')} }) |
  ConvertTo-Json -Compress
