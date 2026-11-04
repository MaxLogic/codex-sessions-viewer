<##
.SYNOPSIS
Run change-scoped tests in the release scripts' isolated test environment.
##>
[CmdletBinding()]
param(
    [string] $Base = 'HEAD',
    [string[]] $ChangedPath = @(),
    [switch] $DryRun,
    [switch] $AllowWide,
    [string] $OutputRoot
)
$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$selectorArguments = @((Join-Path $PSScriptRoot 'fast_tests.py'), '--base', $Base)
foreach ($changed in $ChangedPath) { $selectorArguments += @('--path', $changed) }
$selectionJson = & python @selectorArguments
if ($LASTEXITCODE -ne 0) { throw "Selector failed (exit $LASTEXITCODE)" }
$selection = ($selectionJson -join "`n") | ConvertFrom-Json
$selectionJson | Write-Output
if ($DryRun) { return }
if ($selection.widened -and -not $AllowWide) {
    throw 'Selection widened. Run the full release gate at slice closure, or pass -AllowWide to run all tests now. See docs/testing.md.'
}
if (-not $OutputRoot) { throw 'Supply -OutputRoot for retained selection, logs and per-target timings.' }
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
if (Test-Path -LiteralPath $OutputRoot) { throw 'OutputRoot must be a new run directory.' }
New-Item -ItemType Directory -Path $OutputRoot | Out-Null
$selectionJson | Set-Content -LiteralPath (Join-Path $OutputRoot 'selection.json') -Encoding utf8
$records = [Collections.Generic.List[object]]::new()
$total = [Diagnostics.Stopwatch]::StartNew()
. (Join-Path $PSScriptRoot 'test_support/TestEnvironment.ps1')
$context = New-TestEnvironment -Parent (Join-Path $OutputRoot 'sandboxes')

function Invoke-FastStep {
    param([string] $Name, [string] $Executable, [string[]] $Arguments, [string] $Directory, [switch] $Isolated)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $log = Join-Path $OutputRoot ($Name + '.log')
    $code = -1
    try {
        if ($Isolated) {
            Invoke-TestProcess -Context $context -FilePath $Executable -ArgumentList $Arguments -WorkingDirectory $Directory *> $log
        } else {
            Push-Location -LiteralPath $Directory
            try { & $Executable @Arguments *> $log } finally { Pop-Location }
        }
        $code = $LASTEXITCODE
    } finally {
        $timer.Stop()
        $records.Add([pscustomobject]@{ name=$Name; executable=$Executable; arguments=$Arguments; directory=$Directory; exit_code=$code; duration_seconds=$timer.Elapsed.TotalSeconds; log=$log })
        $records | ConvertTo-Json -Depth 6 -AsArray | Set-Content -LiteralPath (Join-Path $OutputRoot 'timings.json') -Encoding utf8
        Write-Output ("{0}: exit {1}, {2:N2}s; {3}" -f $Name, $code, $timer.Elapsed.TotalSeconds, $log)
    }
    if ($code -ne 0) { throw "$Name failed (exit $code); see $log" }
}

