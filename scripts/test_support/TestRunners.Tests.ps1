BeforeAll {
    Set-StrictMode -Version Latest
    $script:sourceScripts = Split-Path -Parent $PSScriptRoot
    $script:originalPath = $env:PATH
    $script:originalSandboxParent = $env:CXV_TEST_SANDBOX_PARENT
    . (Join-Path $PSScriptRoot 'TestEnvironment.ps1')
    $script:runnerScratch = (New-TestEnvironment).Root

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
if exist "%~dp0fail-%1-%2" exit /b 37
if "$tool"=="cargo" if "%1"=="test" if exist "%~dp0rust-fail" exit /b 101
if "$tool"=="flutter" if "%1"=="pub" if exist "%~dp0pub-fail" exit /b 42
if "$tool"=="flutter" if "%1"=="test" if "%2"=="integration_test" if exist "%~dp0integration-fail" exit /b 23
exit /b 0
"@ | Set-Content -LiteralPath (Join-Path $root "bin/$tool.cmd") -Encoding ascii
        }
        @'
param([string] $CollectorPath)
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
        $output = & $script:runner -AllowWide -OutputRoot $script:outputRoot
        $LASTEXITCODE | Should -Not -Be 0
        $steps = Get-Content (Join-Path $script:outputRoot 'timings.json') -Raw | ConvertFrom-Json
        $steps.name | Should -Be @('rust-all','native-debug-build','flutter-pub-get','flutter-test','script-checks')
        foreach ($step in $steps | Select-Object -Skip 1) {
            $step.status | Should -Be 'passed'
            $step.exit_code | Should -Be 0
        }
        $run = Get-Content (Join-Path $script:outputRoot 'run.json') -Raw | ConvertFrom-Json
        $run.failed[0].exit_code | Should -Be 101
        $run.failed[0].log | Should -Exist
        ($output -join "`n") | Should -Match 'rust-all.*101.*rust-all\.log'
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
    It 'keeps the script-check test profiles under the reported run sandbox parent' {
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
        $expectedParent = Join-Path $script:outputRoot 'sandboxes/script-checks'
        $run.script_check_sandbox_parent | Should -Be $expectedParent
        $profilePath = (Get-Content (Join-Path $script:outputRoot 'script-checks.log'))[-1]
        (Split-Path $profilePath -Parent) | Should -Be $expectedParent
        $profilePath | Should -Exist
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
        $env:CXV_TEST_SANDBOX_PARENT = $script:runnerScratch
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
        $text | Should -Not -Match 'Build Windows release|invoked flutter build windows'
        $script:releaseRoot | Should -Not -Exist
    }
    It 'stops on collector formatting failure before tests or builds' {
        Initialize-FixtureFailure -Root $root -Markers 'fail-fmt---check'
        { & $script:runner -OutputDirectory $script:releaseRoot *> $script:buildLog } | Should -Throw '*Check collector formatting*37*'
        Get-Content $script:buildLog -Raw | Should -Not -Match 'invoked cargo (clippy|test|build)|invoked flutter test'
        $script:releaseRoot | Should -Not -Exist
    }
}
