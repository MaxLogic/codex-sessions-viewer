BeforeAll {
    . (Join-Path $PSScriptRoot 'TestEnvironment.ps1')
    . (Join-Path $PSScriptRoot 'FastTestLaunch.ps1')
    $script:repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    $script:context = New-TestEnvironment
    $script:cargo = (Get-Command cargo -CommandType Application | Select-Object -First 1).Source
    $script:flutter = (Get-Command flutter | Select-Object -First 1).Source
}
Describe 'Focused test launch boundary' {
    It 'builds an accepted Flutter launch for <target>' -TestCases @(
        @{ target = 'test'; expected = 'test' }
        @{ target = 'integration_test'; expected = 'test|integration_test' }
        @{
            target = 'test/app/runtime_scan_app_test.dart'
            filter = 'pricing commits between background scan batches before scan completion'
            expected = 'test|test/app/runtime_scan_app_test.dart|--plain-name|pricing commits between background scan batches before scan completion'
        }
    ) {
        param($target, $filter, $expected)
        Set-StrictMode -Version Latest
        # Same shape as fast_tests.py selection JSON: filters only for filtered files.
        $filters = [pscustomobject]@{}
        if ($filter) { $filters | Add-Member -NotePropertyName $target -NotePropertyValue $filter }
        $arguments = @(Get-FastFlutterTestArgumentList -Target $target -Filters $filters)
        { Assert-TestLaunch $script:context $script:flutter $arguments -WorkingDirectory (Join-Path $script:repo 'app') } | Should -Not -Throw
        ($arguments -join '|') | Should -BeExactly $expected
    }
    It 'admits the existing release commands and bounded targets' {
        foreach ($arguments in @(@('test','--locked','--no-fail-fast'), @('test','--locked','--lib'), @('test','--locked','--test','resident'))) {
            { Assert-TestLaunch $script:context $script:cargo $arguments -WorkingDirectory (Join-Path $script:repo 'collector') } | Should -Not -Throw
        }
        foreach ($arguments in @(@('test'), @('test','integration_test'), @('test','test/database/application_maintenance_test.dart'))) {
            { Assert-TestLaunch $script:context $script:flutter $arguments -WorkingDirectory (Join-Path $script:repo 'app') } | Should -Not -Throw
        }
        { Assert-TestLaunch $script:context $script:flutter @('test','test/app/runtime_scan_app_test.dart','--plain-name','pricing commits between background scan batches before scan completion') -WorkingDirectory (Join-Path $script:repo 'app') } | Should -Not -Throw
        { Assert-TestLaunch $script:context $script:flutter @('test','--machine','test/database/application_maintenance_test.dart','test/pricing/hub_price_history_test.dart') -WorkingDirectory (Join-Path $script:repo 'app') } | Should -Not -Throw
    }
    It 'rejects injected flags, missing targets, traversal and wrong working directory' {
        foreach ($arguments in @(@('test','--locked','--test','missing_target'), @('test','--locked','--test','../resident'), @('test','--locked','--lib','--manifest-path','other/Cargo.toml'))) {
            { Assert-TestLaunch $script:context $script:cargo $arguments -WorkingDirectory (Join-Path $script:repo 'collector') } | Should -Throw
        }
        foreach ($arguments in @(@('test','test/../lib/main.dart'), @('test','--update-goldens'), @('test','test/missing_test.dart'))) {
            { Assert-TestLaunch $script:context $script:flutter $arguments -WorkingDirectory (Join-Path $script:repo 'app') } | Should -Throw
        }
        { Assert-TestLaunch $script:context $script:flutter @('test','test/app/runtime_scan_app_test.dart','--plain-name','unrelated') -WorkingDirectory (Join-Path $script:repo 'app') } | Should -Throw
        { Assert-TestLaunch $script:context $script:flutter @('test','--machine','test/database/application_maintenance_test.dart','--update-goldens') -WorkingDirectory (Join-Path $script:repo 'app') } | Should -Throw
        { Assert-TestLaunch $script:context $script:flutter @('test','--machine','test/../lib/main.dart') -WorkingDirectory (Join-Path $script:repo 'app') } | Should -Throw
        { Assert-TestLaunch $script:context $script:cargo @('test','--locked','--lib') -WorkingDirectory $script:repo } | Should -Throw
    }
}
