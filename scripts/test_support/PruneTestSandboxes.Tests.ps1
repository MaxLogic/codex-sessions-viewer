BeforeAll {
    $script:pruneSource = Join-Path $PSScriptRoot '../prune_test_sandboxes.ps1'
    $script:environmentSource = Join-Path $PSScriptRoot 'TestEnvironment.ps1'
    $script:pwsh = Join-Path $PSHOME 'pwsh.exe'
}
Describe 'Pruning test sandboxes in a disposable checkout' {
    BeforeEach {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $prune = Join-Path $root 'scripts/prune_test_sandboxes.ps1'
        $collectorParent = Join-Path $root 'collector/target/test-sandboxes'
        $appParent = Join-Path $root 'app/build/test-sandboxes'
        $outside = Join-Path $root 'outside'
        New-Item -ItemType Directory -Path (Join-Path $root 'scripts/test_support'), $collectorParent, $appParent, $outside -Force | Out-Null
        if (Test-Path -LiteralPath $script:pruneSource) {
            Copy-Item -LiteralPath $script:pruneSource -Destination $prune
        }
        Copy-Item -LiteralPath $script:environmentSource -Destination (Join-Path $root 'scripts/test_support/TestEnvironment.ps1')
        $sentinel = Join-Path $outside 'sentinel.txt'
        Set-Content -LiteralPath $sentinel -Value 'outside sandbox'
    }

    It 'previews all entries, removes an outside-target junction safely and lists a locked sandbox as kept' {
        $withJunction = Join-Path $collectorParent 'r-junction'
        $locked = Join-Path $collectorParent 'r-locked'
        $ordinary = Join-Path $appParent 'dart-[ordinary]'
        New-Item -ItemType Directory -Path $withJunction, $locked, $ordinary | Out-Null
        $junction = Join-Path $withJunction 'Content.IE5'
        New-Item -ItemType Junction -Path $junction -Target $outside | Out-Null
        $lockedJunction = Join-Path $locked 'Content.IE5'
        $evidence = Join-Path $locked 'evidence.txt'
        New-Item -ItemType Junction -Path $lockedJunction -Target $outside | Out-Null
        Set-Content -LiteralPath $evidence -Value 'locked sandbox evidence'
        $openFile = Join-Path $locked 'held.log'
        $handle = [IO.File]::Open($openFile, 'CreateNew', 'ReadWrite', 'None')
        try {
            $preview = (& $script:pwsh -NoProfile -File $prune) -join "`n"
            $LASTEXITCODE | Should -Be 0
            foreach ($entry in @($withJunction, $locked, $ordinary)) {
                $preview.Contains($entry) | Should -BeTrue
                Test-Path -LiteralPath $entry | Should -BeTrue
            }
            $output = (& $script:pwsh -NoProfile -File $prune -Execute) -join "`n"
            $LASTEXITCODE | Should -Be 1
            $output | Should -Match ('Kept: ' + [regex]::Escape($locked))
            Test-Path -LiteralPath $withJunction | Should -BeFalse
            Test-Path -LiteralPath $ordinary | Should -BeFalse
            @(Get-ChildItem -LiteralPath $locked -Force | Sort-Object Name | Select-Object -ExpandProperty Name) | Should -Be @('Content.IE5', 'evidence.txt', 'held.log')
            Get-Content -LiteralPath $evidence | Should -BeExactly 'locked sandbox evidence'
            (Get-Item -LiteralPath $lockedJunction).Target | Should -Be $outside
            Get-Content -LiteralPath $sentinel | Should -BeExactly 'outside sandbox'
            $collectorParent | Should -Exist
            $appParent | Should -Exist
        } finally {
            $handle.Dispose()
            if (Test-Path -LiteralPath $junction) { [IO.Directory]::Delete($junction) }
            if (Test-Path -LiteralPath $lockedJunction) { [IO.Directory]::Delete($lockedJunction) }
        }
    }

    It 'can remove a sandbox when the writer grants delete sharing' {
        # Windows may refuse to rename a parent directory with open descendants
        # even when the file itself permits rename and deletion.
        $openFile = Join-Path $collectorParent 'held.log'
        $handle = [IO.File]::Open($openFile, 'CreateNew', 'ReadWrite', 'ReadWrite,Delete')
        try {
            $output = (& $script:pwsh -NoProfile -File $prune -Execute) -join "`n"
            $LASTEXITCODE | Should -Be 0
            $output | Should -Match ('Removed: ' + [regex]::Escape($openFile))
            $openFile | Should -Not -Exist
            $handle.CanWrite | Should -BeTrue
        } finally {
            $handle.Dispose()
        }
    }

    It 'unlinks direct child links and refuses a linked parent' {
        $junction = Join-Path $collectorParent 'direct-junction'
        New-Item -ItemType Junction -Path $junction -Target $outside | Out-Null
        [IO.Directory]::Delete($appParent)
        New-Item -ItemType Junction -Path $appParent -Target $outside | Out-Null
        try {
            $output = (& $script:pwsh -NoProfile -File $prune -Execute) -join "`n"
            $LASTEXITCODE | Should -Be 1
            $output | Should -Match ('Kept: ' + [regex]::Escape($appParent))
            $junction | Should -Not -Exist
            Get-Content -LiteralPath $sentinel | Should -BeExactly 'outside sandbox'
        } finally {
            if (Test-Path -LiteralPath $appParent) { [IO.Directory]::Delete($appParent) }
            if (Test-Path -LiteralPath $junction) { [IO.Directory]::Delete($junction) }
        }
    }

    It 'rejects a path argument and ignores an environment override' {
        $inside = Join-Path $appParent 'py-owned'
        New-Item -ItemType Directory -Path $inside | Out-Null
        $null = & $script:pwsh -NoProfile -File $prune -Execute -Path $outside 2>&1
        $LASTEXITCODE | Should -Not -Be 0
        $inside | Should -Exist
        $savedParent = $env:CXV_TEST_SANDBOX_PARENT
        try {
            $env:CXV_TEST_SANDBOX_PARENT = $outside
            $null = & $script:pwsh -NoProfile -File $prune -Execute
            $LASTEXITCODE | Should -Be 0
            $inside | Should -Not -Exist
            Get-Content -LiteralPath $sentinel | Should -BeExactly 'outside sandbox'
        } finally {
            $env:CXV_TEST_SANDBOX_PARENT = $savedParent
        }
    }
}
