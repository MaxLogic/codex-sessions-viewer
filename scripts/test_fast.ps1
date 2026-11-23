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
. (Join-Path $PSScriptRoot 'test_support/TestEnvironment.ps1')
$OutputRoot = [IO.Path]::GetFullPath((Get-TestPathComparisonForm $OutputRoot))
New-TestRunDirectory $OutputRoot
$selectionJson | Set-Content -LiteralPath (Join-Path $OutputRoot 'selection.json') -Encoding utf8
$records = [Collections.Generic.List[object]]::new()
$total = [Diagnostics.Stopwatch]::StartNew()
. (Join-Path $PSScriptRoot 'test_support/FastTestLaunch.ps1')
$sandboxParent = Join-Path $OutputRoot 'sandboxes'
$context = New-TestEnvironment -RunRoot $sandboxParent
$scriptCheckSandboxParent = $null
$completed = $false

function Read-FastFlutterEvidence {
    param([string] $Log, [int] $ExpectedCount)

    # The machine reporter identifies each suite/test even when files
    # run concurrently. Retain measured per-file spans, not a guessed
    # division of the batch wall time. Spans overlap and do not sum.
    $suites = @{}
    $tests = @{}
    foreach ($line in Get-Content -LiteralPath $Log) {
        try { $testEvent = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        if ($testEvent.type -eq 'suite') {
            $suites[[string]$testEvent.suite.id] = [pscustomobject]@{ file=$testEvent.suite.path; first_ms=$null; last_ms=$null; passed=0; failed=0; skipped=0 }
        } elseif ($testEvent.type -eq 'testStart') {
            $tests[[string]$testEvent.test.id] = [string]$testEvent.test.suiteID
            $suite = $suites[[string]$testEvent.test.suiteID]
            if ($suite -and $null -eq $suite.first_ms) { $suite.first_ms = $testEvent.time }
        } elseif ($testEvent.type -eq 'testDone') {
            $suiteId = $tests[[string]$testEvent.testID]
            $suite = if ($null -ne $suiteId) { $suites[$suiteId] }
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
    if ($targetTimings.Count -ne $ExpectedCount -or ($targetTimings | Measure-Object passed -Sum).Sum -le 0) { throw 'Flutter batch produced incomplete or empty suite evidence.' }
}

function Invoke-FastStep {
    param(
        [string] $Name, [string] $Executable, [string[]] $Arguments, [string] $Directory,
        [switch] $Isolated, [string] $Needs, [int] $ExpectedFlutterSuites,
        [hashtable] $NamedArguments = @{}
    )
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $log = $null
    $code = $null
    $reason = $null
    $status = 'not_run'
    if ($Needs) {
        $reason = "needs $Needs"
    } else {
        $log = Join-Path $OutputRoot ($Name + '.log')
        $PSNativeCommandUseErrorActionPreference = $false
        $status = 'failed'
        try {
            if ($Isolated) {
                Invoke-TestProcess -Context $context -FilePath $Executable -ArgumentList $Arguments -WorkingDirectory $Directory *> $log
            } else {
                Push-Location -LiteralPath $Directory
                try { & $Executable @Arguments @NamedArguments *> $log } finally { Pop-Location }
            }
            $code = $LASTEXITCODE
            if ($code -eq 0) {
                if ($ExpectedFlutterSuites) { Read-FastFlutterEvidence -Log $log -ExpectedCount $ExpectedFlutterSuites }
                $status = 'passed'
            }
        } catch {
            $reason = $_.Exception.Message
            try { Add-Content -LiteralPath $log -Value $reason } catch { $log = $null }
        }
    }
    $timer.Stop()
    $records.Add([pscustomobject]@{
        name=$Name; executable=$Executable; arguments=$Arguments; directory=$Directory
        named_arguments=$NamedArguments
        exit_code=$code; duration_seconds=$timer.Elapsed.TotalSeconds; log=$log
        status=$status; reason=$reason
    })
    $records | ConvertTo-Json -Depth 6 -AsArray | Set-Content -LiteralPath (Join-Path $OutputRoot 'timings.json') -Encoding utf8
    if (-not $Needs) {
        $exitText = if ($null -ne $code) { "exit $code" } else { 'no native exit' }
        $logText = if ($log) { $log } else { 'log unavailable' }
        Write-Output ("{0}: {1}, {2:N2}s; {3}" -f $Name, $exitText, $timer.Elapsed.TotalSeconds, $logText)
    }
}

try {
    $cargoCommand = Get-Command cargo -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $cargo = if ($cargoCommand) { $cargoCommand.Source } else { 'cargo' }
    $collectorRoot = Join-Path $repo 'collector'
    foreach ($target in $selection.rust) {
        $arguments = if ($target -eq 'all') { @('test','--locked','--no-fail-fast') } elseif ($target -eq 'lib') { @('test','--locked','--lib') } else { @('test','--locked','--test',$target) }
        Invoke-FastStep -Name "rust-$target" -Executable $cargo -Arguments $arguments -Directory $collectorRoot -Isolated
    }
    if (@($selection.flutter).Count -gt 0) {
        # Keep the checkout's incremental build and tool caches. The test
        # processes alone use the fail-closed profile.
        $appRoot = Join-Path $repo 'app'
        $flutterCommand = Get-Command flutter -ErrorAction SilentlyContinue | Select-Object -First 1
        $flutter = if ($flutterCommand) { $flutterCommand.Source } else { 'C:\\tools\\flutter\\bin\\flutter.bat' }
        $context.Variables['PATH'] = (Split-Path -Parent $flutter) + [IO.Path]::PathSeparator + $context.Variables['PATH']
        $context.Variables['CODEX_SESSIONS_COLLECTOR_EXE'] = Join-Path $collectorRoot 'target/debug/codex-sessions-collector.exe'
        $context.Variables['CODEX_SESSIONS_HUB_EXE'] = Join-Path $collectorRoot 'target/debug/codex-sessions-hub.exe'

        $failedSetups = @()
        Invoke-FastStep -Name 'native-debug-build' -Executable $cargo -Arguments @('build','--locked','--bins') -Directory $collectorRoot
        if ($records[$records.Count - 1].status -eq 'failed') { $failedSetups += 'native-debug-build' }
        Invoke-FastStep -Name 'flutter-pub-get' -Executable $flutter -Arguments @('pub','get') -Directory $appRoot
        if ($records[$records.Count - 1].status -eq 'failed') { $failedSetups += 'flutter-pub-get' }
        $needs = $failedSetups -join ' and '

        $batch = @($selection.flutter | Where-Object { -not $selection.flutter_filters.PSObject.Properties[$_] -and $_ -notin @('test','integration_test') -and -not $_.StartsWith('integration_test/') })
        if ($batch.Count -gt 0) {
            Invoke-FastStep -Name 'flutter-selected' -Executable $flutter -Arguments (@('test','--machine') + $batch) -Directory $appRoot -Isolated -Needs $needs -ExpectedFlutterSuites $batch.Count
        }
        foreach ($file in @($selection.flutter | Where-Object { $_ -notin $batch })) {
            $name = 'flutter-' + ($file -replace '[/\\.]','_')
            $arguments = @(Get-FastFlutterTestArgumentList -Target $file -Filters $selection.flutter_filters)
            Invoke-FastStep -Name $name -Executable $flutter -Arguments $arguments -Directory $appRoot -Isolated -Needs $needs
        }
    }
    if ($selection.script_checks) {
        $scriptCheckSandboxParent = $context.Variables['CXV_TEST_SANDBOX_PARENT']
        $savedSandboxParent = $env:CXV_TEST_SANDBOX_PARENT
        try {
            $env:CXV_TEST_SANDBOX_PARENT = $scriptCheckSandboxParent
            Invoke-FastStep -Name 'script-checks' -Executable (Join-Path $PSScriptRoot 'test_scripts.ps1') -NamedArguments @{ DeferSandboxCleanup = $true } -Directory $repo
        } finally {
            $env:CXV_TEST_SANDBOX_PARENT = $savedSandboxParent
        }
    }
    $completed = $true
} finally {
    $total.Stop()
    $failed = @($records | Where-Object status -eq 'failed')
    $notRun = @($records | Where-Object status -eq 'not_run')
    $passed = $completed -and -not $failed.Count -and -not $notRun.Count
    $receipt = [pscustomobject]@{
        duration_seconds=$total.Elapsed.TotalSeconds; sandbox=$context.Root
        script_check_sandbox_parent=$scriptCheckSandboxParent
        retained_sandboxes=@($context.Root)
        cleanup=if ($passed) { 'Sandbox retained when the result was recorded, before cleanup.' } else { 'Sandbox retained. See test output for details.' }
        steps=@($records.ToArray()); failed=$failed; not_run=$notRun
    }
    $receiptPath = Join-Path $OutputRoot 'run.json'
    try {
        $receipt | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $receiptPath -Encoding utf8
    } catch {
        Write-Warning "Could not write the test result. Retained test sandbox: $($context.Root)"
        throw
    }
    Complete-TestEnvironment -Context $context -Passed:$passed
    if ($passed -and -not [IO.Directory]::Exists($context.Root)) {
        $receipt.retained_sandboxes = @()
        $receipt.cleanup = 'Sandbox removed.'
        # Leave the persisted outcome intact if the cleanup-only update fails.
        $receiptUpdate = Join-Path $OutputRoot 'run.cleanup.json'
        try {
            $receipt | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $receiptUpdate -Encoding utf8
            [IO.File]::Move($receiptUpdate, $receiptPath, $true)
        } catch {
            Write-Warning "Sandbox removed, but could not update the cleanup status in '$receiptPath': $($_.Exception.Message)"
        }
    }
}

if ($failed.Count -or $notRun.Count) {
    Write-Output 'Fast-lane test summary:'
    foreach ($step in $failed) {
        $exitText = if ($null -ne $step.exit_code) { "exit $($step.exit_code)" } else { 'no native exit' }
        $logText = if ($step.log) { $step.log } else { 'log unavailable' }
        $reasonText = if ($step.reason) { " ($($step.reason))" } else { '' }
        Write-Output "$($step.name) $exitText $logText$reasonText"
    }
    foreach ($step in $notRun) { Write-Output "$($step.name) not run: $($step.reason)" }
    exit 1
}
Write-Output "All $($records.Count) selected steps passed."
exit 0
