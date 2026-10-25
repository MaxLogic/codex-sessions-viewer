BeforeAll {
    . (Join-Path $PSScriptRoot 'TestEnvironment.ps1')
    $script:context = New-TestEnvironment
}
Describe 'Shared PowerShell test profile boundary' {
    It 'roundtrips absent and empty environment entries after <Mode>' -ForEach @(
        @{ Mode = 'success' }, @{ Mode = 'exception' }, @{ Mode = 'native nonzero exit' }
    ) {
        $keys = @('PUB_CACHE', 'HOME', 'INCLUDE', 'CXV_TEST_INHERITED_SENTINEL')
        $saved = [Environment]::GetEnvironmentVariables('Process')
        $python = (Get-Command python -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
        $probe = 'import os,json; print(json.dumps({k:os.environ.get(k) for k in ["PUB_CACHE","HOME","INCLUDE","CXV_TEST_INHERITED_SENTINEL"]}))'
        try {
            foreach ($key in @('PUB_CACHE', 'HOME')) { [Environment]::SetEnvironmentVariable($key, [NullString]::Value, 'Process') }
            [Environment]::SetEnvironmentVariable('INCLUDE', '', 'Process')
            [Environment]::SetEnvironmentVariable('CXV_TEST_INHERITED_SENTINEL', 'inherited', 'Process')
            $isolated = New-TestEnvironment
            $operation = {
                Invoke-TestEnvironment $isolated {
                    $native = (& $python -I -c $probe) | ConvertFrom-Json
                    $null -eq $native.CXV_TEST_INHERITED_SENTINEL | Should -BeTrue
                    [Environment]::GetEnvironmentVariables('Process').Contains('CXV_TEST_INHERITED_SENTINEL') | Should -BeFalse
                    $native.HOME | Should -Be $isolated.Variables['HOME']
                    $native.PUB_CACHE | Should -Be $isolated.Variables['PUB_CACHE']
                    $native.INCLUDE | Should -BeExactly ''
                    $null -eq $native.INCLUDE | Should -BeFalse
                    if ($Mode -eq 'exception') { throw 'environment roundtrip probe' }
                }
            }
            if ($Mode -eq 'exception') {
                $operation | Should -Throw '*environment roundtrip probe*'
            } elseif ($Mode -eq 'native nonzero exit') {
                Invoke-TestProcess $isolated $env:ComSpec @('/d', '/c', 'exit 7')
                $LASTEXITCODE | Should -Be 7
            } else { & $operation }
            $restored = [Environment]::GetEnvironmentVariables('Process')
            foreach ($key in @('PUB_CACHE', 'HOME')) { $restored.Contains($key) | Should -BeFalse }
            $restored.Contains('INCLUDE') | Should -BeTrue
            $restored['INCLUDE'] | Should -BeExactly ''
            $restored['CXV_TEST_INHERITED_SENTINEL'] | Should -BeExactly 'inherited'
            $native = (& $python -I -c $probe) | ConvertFrom-Json
            $null -eq $native.PUB_CACHE | Should -BeTrue
            $null -eq $native.HOME | Should -BeTrue
            $native.INCLUDE | Should -BeExactly ''
            $null -eq $native.INCLUDE | Should -BeFalse
            $native.CXV_TEST_INHERITED_SENTINEL | Should -BeExactly 'inherited'
        } finally {
            foreach ($key in $keys) {
                $value = if ($saved.Contains($key)) { $saved[$key] } else { [NullString]::Value }
                [Environment]::SetEnvironmentVariable($key, $value, 'Process')
            }
        }
    }
    It 'admits both exact NoProfile sampler child forms under strict mode' {
        Set-StrictMode -Version Latest
        $hostPath = 'C:\Program Files\PowerShell\7\pwsh.exe'
        $scriptPath = Join-Path $PSScriptRoot '../benchmark_scan_memory.ps1'
        $scriptPath = [IO.Path]::GetFullPath($scriptPath)
        $arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$scriptPath,'-Mode','InternalSelfTestChild','-ChildExitCode','7')
        { Assert-TestLaunch $script:context $hostPath $arguments } | Should -Not -Throw
        { Assert-TestLaunch $script:context $hostPath ($arguments + @('-ChildAllocationMb','32')) } | Should -Not -Throw
    }
    It 'rejects system variables pointing into a profile' {
        $variables = @{} + $script:context.Variables
        foreach ($key in @('SYSTEMROOT','WINDIR','COMSPEC','PROGRAMDATA','PROGRAMFILES','SYSTEMDRIVE')) {
            $variables[$key] = Join-Path $script:context.Variables['APPDATA'] 'poison-system'
        }
        $poisoned = [pscustomobject]@{Root=$script:context.Root;Keys=$script:context.Keys;Original=$script:context.Original;Variables=$variables}
        { Assert-TestEnvironment $poisoned } | Should -Throw '*system*'
    }
    It 'rejects external and unregistered loopback hub endpoints before launch' {
        foreach ($url in @('https://example.invalid','http://127.0.0.1:12345')) {
            { Assert-TestLaunch $script:context $env:CODEX_SESSIONS_COLLECTOR_EXE @('codex','verify','--hub-url',$url) } | Should -Throw '*endpoint*'
        }
        $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
        $listener.Start()
        try {
            $url = 'http://127.0.0.1:' + $listener.LocalEndpoint.Port
            Register-TestEndpoint $script:context $url
            { Assert-TestLaunch $script:context $env:CODEX_SESSIONS_COLLECTOR_EXE @('codex','verify','--hub-url',$url) } | Should -Not -Throw
        } finally { $listener.Stop() }
    }
    It 'rejects quoted and unsupported TOML keys before spawning' {
        $settings = Join-Path $script:context.Root 'quoted.toml'
        Set-Content $settings "[paths]`n`"windows_codex_path`" = 'C:\synthetic-real-profile\sessions'"
        { Assert-TestSettingsFile $script:context $settings } | Should -Throw '*isolation*'
    }
    It 'denies unlisted executables and arbitrary inherited environment entries' {
        foreach ($tool in @('schtasks.exe', 'reg.exe', 'powershell.exe', 'wsl.exe', 'unknown.exe')) {
            { Assert-TestLaunch $script:context $tool @('/Create') } | Should -Throw '*isolation*'
        }
        $script:context.Variables.ContainsKey('PSModulePath') | Should -BeFalse
    }
    It 'rejects positional ingest input before spawn' {
        { Invoke-TestProcess $script:context 'missing-native-probe.exe' @('codex', 'ingest', 'C:\synthetic-real-profile\input', '--db', (Join-Path $script:context.Root 'owned.sqlite')) } | Should -Throw '*isolation rejected*'
    }
    It 'redirects every profile-derived default' {
        foreach ($key in $script:context.Keys) {
            { Assert-TestPath $script:context $script:context.Variables[$key] } | Should -Not -Throw
        }
        Invoke-TestEnvironment $script:context {
            $env:LOCALAPPDATA | Should -Be $script:context.Variables['LOCALAPPDATA']
            $env:APPDATA | Should -Be $script:context.Variables['APPDATA']
        }
    }
    It 'rejects every escaped profile override before attempting to spawn' {
        foreach ($key in $script:context.Keys) {
            $override = @{}; $override[$key] = Join-Path (Split-Path $script:context.Root) 'synthetic-real-profile'
            { Invoke-TestProcess $script:context 'missing-native-isolation-probe.exe' @('version') -Environment $override } | Should -Throw '*isolation rejected*'
        }
    }
    It 'rejects an unknown collector path variable' {
        { Invoke-TestProcess $script:context 'missing-native-isolation-probe.exe' -Environment @{CODEX_SESSIONS_COLLECTOR_FUTURE_LOG='C:\synthetic-real-profile\log'} } | Should -Throw '*isolation rejected*'
    }
    It 'rejects escaped settings values before native parsing' {
        $settings = Join-Path $script:context.Root 'unsafe.toml'
        Set-Content -LiteralPath $settings -Value "[paths]`nwindows_codex_path = 'C:\synthetic-real-profile\sessions'"
        { Invoke-TestProcess $script:context 'missing-native-isolation-probe.exe' @('scan', '--settings', $settings) } | Should -Throw '*isolation rejected*'
    }
    It 'rejects junction traversal even when lexically owned' {
        $external = New-TestEnvironment
        $link = Join-Path $script:context.Root 'escape'
        New-Item -ItemType Junction -Path $link -Target $external.Root | Out-Null
        try { { Assert-TestPath $script:context (Join-Path $link 'log') } | Should -Throw '*reparse*' }
        finally { [IO.Directory]::Delete($link) }
    }
    It 'fails fast for a packaged viewer before Registry or Task Scheduler can be touched' {
        { Start-TestProcess -Context $script:context -FilePath 'codex_session_viewer.exe' } | Should -Throw '*refuses normal packaged-viewer startup*'
    }
    It 'starts native probes with the same guarded environment' {
        $child = Start-TestProcess -Context $script:context -FilePath $env:CODEX_SESSIONS_COLLECTOR_EXE -ArgumentList @('version') -RedirectOutput
        try {
            $output = $child.StandardOutput.ReadToEnd()
            $child.WaitForExit()
            $child.ExitCode | Should -Be 0
            $output | Should -Not -BeNullOrEmpty
        } finally { $child.Dispose() }
    }
    It 'preserves native nonzero exits for build step failure reporting' {
        Invoke-TestProcess -Context $script:context -FilePath $env:ComSpec -ArgumentList @('/d', '/c', 'exit 7')
        $LASTEXITCODE | Should -Be 7
    }
    It 'does not read poisoned inherited default settings' {
        $poison = New-TestEnvironment
        $sentinel = Join-Path $poison.Variables['APPDATA'] 'CodexSessionViewer/settings.toml'
        [IO.Directory]::CreateDirectory((Split-Path $sentinel)) | Out-Null
        [IO.File]::WriteAllText($sentinel, 'POISONED_INHERITED_SETTINGS = [')
        $saved = $env:APPDATA
        try {
            $env:APPDATA = $poison.Variables['APPDATA']
            $isolated = New-TestEnvironment
            $exe = $env:CODEX_SESSIONS_COLLECTOR_EXE
            $db = Join-Path $isolated.Root 'sentinel.sqlite'
            $output = Invoke-TestProcess $isolated $exe @('codex','scan','--standalone',$db,'--no-wsl-projects','--json')
            $LASTEXITCODE | Should -Be 0
            ($output -join '') | Should -Not -Match 'POISONED_INHERITED_SETTINGS'
            [IO.File]::ReadAllText($sentinel) | Should -Be 'POISONED_INHERITED_SETTINGS = ['
        } finally { $env:APPDATA = $saved }
    }
}
