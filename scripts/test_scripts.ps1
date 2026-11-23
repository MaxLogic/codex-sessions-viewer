#Requires -Version 7.0
[CmdletBinding()]
param([string] $CollectorPath)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$repo = Split-Path -Parent $PSScriptRoot
$collectorRoot = Join-Path $repo 'collector'
$failures = [Collections.Generic.List[string]]::new()

function Invoke-ScriptCheck {
    param([string] $Name, [scriptblock] $Check)
    Write-Output "==> $Name"
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $report = @{ Code = 1; Counts = 'no results' }
    try {
        & $Check $report
    } catch {
        $report.Code = 1
        Write-Output $_.Exception.Message
    }
    $timer.Stop()
    if ($report.Code -ne 0) { $failures.Add($Name) }
    Write-Output ("{0}: exit {1}; {2}; {3:N2}s" -f $Name, $report.Code, $report.Counts, $timer.Elapsed.TotalSeconds)
}

if (-not $CollectorPath) {
    $CollectorPath = Join-Path $collectorRoot 'target/debug/codex-sessions-collector.exe'
    if (-not (Test-Path -LiteralPath $CollectorPath -PathType Leaf)) {
        Invoke-ScriptCheck 'Build debug collector for script tests' {
            param($Report)
            Push-Location -LiteralPath $collectorRoot
            try {
                & cargo build --locked --bin codex-sessions-collector
                $Report.Code = $LASTEXITCODE
                $Report.Counts = if ($Report.Code -eq 0) { '1 build succeeded' } else { '1 build failed' }
            } finally { Pop-Location }
        }
    }
}

Invoke-ScriptCheck 'Pester under scripts/' {
    param($Report)
    Import-Module Pester -MinimumVersion 5.0 -ErrorAction Stop
    $savedCollector = $env:CODEX_SESSIONS_COLLECTOR_EXE
    try {
        $env:CODEX_SESSIONS_COLLECTOR_EXE = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($CollectorPath)
        $config = New-PesterConfiguration
        $config.Run.Path = $PSScriptRoot
        $config.Run.PassThru = $true
        $config.Output.Verbosity = 'Normal'
        $result = Invoke-Pester -Configuration $config
        $Report.Counts = "$($result.TotalCount) tests, $($result.PassedCount) passed, $($result.FailedCount) failed, $($result.SkippedCount) skipped, $($result.NotRunCount) not run"
        $Report.Code = if ($result.Result -eq 'Passed' -and $result.TotalCount -gt 0) { 0 } else { 1 }
    } finally {
        $env:CODEX_SESSIONS_COLLECTOR_EXE = $savedCollector
    }
}

foreach ($suite in @('test_fast_tests.py', 'test_selection_invariant.py')) {
    Invoke-ScriptCheck $suite {
        param($Report)
        $output = & python -B (Join-Path $PSScriptRoot $suite) 2>&1
        $Report.Code = $LASTEXITCODE
        $output | ForEach-Object { [string] $_ }
        if (($output -join "`n") -match '(?m)^Ran (\d+) tests? in ') {
            $Report.Counts = "$($Matches[1]) tests"
        } elseif ($Report.Code -eq 0) {
            $Report.Code = 1
            Write-Output 'Python suite produced no test-count summary.'
        }
    }
}

Invoke-ScriptCheck 'PSScriptAnalyzer under scripts/' {
    param($Report)
    $diagnostics = @(Invoke-ScriptAnalyzer -Path $PSScriptRoot -Recurse -ErrorAction Stop)
    $diagnostics | Format-Table -AutoSize | Out-String | Write-Output
    $Report.Counts = "$($diagnostics.Count) diagnostics"
    $Report.Code = [int]($diagnostics.Count -gt 0)
}

if ($failures.Count -gt 0) {
    Write-Output ('Failed script checks: ' + ($failures -join ', '))
    exit 1
}
Write-Output 'All script checks passed.'
exit 0