try {
    $cargo = (Get-Command cargo -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $collectorRoot = Join-Path $repo 'collector'
    foreach ($target in $selection.rust) {
        $arguments = if ($target -eq 'all') { @('test','--locked','--no-fail-fast') } elseif ($target -eq 'lib') { @('test','--locked','--lib') } else { @('test','--locked','--test',$target) }
        Invoke-FastStep -Name "rust-$target" -Executable $cargo -Arguments $arguments -Directory $collectorRoot -Isolated
    }
    if (@($selection.flutter).Count -gt 0) {
        # Same tool-cache/build environment as build_windows.ps1. Tests alone
        # enter the fail-closed profile, preserving the checkout's default target.
        Invoke-FastStep -Name 'native-debug-build' -Executable $cargo -Arguments @('build','--locked','--bins') -Directory $collectorRoot
        $flutter = (Get-Command flutter -ErrorAction SilentlyContinue | Select-Object -First 1).Source
        if (-not $flutter) { $flutter = 'C:\tools\flutter\bin\flutter.bat' }
        $context.Variables['PATH'] = (Split-Path -Parent $flutter) + [IO.Path]::PathSeparator + $context.Variables['PATH']
        $context.Variables['CODEX_SESSIONS_COLLECTOR_EXE'] = Join-Path $collectorRoot 'target/debug/codex-sessions-collector.exe'
        $context.Variables['CODEX_SESSIONS_HUB_EXE'] = Join-Path $collectorRoot 'target/debug/codex-sessions-hub.exe'
        Invoke-FastStep -Name 'flutter-pub-get' -Executable $flutter -Arguments @('pub','get') -Directory (Join-Path $repo 'app')
        $batch = @($selection.flutter | Where-Object { -not $selection.flutter_filters.PSObject.Properties[$_] -and $_ -notin @('test','integration_test') -and -not $_.StartsWith('integration_test/') })
        if ($batch.Count -gt 0) {
            Invoke-FastStep -Name 'flutter-selected' -Executable $flutter -Arguments (@('test','--machine') + $batch) -Directory (Join-Path $repo 'app') -Isolated
            # The machine reporter identifies each suite/test even when files
            # run concurrently. Retain measured per-file spans, not a guessed
            # division of the batch wall time. Spans overlap and do not sum.
            $suites = @{}
            $tests = @{}
            foreach ($line in Get-Content -LiteralPath (Join-Path $OutputRoot 'flutter-selected.log')) {
                try { $testEvent = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
                if ($testEvent.type -eq 'suite') {
                    $suites[[string]$testEvent.suite.id] = [pscustomobject]@{ file=$testEvent.suite.path; first_ms=$null; last_ms=$null; passed=0; failed=0; skipped=0 }
                } elseif ($testEvent.type -eq 'testStart') {
                    $tests[[string]$testEvent.test.id] = [string]$testEvent.test.suiteID
                    $suite = $suites[[string]$testEvent.test.suiteID]
                    if ($suite -and $null -eq $suite.first_ms) { $suite.first_ms = $testEvent.time }
                } elseif ($testEvent.type -eq 'testDone') {
                    $suite = $suites[$tests[[string]$testEvent.testID]]
                    if ($suite) {
                        $suite.last_ms = $testEvent.time
                        if (-not $testEvent.hidden) {
                            if ($testEvent.skipped) { $suite.skipped++ } elseif ($testEvent.result -eq 'success') { $suite.passed++ } else { $suite.failed++ }
                        }
                    }
                }
            }
            $targetTimings = @($suites.Values | ForEach-Object {
                [pscustomobject]@{ file=$_.file; duration_seconds=($_.last_ms - $_.first_ms)/1000.0; measurement='concurrent suite span including load'; passed=$_.passed; failed=$_.failed; skipped=$_.skipped }
            } | Sort-Object file)
            $targetTimings | ConvertTo-Json -AsArray | Set-Content -LiteralPath (Join-Path $OutputRoot 'flutter-target-timings.json') -Encoding utf8
            if ($targetTimings.Count -ne $batch.Count -or ($targetTimings | Measure-Object passed -Sum).Sum -le 0) { throw 'Flutter batch produced incomplete or empty suite evidence.' }
        }
        foreach ($file in @($selection.flutter | Where-Object { $_ -notin $batch })) {
            $name = 'flutter-' + ($file -replace '[/\\.]','_')
            $arguments = @('test',$file)
            $filter = $selection.flutter_filters.PSObject.Properties[$file]
            if ($filter) { $arguments += @('--plain-name', [string]$filter.Value) }
            Invoke-FastStep -Name $name -Executable $flutter -Arguments $arguments -Directory (Join-Path $repo 'app') -Isolated
        }
    }
} finally {
    $total.Stop()
    [pscustomobject]@{ duration_seconds=$total.Elapsed.TotalSeconds; sandbox=$context.Root; cleanup='Retained for inspection; remove this owned sandbox after reviewing logs.' } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $OutputRoot 'run.json') -Encoding utf8
}
