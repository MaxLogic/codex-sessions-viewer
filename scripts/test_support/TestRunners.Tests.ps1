AfterAll {
    $ownedEnvironment = Get-Variable runnerEnvironment -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    if ($ownedEnvironment) {
        Complete-PesterTestEnvironment $ownedEnvironment (Get-Variable ____Pester -ValueOnly -ErrorAction SilentlyContinue)
    }
}

BeforeAll {
    Set-StrictMode -Version Latest
    $script:sourceScripts = Split-Path -Parent $PSScriptRoot
    $script:originalPath = $env:PATH
    $script:originalSandboxParent = $env:CXV_TEST_SANDBOX_PARENT
    . (Join-Path $PSScriptRoot 'TestEnvironment.ps1')
    $script:runnerEnvironment = New-TestEnvironment
    $script:runnerScratch = $script:runnerEnvironment.Root

    function Initialize-RunnerFixture {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        foreach ($folder in @('scripts/test_support','app/test','collector/target/release','sql','bin')) {
            New-Item -ItemType Directory -Path (Join-Path $root $folder) -Force | Out-Null
        }
        foreach ($file in @('test_fast.ps1','build_windows.ps1','test_support/TestEnvironment.ps1','test_support/FastTestLaunch.ps1')) {
            Copy-Item -LiteralPath (Join-Path $script:sourceScripts $file) -Destination (Join-Path $root "scripts/$file")
        }
        foreach ($file in @('settings.sample.toml','app/test/batch_test.dart','collector/Cargo.toml','collector/target/release/codex-sessions-collector.exe','collector/target/release/codex-sessions-hub.exe','collector/target/release/codex-sessions-scan-launcher.exe')) {
            Set-Content -LiteralPath (Join-Path $root $file) -Value 'fixture'
        }
        # Stub every tool at the external command boundary. The copied runners
        # still execute their real scheduling and isolated launch guards.
        foreach ($tool in @('cargo','flutter','dart')) {
            @"
@echo off
echo invoked $tool %*
if "$tool"=="cargo" if "%1"=="test" echo Rust sandbox parent=%CXV_TEST_SANDBOX_PARENT%
if "$tool"=="flutter" if "%1"=="test" echo Flutter sandbox parent=%CXV_TEST_SANDBOX_PARENT%
if exist "%~dp0fail-%1-%2" exit /b 37
if "$tool"=="cargo" if "%1"=="test" if exist "%~dp0rust-fail" exit /b 101
if "$tool"=="flutter" if "%1"=="pub" if exist "%~dp0pub-fail" exit /b 42
if "$tool"=="flutter" if "%1"=="test" if "%2"=="integration_test" if exist "%~dp0integration-fail" exit /b 23
exit /b 0
"@ | Set-Content -LiteralPath (Join-Path $root "bin/$tool.cmd") -Encoding ascii
        }
        @'
param([string] $CollectorPath, [switch] $DeferSandboxCleanup)
Write-Output "invoked script checks $CollectorPath"
if (-not $CollectorPath) {
    . (Join-Path $PSScriptRoot 'test_support/TestEnvironment.ps1')
    $context = New-TestEnvironment
    Write-Output $context.Root
}
if (Test-Path -LiteralPath (Join-Path $PSScriptRoot '../bin/script-fail')) { exit 19 }
exit 0
'@ | Set-Content -LiteralPath (Join-Path $root 'scripts/test_scripts.ps1')
        $env:PATH = (Join-Path $root 'bin') + [IO.Path]::PathSeparator + $script:originalPath
        return $root
    }

    function Initialize-FixtureSelection {
        param([string] $Root, [string[]] $Flutter, [bool] $ScriptChecks = $false)
        $plan = @{ rust = @('all'); flutter = $Flutter; flutter_filters = @{}; script_checks = $ScriptChecks; widened = $true }
        $plan | ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $Root 'selection.json')
        @'
from pathlib import Path
print(Path(__file__).resolve().parents[1].joinpath("selection.json").read_text(encoding="utf-8"))
'@ | Set-Content -LiteralPath (Join-Path $Root 'scripts/fast_tests.py')
    }

    function Initialize-FixtureFailure {
        param([string] $Root, [string[]] $Markers)
        foreach ($marker in $Markers) {
            New-Item -ItemType File -Path (Join-Path $Root "bin/$marker") | Out-Null
        }
    }
}

