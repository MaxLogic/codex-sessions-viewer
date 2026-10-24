BeforeAll {
    . (Join-Path $PSScriptRoot 'test_support/TestEnvironment.ps1')
    $script:testEnvironment = New-TestEnvironment
    $buildPath = Join-Path $PSScriptRoot 'build_windows.ps1'
    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($buildPath, [ref]$tokens, [ref]$parseErrors)
    foreach ($name in @('Resolve-ReleaseFinalPath', 'Test-ReleaseProcessPath', 'Get-ReleaseResidentEndpoint', 'Open-ReleaseResidentConnection', 'Send-ReleaseResidentRequest', 'Invoke-ReleaseResidentStop', 'Stop-ReleaseProcess')) {
        $definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
        . ([scriptblock]::Create($definition.Extent.Text))
    }
}

Describe 'Physical release process ownership' {
    BeforeEach {
        $script:release = Join-Path $script:testEnvironment.Root 'release'
        $script:external = Join-Path $script:testEnvironment.Root 'other-deployment'
        New-Item -ItemType Directory -Path $script:release, $script:external -Force | Out-Null
        $script:internalImage = Join-Path $script:release 'collector.exe'
        Set-Content -LiteralPath $script:internalImage -Value 'fixture image'
        Set-Content -LiteralPath (Join-Path $script:external 'collector.exe') -Value 'external fixture image'
        Mock Get-ReleaseResidentEndpoint { 'fixture-pipe' }
        Mock Open-ReleaseResidentConnection { [pscustomobject]@{} }
        Mock Send-ReleaseResidentRequest {
            if ($Operation -eq 'status') { return [pscustomobject]@{event='status';pid=101} }
            return [pscustomobject]@{event='stopping'}
        }
        Mock Stop-Process -RemoveParameterType InputObject {}
        Mock Get-Process {
            $process = [pscustomobject]@{Id=101;Path=$script:image;StartTime=[datetime]'2026-10-23'}
            $process | Add-Member ScriptMethod WaitForExit { param($timeout) return $timeout -eq 10000 }
            return $process
        }
        Mock Get-CimInstance { @([pscustomobject]@{ProcessId=101;ExecutablePath=$script:image}) }
    }
    It 'leaves an external image reached through an output-folder junction untouched' {
        $junction = Join-Path $script:release 'linked'
        New-Item -ItemType Junction -Path $junction -Target $script:external | Out-Null
        try {
            $script:image = Join-Path $junction 'collector.exe'
            Test-ReleaseProcessPath $script:image $script:release | Should -BeFalse
            Invoke-ReleaseResidentStop $script:internalImage 'fixture.sqlite' $script:release
            Stop-ReleaseProcess $script:release
            Should -Invoke Send-ReleaseResidentRequest -Times 0 -ParameterFilter {$Operation -eq 'shutdown'}
            Should -Invoke Stop-Process -Times 0
        } finally {
            [IO.Directory]::Delete($junction)
        }
    }
    It 'still stops an image physically inside the output folder' {
        $script:image = $script:internalImage
        Test-ReleaseProcessPath $script:image $script:release | Should -BeTrue
        Invoke-ReleaseResidentStop $script:internalImage 'fixture.sqlite' $script:release
        Should -Invoke Get-Process -Times 2 -ParameterFilter {$Id -eq 101}
        Should -Invoke Send-ReleaseResidentRequest -Times 1 -ParameterFilter {$Operation -eq 'shutdown'}
    }
    It 'does not own an image whose final path cannot be opened' {
        Test-ReleaseProcessPath (Join-Path $script:release 'missing.exe') $script:release | Should -BeFalse
    }
}

