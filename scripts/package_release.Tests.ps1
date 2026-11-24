AfterAll {
    $ownedEnvironment = Get-Variable testEnvironment -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    if ($ownedEnvironment) {
        Complete-PesterTestEnvironment $ownedEnvironment (Get-Variable ____Pester -ValueOnly -ErrorAction SilentlyContinue)
    }
}

BeforeAll {
    . (Join-Path $PSScriptRoot 'test_support/TestEnvironment.ps1')
    $script:testEnvironment = New-TestEnvironment
    $script:repoSample = Join-Path (Split-Path -Parent $PSScriptRoot) 'settings.sample.toml'
    $script:sampleHash = (Get-FileHash -LiteralPath $script:repoSample -Algorithm SHA256).Hash

    # A copy of package_release.ps1 beside a stub build script, so packaging
    # runs on fixture build output instead of the compiler and test pipeline.
    $script:fixtureRepo = Join-Path $script:testEnvironment.Root 'repo'
    $fixtureScripts = Join-Path $script:fixtureRepo 'scripts'
    New-Item -ItemType Directory -Path $fixtureScripts -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'package_release.ps1') -Destination $fixtureScripts
    Copy-Item -LiteralPath $script:repoSample -Destination $script:fixtureRepo
    Set-Content -LiteralPath (Join-Path $fixtureScripts 'build_windows.ps1') -Encoding utf8 -Value @'
param([string] $OutputDirectory)
if (-not (Test-Path -LiteralPath $OutputDirectory)) { throw 'Missing fixture build' }
$global:LASTEXITCODE = 0
'@
    $script:packageScript = Join-Path $fixtureScripts 'package_release.ps1'

    function Initialize-FixtureBuild([string] $Name) {
        $build = Join-Path $script:testEnvironment.Root $Name
        New-Item -ItemType Directory -Path $build | Out-Null
        foreach ($file in @('codex_session_viewer.exe', 'codex-sessions-collector.exe', 'codex-sessions-hub.exe',
                'codex-sessions-scan-launcher.exe', 'flutter_windows.dll', 'README.md')) {
            Set-Content -LiteralPath (Join-Path $build $file) -Value 'fixture'
        }
        foreach ($folder in @('data', 'sql', 'assets')) {
            New-Item -ItemType Directory -Path (Join-Path $build $folder) | Out-Null
            Set-Content -LiteralPath (Join-Path $build "$folder/fixture.txt") -Value 'fixture'
        }
        Set-Content -LiteralPath (Join-Path $build 'settings.toml') -Value '[pricing.openrouter]', 'api_key = "private-test-marker"'
        # A stale sample in the build output must be replaced by the repository sample.
        Set-Content -LiteralPath (Join-Path $build 'settings.sample.toml') -Value '# stale sample'
        return $build
    }
}

Describe 'Release packaging keeps local settings private' {
    It 'ships the repository sample and never the local settings.toml' {
        $build = Initialize-FixtureBuild 'windows'
        $localSettings = Join-Path $build 'settings.toml'
        $localHash = (Get-FileHash -LiteralPath $localSettings -Algorithm SHA256).Hash
        $package = Join-Path $script:testEnvironment.Root 'package'
        $archive = Join-Path $script:testEnvironment.Root 'release.zip'

        & $script:packageScript -BuildOutputDirectory $build -PackageDirectory $package -ArchivePath $archive | Out-Null

        (Get-FileHash -LiteralPath $localSettings -Algorithm SHA256).Hash | Should -Be $localHash
        Join-Path $package 'settings.toml' | Should -Not -Exist
        (Get-FileHash -LiteralPath (Join-Path $package 'settings.sample.toml') -Algorithm SHA256).Hash | Should -Be $script:sampleHash
        Join-Path $package 'codex_session_viewer.exe' | Should -Exist
        Join-Path $package 'data/fixture.txt' | Should -Exist

        $expanded = Join-Path $script:testEnvironment.Root 'expanded'
        Expand-Archive -LiteralPath $archive -DestinationPath $expanded
        Join-Path $expanded 'settings.toml' | Should -Not -Exist
        (Get-FileHash -LiteralPath (Join-Path $expanded 'settings.sample.toml') -Algorithm SHA256).Hash | Should -Be $script:sampleHash
        @(Get-ChildItem -LiteralPath $expanded -Recurse -File |
            Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -like '*private-test-marker*' }) | Should -HaveCount 0
    }

    It 'rejects a package directory that overlaps the build output, leaving it unchanged' {
        $build = Initialize-FixtureBuild 'overlap'
        $before = @(Get-ChildItem -LiteralPath $build -Recurse -File | ForEach-Object {
                "$($_.FullName)=$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)" })
        $archive = Join-Path $script:testEnvironment.Root 'overlap.zip'

        foreach ($package in @($build, (Join-Path $build 'package'), (Split-Path -Parent $build))) {
            { & $script:packageScript -BuildOutputDirectory $build -PackageDirectory $package -ArchivePath $archive } |
                Should -Throw '*separate, non-nested*'
        }

        @(Get-ChildItem -LiteralPath $build -Recurse -File | ForEach-Object {
                "$($_.FullName)=$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)" }) | Should -Be $before
        $archive | Should -Not -Exist
    }
}