Describe 'Fast lane runner in a disposable checkout' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $root = Initialize-RunnerFixture
        $script:runner = Join-Path $root 'scripts/test_fast.ps1'
        $script:outputRoot = Join-Path $script:runnerScratch (Split-Path $root -Leaf)
    }
    AfterEach {
        $env:PATH = $script:originalPath
    }
    It 'keeps running after a native Rust failure and reports the failed exit and log' {
        Initialize-FixtureSelection -Root $root -Flutter @('test') -ScriptChecks $true
        Initialize-FixtureFailure -Root $root -Markers 'rust-fail'
        $output = & $script:runner -AllowWide -OutputRoot $script:outputRoot 3>&1
        $LASTEXITCODE | Should -Not -Be 0
        $steps = Get-Content (Join-Path $script:outputRoot 'timings.json') -Raw | ConvertFrom-Json
        $steps.name | Should -Be @('rust-all','native-debug-build','flutter-pub-get','flutter-test','script-checks')
        foreach ($step in $steps | Select-Object -Skip 1) {
            $step.status | Should -Be 'passed'
            $step.exit_code | Should -Be 0
        }
        $run = Get-Content (Join-Path $script:outputRoot 'run.json') -Raw | ConvertFrom-Json
        $run.sandbox | Should -Be (Join-Path $script:outputRoot 'sandboxes')
        $run.failed[0].exit_code | Should -Be 101
        $run.failed[0].log | Should -Exist
        $run.retained_sandboxes | Should -Be @($run.sandbox)
        $run.sandbox | Should -Exist
        ($output -join "`n") | Should -Match 'rust-all.*101.*rust-all\.log'
        ($output -join "`n") | Should -Match ([regex]::Escape($run.sandbox))
        $childParent = Join-Path $run.sandbox 'children'
        $childParent | Should -Exist
        Get-Content -LiteralPath $run.failed[0].log | Should -Contain "Rust sandbox parent=$childParent"
        Get-Content -LiteralPath ($steps | Where-Object name -eq 'flutter-test').log | Should -Contain "Flutter sandbox parent=$childParent"
    }
    It 'records dependent steps as not run after <Setup>' -ForEach @(
        @{ Setup = 'native-debug-build'; Trigger = 'build---locked' }
        @{ Setup = 'flutter-pub-get'; Trigger = 'pub-get' }
    ) {
        Initialize-FixtureSelection -Root $root -Flutter @('test','integration_test') -ScriptChecks $true
        Initialize-FixtureFailure -Root $root -Markers "fail-$Trigger"
        $output = & $script:runner -AllowWide -OutputRoot $script:outputRoot
        $LASTEXITCODE | Should -Not -Be 0
        $run = Get-Content (Join-Path $script:outputRoot 'run.json') -Raw | ConvertFrom-Json
        $run.failed[0].name | Should -Be $Setup
        $run.failed[0].exit_code | Should -Be 37
        $run.not_run.name | Should -Be @('flutter-test','flutter-integration_test')
        if ($Setup -eq 'native-debug-build') {
            $pubGet = $run.steps | Where-Object name -eq 'flutter-pub-get'
            $pubGet.exit_code | Should -Be 0
            $pubGet.status | Should -Be 'passed'
        }
        foreach ($step in $run.not_run) {
            $step.reason | Should -Be "needs $Setup"
            ($output -join "`n") | Should -Match "$($step.name).*not run.*$Setup"
        }
        (Get-Content (Join-Path $script:outputRoot 'script-checks.log') -Raw) | Should -Match 'invoked script checks'
    }
    It 'reports both independent setup failures along with the Rust failure' {
        Initialize-FixtureSelection -Root $root -Flutter @('test','integration_test')
        Initialize-FixtureFailure -Root $root -Markers @('rust-fail','fail-build---locked','pub-fail')
        $output = (& $script:runner -AllowWide -OutputRoot $script:outputRoot) -join "`n"
        $LASTEXITCODE | Should -Be 1
        $run = Get-Content (Join-Path $script:outputRoot 'run.json') -Raw | ConvertFrom-Json
        $run.failed.name | Should -Be @('rust-all','native-debug-build','flutter-pub-get')
        $run.failed.exit_code | Should -Be @(101,37,42)
        $run.not_run.name | Should -Be @('flutter-test','flutter-integration_test')
        foreach ($step in $run.not_run) {
            $step.reason | Should -Be 'needs native-debug-build and flutter-pub-get'
        }
        $output | Should -Match 'rust-all exit 101'
        $output | Should -Match 'native-debug-build exit 37'
        $output | Should -Match 'flutter-pub-get exit 42'
    }
    It 'records an unavailable step log and runs later steps' {
        Initialize-FixtureSelection -Root $root -Flutter @('test','integration_test') -ScriptChecks $true
        $cargo = Join-Path $root 'bin/cargo.cmd'
        $logPath = Join-Path $script:outputRoot 'flutter-test.log'
        $blockLog = 'if "%1"=="test" mkdir "' + $logPath + '"'
        $stub = (Get-Content -LiteralPath $cargo -Raw).Replace('exit /b 0', "$blockLog`r`nexit /b 0")
        Set-Content -LiteralPath $cargo -Value $stub -Encoding ascii

        $output = (& $script:runner -AllowWide -OutputRoot $script:outputRoot) -join "`n"
        $LASTEXITCODE | Should -Be 1
        $run = Get-Content (Join-Path $script:outputRoot 'run.json') -Raw | ConvertFrom-Json
        $run.failed.name | Should -Be 'flutter-test'
        $run.failed[0].exit_code | Should -BeNullOrEmpty
        $run.failed[0].log | Should -BeNullOrEmpty
        $run.failed[0].reason | Should -Match 'flutter-test\.log'
        $output | Should -Match 'flutter-test no native exit.*log unavailable'
        foreach ($name in @('flutter-integration_test','script-checks')) {
            ($run.steps | Where-Object name -eq $name).status | Should -Be 'passed'
        }
    }
    It 'removes passing script-check profiles allocated under the run sandbox' {
        Initialize-FixtureSelection -Root $root -Flutter @() -ScriptChecks $true
        $env:CXV_TEST_SANDBOX_PARENT = $script:runnerScratch
        try {
            & $script:runner -AllowWide -OutputRoot $script:outputRoot
            $LASTEXITCODE | Should -Be 0
            $env:CXV_TEST_SANDBOX_PARENT | Should -Be $script:runnerScratch
        } finally {
            $env:CXV_TEST_SANDBOX_PARENT = $script:originalSandboxParent
        }

        $run = Get-Content (Join-Path $script:outputRoot 'run.json') -Raw | ConvertFrom-Json
        $expectedParent = Join-Path $run.sandbox 'children'
        $run.script_check_sandbox_parent | Should -Be $expectedParent
        $profilePath = (Get-Content (Join-Path $script:outputRoot 'script-checks.log'))[-1]
        (Split-Path $profilePath -Parent) | Should -Be $expectedParent
        $profilePath | Should -Not -Exist
        $run.retained_sandboxes | Should -BeNullOrEmpty
    }
    It 'records missing Flutter batch evidence as failed and still runs integration' {
        Initialize-FixtureSelection -Root $root -Flutter @('test/batch_test.dart','integration_test')
        & $script:runner -AllowWide -OutputRoot $script:outputRoot
        $LASTEXITCODE | Should -Not -Be 0
        $run = Get-Content (Join-Path $script:outputRoot 'run.json') -Raw | ConvertFrom-Json
        $run.failed[0].name | Should -Be 'flutter-selected'
        $run.failed[0].exit_code | Should -Be 0
        $run.failed[0].reason | Should -Match 'incomplete or empty suite evidence'
        Join-Path $script:outputRoot 'flutter-integration_test.log' | Should -Exist
    }
    It 'exits zero with the expected timing fields when all steps pass' {
        Initialize-FixtureSelection -Root $root -Flutter @('test')
        $output = & $script:runner -AllowWide -OutputRoot $script:outputRoot
        $LASTEXITCODE | Should -Be 0
        ($output -join "`n") | Should -Match 'All .* passed'
        $steps = Get-Content (Join-Path $script:outputRoot 'timings.json') -Raw | ConvertFrom-Json
        $steps[0].PSObject.Properties.Name | Should -Contain 'duration_seconds'
        $steps[0].exit_code | Should -Be 0
        $run = Get-Content (Join-Path $script:outputRoot 'run.json') -Raw | ConvertFrom-Json
        $run.retained_sandboxes | Should -BeNullOrEmpty
        $run.sandbox | Should -Not -Exist
        (Join-Path $script:outputRoot 'sandboxes') | Should -Not -Exist
    }
    It 'retains and names the child evidence when the run receipt cannot be written' {
        Initialize-FixtureSelection -Root $root -Flutter @() -ScriptChecks $true
        $step = Join-Path $root 'scripts/test_scripts.ps1'
        $original = Get-Content -LiteralPath $step -Raw
        $blockReceipt = @'
$out = Split-Path -Parent (Split-Path -Parent $env:CXV_TEST_SANDBOX_PARENT)
New-Item -ItemType Directory -Path (Join-Path $out 'run.json') | Out-Null
Set-Content -LiteralPath (Join-Path $env:CXV_TEST_SANDBOX_PARENT 'evidence.txt') -Value 'preserve this'
'@
        Set-Content -LiteralPath $step -Value ($original.Replace('exit 0', "$blockReceipt`nexit 0"))

        $output = & {
            try { & $script:runner -AllowWide -OutputRoot $script:outputRoot }
            catch { $_ }
        } 3>&1
        $sandbox = Join-Path $script:outputRoot 'sandboxes'
        $errors = @($output | Where-Object { $_ -is [Management.Automation.ErrorRecord] })
        $errors.Count | Should -Be 1
        [string]$errors[0] | Should -Match 'run\.json'
        $warnings = $output | Where-Object { $_ -is [Management.Automation.WarningRecord] }
        ($warnings -join "`n") | Should -Match ([regex]::Escape($sandbox))
        Get-Content -LiteralPath (Join-Path $sandbox 'children/evidence.txt') | Should -BeExactly 'preserve this'
    }
    It 'rejects missing output and unapproved widening before allocating a run' {
        Initialize-FixtureSelection -Root $root -Flutter @('test')
        { & $script:runner -AllowWide } | Should -Throw '*Supply -OutputRoot*'
        { & $script:runner -OutputRoot $script:outputRoot } | Should -Throw '*Selection widened*'
        $script:outputRoot | Should -Not -Exist
    }
}