Describe 'Release process shutdown' {
    BeforeEach {
        Mock Resolve-ReleaseFinalPath { [IO.Path]::GetFullPath($LiteralPath) }
        $script:events = [Collections.Generic.List[string]]::new()
        $script:stopper = [pscustomobject]@{ ExitCode = 0 }
        $script:stopper | Add-Member ScriptMethod WaitForExit { param($timeout) $script:events.Add("wait $timeout"); return $true }
        $script:stopper | Add-Member ScriptMethod Dispose { $script:events.Add('dispose') }
        $script:stopper | Add-Member ScriptMethod Kill { $script:events.Add('kill stopper') }
        Mock Test-Path { $true }
        Mock Get-ReleaseResidentEndpoint { $null }
        Mock Start-Process { $script:events.Add('graceful'); return $script:stopper }
        Mock Stop-Process -RemoveParameterType InputObject { $script:events.Add("force $($InputObject.Id)") }
        Mock Get-Process {
            $process = [pscustomobject]@{ Id = $Id; Path = 'F:\fixture\release\viewer.exe' }
            $process | Add-Member ScriptMethod WaitForExit { param($timeout) return $timeout -eq 10000 }
            return $process
        }
    }
    It 'exchanges status and shutdown over one real fixture pipe' {
        if (-not ('Cxv185PipeFixture' -as [type])) {
            Add-Type -TypeDefinition @"
using System;
using System.IO;
using System.IO.Pipes;
using System.Text;
using System.Threading.Tasks;
public static class Cxv185PipeFixture {
    public static Task<string> Run(NamedPipeServerStream server) {
        return Task.Run(() => {
            server.WaitForConnection();
            using (var reader = new StreamReader(server, new UTF8Encoding(false), false, 1024, true))
            using (var writer = new StreamWriter(server, new UTF8Encoding(false), 1024, true)) {
                writer.AutoFlush = true;
                var status = reader.ReadLine();
                writer.WriteLine("{\"v\":1,\"id\":\"build-status\",\"event\":\"status\",\"pid\":101}");
                var shutdown = reader.ReadLine();
                writer.WriteLine("{\"v\":1,\"id\":\"build-shutdown\",\"event\":\"stopping\"}");
                return status + "\n" + shutdown;
            }
        });
    }
}
"@
        }
        $script:pipeName = 'cxv185-test-' + [guid]::NewGuid().ToString('N')
        $server = [IO.Pipes.NamedPipeServerStream]::new($script:pipeName, [IO.Pipes.PipeDirection]::InOut, 1, [IO.Pipes.PipeTransmissionMode]::Byte, [IO.Pipes.PipeOptions]::Asynchronous)
        $serverTask = [Cxv185PipeFixture]::Run($server)
        Mock Get-ReleaseResidentEndpoint { $script:pipeName }
        Mock Get-Process {
            $process = [pscustomobject]@{Id=101;Path='F:\fixture\release\collector.exe';StartTime=[datetime]'2026-10-23'}
            $process | Add-Member ScriptMethod WaitForExit { param($timeout) return $timeout -eq 10000 }
            return $process
        }
        # These tests mock the boundary by default; this case exercises the actual pipe adapter.
        try {
            Invoke-ReleaseResidentStop 'F:\fixture\release\collector.exe' 'F:\fixture\db.sqlite' 'F:\fixture\release'
            $serverTask.Wait(3000) | Should -BeTrue
            $requests = $serverTask.Result.Split("`n") | ConvertFrom-Json
            $requests[0].op | Should -Be 'status'
            $requests[1].op | Should -Be 'shutdown'
            Should -Invoke Get-Process -Times 2 -ParameterFilter {$Id -eq 101}
        } finally {
            $server.Dispose()
        }
    }
    It 'matches only image paths inside the exact output directory' {
        Test-ReleaseProcessPath 'F:\fixture\release\viewer.exe' 'F:\fixture\release' | Should -BeTrue
        Test-ReleaseProcessPath 'f:\fixture\release\nested\collector.exe' 'F:\fixture\release\' | Should -BeTrue
        Test-ReleaseProcessPath 'F:\fixture\release-other\viewer.exe' 'F:\fixture\release' | Should -BeFalse
        Test-ReleaseProcessPath $null 'F:\fixture\release' | Should -BeFalse
    }
    It 'does not shut down another deployment when a target one-shot shares the database' {
        Mock Get-CimInstance { @(
          [pscustomobject]@{ ProcessId=101; ExecutablePath='F:\fixture\release\codex-sessions-collector.exe' },
          [pscustomobject]@{ ProcessId=202; ExecutablePath='F:\dev\codex-sessions-collector.exe' }) }
        Mock Get-ReleaseResidentEndpoint { 'fixture-pipe' }
        Mock Open-ReleaseResidentConnection { [pscustomobject]@{} }
        Mock Send-ReleaseResidentRequest { [pscustomobject]@{v=1;id='build-status';event='status';pid=202} }
        Mock Get-Process {
          $path = if ($Id -eq 202) { 'F:\dev\codex-sessions-collector.exe' } else { 'F:\fixture\release\viewer.exe' }
          $process=[pscustomobject]@{Id=$Id;Path=$path;StartTime=[datetime]'2026-10-23'}
          $process | Add-Member ScriptMethod WaitForExit { param($timeout) return $timeout -eq 10000 }
          return $process
        }
        Stop-ReleaseProcess 'F:\fixture\release'
        Should -Invoke Start-Process -Times 0
        Should -Invoke Send-ReleaseResidentRequest -Times 0 -ParameterFilter {$Operation -eq 'shutdown'}
        Should -Invoke Get-Process -Times 1 -ParameterFilter {$Id -eq 202}
        Should -Invoke Stop-Process -Times 0 -ParameterFilter {$InputObject.Id -eq 202}
        Should -Invoke Stop-Process -Times 1 -ParameterFilter {$InputObject.Id -eq 101}
    }
    It 'shuts down the verified target resident on the same status connection' {
        $script:connection=[pscustomobject]@{}
        Mock Get-ReleaseResidentEndpoint { 'fixture-pipe' }
        Mock Open-ReleaseResidentConnection { $script:connection }
        Mock Send-ReleaseResidentRequest {
            if ($Operation -eq 'status') { return [pscustomobject]@{v=1;id='build-status';event='status';pid=101} }
            return [pscustomobject]@{v=1;id='build-shutdown';event='stopping'}
        }
        Mock Get-Process {
            $process=[pscustomobject]@{Id=101;Path='F:\fixture\release\collector.exe';StartTime=[datetime]'2026-10-23'}
            $process | Add-Member ScriptMethod WaitForExit { param($timeout) $script:events.Add("wait $timeout"); return $true }
            return $process
        }
        Invoke-ReleaseResidentStop 'F:\fixture\release\codex-sessions-collector.exe' 'F:\fixture\db.sqlite' 'F:\fixture\release'
        Should -Invoke Get-Process -Times 2 -ParameterFilter {$Id -eq 101}
        Should -Invoke Send-ReleaseResidentRequest -Times 1 -ParameterFilter {$Operation -eq 'shutdown' -and [object]::ReferenceEquals($Connection,$script:connection)}
        $script:events | Should -Contain 'wait 10000'
    }
    It 'refuses shutdown when the PID image is replaced during ownership checks' {
        Mock Get-ReleaseResidentEndpoint { 'fixture-pipe' }
        Mock Open-ReleaseResidentConnection { [pscustomobject]@{} }
        Mock Send-ReleaseResidentRequest { [pscustomobject]@{v=1;id='build-status';event='status';pid=101} }
        $script:checks=0
        Mock Get-Process {
            $script:checks++
            [pscustomobject]@{Id=101;Path=$(if($script:checks -eq 1){'F:\fixture\release\collector.exe'}else{'F:\dev\collector.exe'});StartTime=[datetime]'2026-10-23'}
        }
        Invoke-ReleaseResidentStop 'F:\fixture\release\collector.exe' 'F:\fixture\db.sqlite' 'F:\fixture\release'
        Should -Invoke Get-Process -Times 2 -ParameterFilter {$Id -eq 101}
        Should -Invoke Send-ReleaseResidentRequest -Times 0 -ParameterFilter {$Operation -eq 'shutdown'}
    }
    It 'rechecks the process image before force-stopping a reused PID' {
        Mock Get-CimInstance { @([pscustomobject]@{ProcessId=101;ExecutablePath='F:\fixture\release\viewer.exe'}) }
        Mock Get-Process { [pscustomobject]@{Id=101;Path='F:\another\viewer.exe'} }
        Stop-ReleaseProcess 'F:\fixture\release'
        Should -Invoke Get-Process -Times 1 -ParameterFilter {$Id -eq 101}
        Should -Invoke Stop-Process -Times 0
    }
}