Describe 'Windows release gate in a disposable checkout' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $root = Initialize-RunnerFixture
        $script:releaseSandboxParent = $script:runnerScratch
        $script:existingReleases = @(Get-ChildItem -LiteralPath $script:releaseSandboxParent -Directory | Select-Object -ExpandProperty FullName)
        $env:CXV_TEST_SANDBOX_PARENT = $script:releaseSandboxParent
        $script:runner = Join-Path $root 'scripts/build_windows.ps1'
        $script:releaseRoot = Join-Path $root 'fake-release'
        $script:buildLog = Join-Path $root 'build.log'
    }
    AfterEach {
        $env:PATH = $script:originalPath
        $env:CXV_TEST_SANDBOX_PARENT = $script:originalSandboxParent
    }
    It 'reports all failing tests before building or copying the release under <TestHost>' -ForEach @(
        @{ TestHost = 'PowerShell 7' }, @{ TestHost = 'Windows PowerShell 5.1' }
    ) {
        Initialize-FixtureFailure -Root $root -Markers @('rust-fail','integration-fail','script-fail')
        if ($TestHost -eq 'Windows PowerShell 5.1') {
            $legacy = Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
            $PSNativeCommandUseErrorActionPreference = $false
            & $legacy -NoProfile -ExecutionPolicy Bypass -File $script:runner -OutputDirectory $script:releaseRoot *> $script:buildLog
            $LASTEXITCODE | Should -Be 1
        } else {
            { & $script:runner -OutputDirectory $script:releaseRoot *> $script:buildLog } | Should -Throw '*test*failed*'
        }
        $text = Get-Content $script:buildLog -Raw
        $text | Should -Match 'invoked cargo build --locked --release --bins'
        $text | Should -Match '(?m)^invoked flutter test\s*$'
        $text | Should -Match 'invoked flutter test integration_test'
        $text | Should -Match 'invoked script checks .*codex-sessions-collector.exe'
        $text | Should -Match 'Test collector.*101'
        $text | Should -Match 'Run Flutter integration tests.*23'
        $text | Should -Match 'Run script checks.*19'
        $retained = @(Get-ChildItem -LiteralPath $script:releaseSandboxParent -Directory | Where-Object FullName -notin $script:existingReleases)
        $retained.Count | Should -Be 1
        $retainedRoot = $retained[0].FullName
        $text | Should -Match 'Retained test sandbox:'
        $text | Should -Match ([regex]::Escape($retainedRoot))
        $childParent = Join-Path $retainedRoot 'children'
        $childParent | Should -Exist
        $text | Should -Match ([regex]::Escape("Rust sandbox parent=$childParent"))
        $text | Should -Match ([regex]::Escape("Flutter sandbox parent=$childParent"))
        $text | Should -Not -Match 'Build Windows release|invoked flutter build windows'
        $script:releaseRoot | Should -Not -Exist
    }
    It 'stops on collector formatting failure before tests or builds' {
        Initialize-FixtureFailure -Root $root -Markers 'fail-fmt---check'
        { & $script:runner -OutputDirectory $script:releaseRoot *> $script:buildLog } | Should -Throw '*Check collector formatting*37*'
        Get-Content $script:buildLog -Raw | Should -Not -Match 'invoked cargo (clippy|test|build)|invoked flutter test'
        $script:releaseRoot | Should -Not -Exist
    }
    It 'removes the passing test sandbox before building Windows' {
        Initialize-FixtureFailure -Root $root -Markers 'fail-build-windows'
        $cargoStub = Join-Path $root 'bin/cargo.cmd'
        $flutterStub = Join-Path $root 'bin/flutter.cmd'
        $cargo = (Get-Content -LiteralPath $cargoStub -Raw).Replace('exit /b 0', @'
if "%1"=="test" echo %CXV_TEST_SANDBOX_PARENT%>"%~dp0tested-sandbox"
exit /b 0
'@)
        $flutter = (Get-Content -LiteralPath $flutterStub -Raw).Replace('if exist "%~dp0fail-%1-%2" exit /b 37', @'
if not "%1"=="build" goto skip-sandbox-check
if not exist "%~dp0tested-sandbox" exit /b 67
set /p testedSandbox=<"%~dp0tested-sandbox"
if exist "%testedSandbox%" exit /b 68
echo Test sandbox absent at Windows build
:skip-sandbox-check
if exist "%~dp0fail-%1-%2" exit /b 37
'@)
        Set-Content -LiteralPath $cargoStub -Value $cargo -Encoding ascii
        Set-Content -LiteralPath $flutterStub -Value $flutter -Encoding ascii
        { & $script:runner -OutputDirectory $script:releaseRoot *> $script:buildLog } | Should -Throw '*Build Windows release*37*'
        Get-Content -LiteralPath $script:buildLog | Should -Contain 'Test sandbox absent at Windows build'
        @(Get-ChildItem -LiteralPath $script:releaseSandboxParent -Directory | Where-Object FullName -notin $script:existingReleases).Count | Should -Be 0
        $script:releaseRoot | Should -Not -Exist
    }
}

Describe 'Script checks in a disposable checkout' {
    AfterEach {
        $env:PATH = $script:originalPath
        $env:CXV_TEST_SANDBOX_PARENT = $script:originalSandboxParent
    }
    It 'routes Pester and Python into one sandbox (Python exit <PythonExit>, defer <Defer>)' -ForEach @(
        @{ PythonExit = 0; Defer = $false }, @{ PythonExit = 31; Defer = $false }, @{ PythonExit = 0; Defer = $true }
    ) {
        $root = Initialize-RunnerFixture
        $runner = Join-Path $root 'scripts/test_scripts.ps1'
        Copy-Item -LiteralPath (Join-Path $script:sourceScripts 'test_scripts.ps1') -Destination $runner -Force
        $parent = Join-Path $script:runnerScratch (Split-Path $root -Leaf)
        $env:CXV_TEST_SANDBOX_PARENT = $parent
        @'
Describe 'Child process sandbox parent' {
    It 'receives a runner-owned parent' {
        New-Item -ItemType Directory -Path (Join-Path $env:CXV_TEST_SANDBOX_PARENT 'pester-fixture') -Force | Out-Null
        $env:CXV_TEST_SANDBOX_PARENT | Should -BeLike '*powershell-*children'
    }
}
'@ | Set-Content -LiteralPath (Join-Path $root 'scripts/Probe.Tests.ps1')
        @'
import os
from pathlib import Path
parent = Path(os.environ['CXV_TEST_SANDBOX_PARENT'])
assert parent.name == 'children' and parent.parent.name.startswith('powershell-'), parent
(parent / 'py-fixture').mkdir()
print('Ran 1 test in 0s')
'@ + "`nraise SystemExit($PythonExit)" | Set-Content -LiteralPath (Join-Path $root 'scripts/test_fast_tests.py')
        "print('Ran 1 test in 0s')" | Set-Content -LiteralPath (Join-Path $root 'scripts/test_selection_invariant.py')

        $collector = Join-Path $root 'collector/target/release/codex-sessions-collector.exe'
        $pwsh = (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source
        $arguments = @('-NoProfile', '-File', $runner, '-CollectorPath', $collector)
        if ($Defer) { $arguments += '-DeferSandboxCleanup' }
        $output = (& $pwsh @arguments) -join "`n"
        $code = $LASTEXITCODE
        if ($PythonExit -eq 0 -and -not $Defer) {
            $output | Should -Match 'All script checks passed'
            $code | Should -Be 0
            @(Get-ChildItem -LiteralPath $parent).Count | Should -Be 0
        } else {
            $code | Should -Be ([int]($PythonExit -ne 0))
            $output | Should -Match "test_fast_tests.py: exit $PythonExit"
            $retained = @(Get-ChildItem -LiteralPath $parent -Directory)
            $retained.Count | Should -Be 1
            if ($PythonExit -ne 0) {
                $output | Should -Match ([regex]::Escape($retained[0].FullName))
            }
            (Join-Path $retained[0].FullName 'children/pester-fixture') | Should -Exist
            (Join-Path $retained[0].FullName 'children/py-fixture') | Should -Exist
        }
    }
}

Describe 'Direct Pester suite cleanup' {
    AfterEach {
        $env:PATH = $script:originalPath
        $env:CXV_TEST_SANDBOX_PARENT = $script:originalSandboxParent
    }
    It 'handles a direct FastTestLaunch run with failure set to <Fail>' -ForEach @(
        @{ Fail = $false }, @{ Fail = $true }
    ) {
        $root = Initialize-RunnerFixture
        $suite = Join-Path $root 'scripts/test_support/FastTestLaunch.Tests.ps1'
        Copy-Item -LiteralPath (Join-Path $script:sourceScripts 'test_support/FastTestLaunch.Tests.ps1') -Destination $suite
        if ($Fail) {
            Add-Content -LiteralPath $suite -Value @'
Describe 'Intentional execution failure' {
    It 'fails after allocation' { $script:context.Root | Should -Not -Exist }
}
'@
        }
        $probe = Join-Path $root 'direct-pester.ps1'
        @'
param([string] $Suite)
Import-Module Pester -MinimumVersion 5.0
$config = New-PesterConfiguration
$config.Run.Path = $Suite
$config.Run.PassThru = $true
$config.Filter.FullName = @(
    'Focused test launch boundary.builds an accepted Flutter launch for*',
    'Intentional execution failure.*'
)
$config.Output.Verbosity = 'Detailed'
$result = Invoke-Pester -Configuration $config
if ($result.PassedCount -ne 3 -or $result.FailedBlocksCount) { exit 2 }
exit $result.FailedCount
'@ | Set-Content -LiteralPath $probe
        $env:CXV_TEST_SANDBOX_PARENT = Join-Path $script:runnerScratch (Split-Path $root -Leaf)
        $pwsh = (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source
        $output = (& $pwsh -NoProfile -File $probe -Suite $suite) -join "`n"
        $LASTEXITCODE | Should -Be ([int]$Fail) -Because $output
        $profiles = @(Get-ChildItem -LiteralPath $env:CXV_TEST_SANDBOX_PARENT -Directory)
        $profiles.Count | Should -Be ([int]$Fail)
        if ($Fail) {
            $output | Should -Match ('Retained test sandbox: ' + [regex]::Escape($profiles[0].FullName))
        }
    }
}
