# Shared, fail-closed environment for PowerShell test/native harnesses.
$script:TestSystemKeys = @('SYSTEMROOT','WINDIR','COMSPEC','SYSTEMDRIVE','PATHEXT','PROGRAMFILES','PROGRAMFILES(X86)','PROGRAMW6432','PROGRAMDATA','ALLUSERSPROFILE','COMMONPROGRAMFILES','COMMONPROGRAMFILES(X86)','COMMONPROGRAMW6432')
$script:TestSystemValues = @{}
foreach ($systemKey in $script:TestSystemKeys) { $script:TestSystemValues[$systemKey] = [Environment]::GetEnvironmentVariable($systemKey, 'Process') }

function Assert-TestSystemVariable {
    [CmdletBinding()]
    param($Context, [hashtable] $Variables)
    foreach ($key in $script:TestSystemKeys) {
        $value = $Variables[$key]
        if (-not $value) { continue }
        $machine = [Environment]::GetEnvironmentVariable($key, 'Machine')
        if ($machine) { $machine = [Environment]::ExpandEnvironmentVariables($machine) }
        # Shells legitimately extend the executable-extension list; it is a
        # scalar checked against this host's original list, not a location.
        if ($key -eq 'PATHEXT') { $machine = $null }
        if ($value -ne $script:TestSystemValues[$key] -or ($machine -and $value -ne $machine)) { throw "Test isolation rejected system variable: $key" }
        if ($key -eq 'PATHEXT') {
            if ($value -notmatch '^\.[A-Za-z0-9]+(;\.[A-Za-z0-9]+)*$') { throw 'Test isolation rejected system PATHEXT' }
            continue
        }
        if ($key -eq 'SYSTEMDRIVE' -and $value -match '^[A-Za-z]:$') { $value += '\' }
        if (-not [IO.Path]::IsPathRooted($value)) { throw "Test isolation rejected relative system variable: $key" }
        $path = [IO.Path]::GetFullPath($value).TrimEnd('\','/')
        $profiles = @($Context.Keys | ForEach-Object { $Context.Original[$_] })
        $homePath = [Environment]::GetFolderPath('UserProfile')
        if ($homePath) { $profiles += [IO.Path]::GetDirectoryName($homePath) }
        foreach ($profileRoot in $profiles) {
            if (-not $profileRoot -or -not [IO.Path]::IsPathRooted($profileRoot)) { continue }
            $profileRoot = [IO.Path]::GetFullPath($profileRoot).TrimEnd('\','/')
            if ($path -eq $profileRoot -or $path.StartsWith($profileRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw "Test isolation rejected profile system variable: $key" }
        }
        $cursor = $path
        while ($cursor) {
            if ((Test-Path -LiteralPath $cursor) -and ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Test isolation rejected system reparse point: $key" }
            $cursor = [IO.Path]::GetDirectoryName($cursor)
        }
    }
}

function Register-TestEndpoint {
    [CmdletBinding()]
    param($Context, [string]$Url)
    $origin = Assert-TestEndpoint -Context $Context -Url $Url -Register
    $Context.Endpoints[$origin] = $true
}
function Assert-TestEndpoint {
    [CmdletBinding()]
    param($Context, [string]$Url, [switch]$Register)
    $uri = $null
    $ip = $null
    if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -notin @('http','https') -or -not [Net.IPAddress]::TryParse($uri.DnsSafeHost, [ref]$ip) -or -not [Net.IPAddress]::IsLoopback($ip) -or $uri.Port -le 0) { throw 'Test isolation rejected network endpoint' }
    $origin = $uri.GetLeftPart([UriPartial]::Authority)
    if ($Register) { return $origin }
    if (-not $Context.Endpoints.ContainsKey($origin)) { throw 'Test isolation rejected unowned network endpoint' }
}
function New-TestEnvironment {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string] $Parent = $env:CXV_TEST_SANDBOX_PARENT)
    if (-not $Parent) { $Parent = Join-Path $PSScriptRoot '../../app/build/test-sandboxes' }
    $keys = @('LOCALAPPDATA', 'APPDATA', 'USERPROFILE', 'HOME', 'XDG_CONFIG_HOME', 'XDG_DATA_HOME', 'XDG_STATE_HOME', 'XDG_CACHE_HOME', 'XDG_RUNTIME_DIR', 'XDG_CONFIG_DIRS', 'XDG_DATA_DIRS', 'CODEX_HOME', 'CLAUDE_CONFIG_DIR', 'CLAUDE_HOME', 'CODEX_SESSIONS_COLLECTOR_QUEUE', 'TEMP', 'TMP', 'TMPDIR')
    $original = @{}
    foreach ($entry in [Environment]::GetEnvironmentVariables('Process').GetEnumerator()) { $original[$entry.Key] = [string]$entry.Value }
    $root = [IO.Path]::GetFullPath((Join-Path $Parent ('powershell-' + [guid]::NewGuid().ToString('N'))))
    # Reject reparse traversal rather than guessing a physical destination.
    $context = [pscustomobject]@{ Root = $root; Keys = $keys; Original = $original; Variables = @{}; Endpoints = @{} }
    Assert-TestSystemVariable $context $original
    # Construct from a closed set, never inherit arbitrary tool/profile overrides.
    foreach ($key in @('PATH','SYSTEMROOT','WINDIR','COMSPEC','SYSTEMDRIVE','PATHEXT','PROGRAMFILES','PROGRAMFILES(X86)','PROGRAMW6432','PROGRAMDATA','ALLUSERSPROFILE','COMMONPROGRAMFILES','COMMONPROGRAMFILES(X86)','COMMONPROGRAMW6432','INCLUDE','LIB','LIBPATH','FLUTTER_ROOT','CARGO_HOME','RUSTUP_HOME','PUB_CACHE','CODEX_SESSIONS_COLLECTOR_EXE','CODEX_SESSIONS_HUB_EXE','CXV_TEST_SANDBOX_PARENT')) {
        if ($original.ContainsKey($key)) { $context.Variables[$key] = $original[$key] }
    }
    foreach ($key in $keys) { $context.Variables[$key] = Join-Path $root $key }
    $context.Variables['HOME'] = $context.Variables['USERPROFILE']
    # Keep tool installations as read-only inputs after changing the home.
    foreach ($pair in @(@('CARGO_HOME', '.cargo'), @('RUSTUP_HOME', '.rustup'))) {
        if (-not $context.Variables.ContainsKey($pair[0]) -and $original['USERPROFILE']) { $context.Variables[$pair[0]] = Join-Path $original['USERPROFILE'] $pair[1] }
    }
    if (-not $context.Variables['PUB_CACHE'] -and $original['LOCALAPPDATA']) { $context.Variables['PUB_CACHE'] = Join-Path $original['LOCALAPPDATA'] 'Pub/Cache' }
    Assert-TestPath -Context $context -LiteralPath $root
    if (-not $PSCmdlet.ShouldProcess($root, 'Allocate isolated test profile')) { return }
    [IO.Directory]::CreateDirectory($root) | Out-Null
    foreach ($key in $keys) { [IO.Directory]::CreateDirectory($context.Variables[$key]) | Out-Null }
    return $context
}

function Assert-TestPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Context, [Parameter(Mandatory)][AllowEmptyString()][string] $LiteralPath, [string] $WorkingDirectory = $Context.Root)
    if ([string]::IsNullOrWhiteSpace($LiteralPath)) { return }
    $path = if ([IO.Path]::IsPathRooted($LiteralPath)) { [IO.Path]::GetFullPath($LiteralPath) } else { [IO.Path]::GetFullPath((Join-Path $WorkingDirectory $LiteralPath)) }
    $root = $Context.Root.TrimEnd('\', '/')
    if ($path -ne $root -and -not $path.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw "Test profile isolation rejected unowned path: $LiteralPath" }
    foreach ($key in $Context.Keys) {
        $real = $Context.Original[$key]
        if ($real -and [IO.Path]::IsPathRooted($real)) {
            $real = [IO.Path]::GetFullPath($real).TrimEnd('\', '/')
            if ($path -eq $real -or $path.StartsWith($real + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw "Test profile isolation rejected inherited profile: $LiteralPath" }
        }
    }
    $cursor = $path
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            if ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Test profile isolation rejected reparse path: $LiteralPath" }
        }
        $parentPath = [IO.Path]::GetDirectoryName($cursor)
        if ($parentPath -eq $cursor) { break }
        $cursor = $parentPath
    }
}

function Assert-TestEnvironment {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Context, [hashtable] $Variables = $Context.Variables)
    Assert-TestSystemVariable $Context $Variables
    foreach ($key in $Variables.Keys) {
        if (-not $Context.Variables.ContainsKey($key) -and $key -notin @('CODEX_SESSIONS_COLLECTOR_BUSY_TIMEOUT_MS','CODEX_SESSIONS_COLLECTOR_TIMINGS')) { throw "Test profile isolation rejected environment key: $key" }
        if ($key -notin $Context.Keys -and $Context.Variables.ContainsKey($key) -and $Variables[$key] -ne $Context.Variables[$key]) { throw "Test profile isolation rejected tool override: $key" }
    }
    foreach ($key in $Context.Keys) {
        if (-not $Variables[$key] -or -not [IO.Path]::IsPathRooted($Variables[$key])) { throw "Test profile isolation requires $key" }
        Assert-TestPath $Context $Variables[$key]
    }
    foreach ($key in $Variables.Keys) {
        if ($key -like 'CODEX_SESSIONS_COLLECTOR_*' -and $key -notin @('CODEX_SESSIONS_COLLECTOR_EXE', 'CODEX_SESSIONS_COLLECTOR_BUSY_TIMEOUT_MS', 'CODEX_SESSIONS_COLLECTOR_TIMINGS')) { Assert-TestPath $Context $Variables[$key] }
    }
}

function Invoke-TestEnvironment {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Context, [Parameter(Mandatory)][scriptblock] $Body)
    Assert-TestEnvironment $Context
    $saved = [Environment]::GetEnvironmentVariables('Process')
    try {
        # PowerShell coerces $null to an empty string for this .NET string
        # parameter. NullString passes a real null so excluded keys are absent.
        foreach ($key in @([Environment]::GetEnvironmentVariables('Process').Keys)) { [Environment]::SetEnvironmentVariable($key, [NullString]::Value, 'Process') }
        foreach ($key in $Context.Variables.Keys) { [Environment]::SetEnvironmentVariable($key, $Context.Variables[$key], 'Process') }
        & $Body
    } finally {
        foreach ($key in @([Environment]::GetEnvironmentVariables('Process').Keys)) { [Environment]::SetEnvironmentVariable($key, [NullString]::Value, 'Process') }
        foreach ($key in $saved.Keys) { [Environment]::SetEnvironmentVariable($key, $saved[$key], 'Process') }
    }
}

function Assert-TestSettingsFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Context, [Parameter(Mandatory)][string] $LiteralPath, [string] $WorkingDirectory = $Context.Root)
    Assert-TestPath -Context $Context -LiteralPath $LiteralPath -WorkingDirectory $WorkingDirectory
    $resolved = if ([IO.Path]::IsPathRooted($LiteralPath)) { $LiteralPath } else { Join-Path $WorkingDirectory $LiteralPath }
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) { return }
    $python = (Get-Command python -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $parsed = Invoke-TestProcess -Context $Context -FilePath $python -ArgumentList @('-I', (Join-Path $PSScriptRoot 'validate_settings.py'), $resolved)
    if ($LASTEXITCODE -ne 0) { throw 'Test profile isolation cannot fully parse settings TOML' }
    $settings = $parsed | ConvertFrom-Json
    foreach ($value in $settings.paths) {
        Assert-TestPath -Context $Context -LiteralPath $value -WorkingDirectory $WorkingDirectory
    }
    foreach ($value in $settings.endpoints) { Assert-TestEndpoint $Context $value }
}

function Assert-TestLaunch {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Context, [Parameter(Mandatory)][string] $FilePath, [string[]] $ArgumentList = @(), [hashtable] $Environment = @{}, [string] $WorkingDirectory = $Context.Root)
    $variables = @{} + $Context.Variables
    foreach ($key in $Environment.Keys) { $variables[$key] = $Environment[$key] }
    Assert-TestEnvironment $Context $variables
    $flags = @('--db', '--standalone', '--settings', '--root', '--input', '--claude-wsl-root', '--windows-root', '--wsl-root', '--wsl-unc-root', '--claude-root', '--queue', '--log', '--output', '--config', '--data-dir', '--work', '--result')
    for ($i = 0; $i -lt $ArgumentList.Count; $i++) {
        $parts = $ArgumentList[$i] -split '=', 2
        if ($parts[0] -eq '--bind') {
            $bind = if ($parts.Count -eq 2) { $parts[1] } else { $ArgumentList[$i+1] }
            if ($bind -notmatch '^(127\.0\.0\.1|\[::1\]):[0-9]{1,5}$') { throw 'Test isolation rejected network bind endpoint' }
        }
        if ($parts[0] -in @('--hub-url','--hub')) {
            $endpoint = if ($parts.Count -eq 2) { $parts[1] } else { $ArgumentList[$i+1] }
            Assert-TestEndpoint $Context $endpoint
        }
        if ($parts[0] -in $flags) {
            $value = if ($parts.Count -eq 2) { $parts[1] } else { $i++; $ArgumentList[$i] }
            Assert-TestPath -Context $Context -LiteralPath $value -WorkingDirectory $WorkingDirectory
            if ($parts[0] -eq '--settings') { Assert-TestSettingsFile -Context $Context -LiteralPath $value -WorkingDirectory $WorkingDirectory }
        }
    }
    if ($ArgumentList.Count -ge 2 -and $ArgumentList[0] -in @('codex', 'claude') -and $ArgumentList[1] -in @('ingest','parse')) {
        $switches = @('--no-drain', '--no-wait', '--no-wsl-projects', '--force', '--json', '--progress-json', '--cancel-stdin')
        for ($i = 2; $i -lt $ArgumentList.Count; $i++) {
            $arg = $ArgumentList[$i]
            if ($arg.StartsWith('--')) {
                if (-not $arg.Contains('=') -and $arg -notin $switches) { $i++ }
            } else { Assert-TestPath -Context $Context -LiteralPath $arg -WorkingDirectory $WorkingDirectory }
        }
    }
    if ([IO.Path]::GetFileName($FilePath) -like 'codex-sessions-*') {
        Assert-TestPath $Context $WorkingDirectory
        $adjacent = Join-Path ([IO.Path]::GetDirectoryName($FilePath)) 'settings.toml'
        if (-not ($ArgumentList -match '^--settings(?:=|$)')) {
            $settings = if (Test-Path -LiteralPath $adjacent) { $adjacent } else { Join-Path $variables['APPDATA'] 'CodexSessionViewer/settings.toml' }
            Assert-TestSettingsFile -Context $Context -LiteralPath $settings -WorkingDirectory $WorkingDirectory
        }
        foreach ($path in @((Join-Path $variables['LOCALAPPDATA'] 'CodexSessionViewer/collector/resident.log'),
            (Join-Path $variables['LOCALAPPDATA'] 'CodexSessionViewer/collector/resident.log.1'),
            (Join-Path $variables['LOCALAPPDATA'] 'CodexSessionViewer/run'),
            (Join-Path $variables['APPDATA'] 'CodexSessionViewer/codex_sessions_viewer.sqlite'),
            (Join-Path $variables['APPDATA'] 'CodexSessionViewer/backups'),
            (Join-Path $variables['USERPROFILE'] '.claude/projects'),
            (Join-Path $variables['CODEX_HOME'] 'config.toml'),
            (Join-Path $variables['CLAUDE_CONFIG_DIR'] 'settings.json'), (Join-Path $WorkingDirectory 'logs'))) {
            Assert-TestPath -Context $Context -LiteralPath $path
        }
    }
    # A normal packaged viewer can edit HKCU/Task Scheduler during startup.
    # Profile environment redirection cannot isolate those native stores.
    if ([IO.Path]::GetFileName($FilePath) -match '^codex_sessions?_viewer(?:\.exe)?$' -and '--benchmark-scan-memory' -notin $ArgumentList) {
        throw 'Test profile isolation refuses normal packaged-viewer startup: use the headless Flutter harness, which guards Registry and Task Scheduler.'
    }
    Assert-TestExecutable -Context $Context -FilePath $FilePath -ArgumentList $ArgumentList -WorkingDirectory $WorkingDirectory
    return $variables
}

function Assert-TestExecutable {
    [CmdletBinding()]
    param($Context, [string]$FilePath, [string[]]$ArgumentList, [string]$WorkingDirectory)
    $repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    $resolved = (Get-Command $FilePath -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    if (-not $resolved -and (Test-Path -LiteralPath $FilePath -PathType Leaf)) { $resolved = [IO.Path]::GetFullPath($FilePath) }
    if (-not $resolved) { throw "Test profile isolation rejected unknown executable: $FilePath" }
    # Rustup's installed cargo proxy is a known tool alias. Resolve that one
    # leaf link explicitly; every parent and every build-output reparse is denied.
    $cargoProxy = (Get-Command cargo -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $cursor = $resolved
    if ($resolved -eq $cargoProxy) {
        $item = Get-Item -LiteralPath $resolved -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            if (@($item.Target).Count -ne 1 -or $item.Target -ne 'rustup.exe') { throw 'Test profile isolation rejected unknown cargo proxy target' }
            $cursor = Join-Path ([IO.Path]::GetDirectoryName($resolved)) 'rustup.exe'
        }
    }
    # Refuse every other reparse component, including links within build outputs.
    while ($cursor) {
        if ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Test profile isolation rejected executable reparse path' }
        $cursor = [IO.Path]::GetDirectoryName($cursor)
    }
    $native = @('debug','release') | ForEach-Object {
        $mode = $_
        @('collector','hub','scan-launcher') | ForEach-Object { Join-Path $repo "collector/target/$mode/codex-sessions-$_.exe" }
    }
    if ($resolved -in $native) {
        if ([IO.Path]::GetFileName($resolved) -eq 'codex-sessions-hub.exe') {
            if ($ArgumentList.Count -ne 3 -or $ArgumentList[0] -notmatch '^127\.0\.0\.1:[0-9]{1,5}$') { throw 'Test profile isolation invalid fixture hub arguments' }
            Assert-TestPath $Context $ArgumentList[1] -WorkingDirectory $WorkingDirectory
            Assert-TestPath $Context $ArgumentList[2] -WorkingDirectory $WorkingDirectory
            return
        }
        if ([IO.Path]::GetFileName($resolved) -eq 'codex-sessions-collector.exe' -and ($ArgumentList.Count -eq 0 -or $ArgumentList[0] -notin @('codex','claude','query','hub','resident','serve','client','drain','apply','version','--help'))) { throw 'Test profile isolation unlisted collector command' }
        $allowed = @('--db','--standalone','--settings','--root','--input','--claude-wsl-root','--windows-root','--wsl-root','--wsl-unc-root','--claude-root','--queue','--log','--output','--config','--data-dir','--work','--result','--lifetime','--parser-workers','--flush-sessions','--flush-bytes','--hub-url','--bind')
        $switches = @('--no-drain','--no-wait','--no-wsl-projects','--force','--json','--progress-json','--cancel-stdin','--help','--apply','--remove','--local-proof','--check-hub')
        for ($i=0; $i -lt $ArgumentList.Count; $i++) {
            $flag = ($ArgumentList[$i] -split '=',2)[0]
            if (-not $flag.StartsWith('--') -or $flag -in $switches) { continue }
            if ($flag -notin $allowed) { throw "Test profile isolation rejected option: $flag" }
            if (-not $ArgumentList[$i].Contains('=') -and ++$i -ge $ArgumentList.Count) { throw 'Test profile isolation missing argument' }
        }
        return
    }
    $python = (Get-Command python -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    if ($resolved -eq $python -and $ArgumentList.Count -eq 3 -and $ArgumentList[0] -eq '-I' -and $ArgumentList[1] -eq (Join-Path $PSScriptRoot 'validate_settings.py')) {
        Assert-TestPath $Context $ArgumentList[2] -WorkingDirectory $WorkingDirectory
        return
    }
    # The build orchestrator has exactly two permitted test invocations.
    $cargo = (Get-Command cargo -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $flutter = (Get-Command flutter -ErrorAction Stop | Select-Object -First 1).Source
    if ($resolved -eq $cargo -and ($ArgumentList -join '|') -eq 'test|--locked|--no-fail-fast' -and $WorkingDirectory -eq (Join-Path $repo 'collector')) { return }
    if ($resolved -eq $flutter -and ($ArgumentList -join '|') -in @('test','test|integration_test') -and $WorkingDirectory -eq (Join-Path $repo 'app')) { return }
    if ($resolved -eq $env:ComSpec -and ($ArgumentList -join '|') -eq '/d|/c|exit 7') { return }
    $knownHosts = @((Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'), 'C:\Program Files\PowerShell\7\pwsh.exe')
    if ($resolved -in $knownHosts -and $ArgumentList.Count -in @(9,11) -and ($ArgumentList[0..7] -join '|') -eq ('-NoProfile|-ExecutionPolicy|Bypass|-File|' + (Join-Path $repo 'scripts/benchmark_scan_memory.ps1') + '|-Mode|InternalSelfTestChild|-ChildExitCode') -and $ArgumentList[8] -match '^[0-9]{1,3}$') {
        # Exact self-test child, which only allocates memory and exits.
        if ($ArgumentList.Count -eq 9 -or ($ArgumentList.Count -eq 11 -and $ArgumentList[9] -eq '-ChildAllocationMb' -and $ArgumentList[10] -match '^[0-9]{1,4}$')) { return }
    }
    throw "Test profile isolation rejected executable/arguments: $FilePath"
}

function Invoke-TestProcess {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Context, [Parameter(Mandatory)][string] $FilePath, [string[]] $ArgumentList = @(), [hashtable] $Environment = @{}, [string] $WorkingDirectory = $Context.Root)
    $variables = Assert-TestLaunch -Context $Context -FilePath $FilePath -ArgumentList $ArgumentList -Environment $Environment -WorkingDirectory $WorkingDirectory
    $childContext = [pscustomobject]@{ Root=$Context.Root; Keys=$Context.Keys; Original=$Context.Original; Variables=$variables }
    Invoke-TestEnvironment -Context $childContext -Body {
        Push-Location -LiteralPath $WorkingDirectory
        try { & $FilePath @ArgumentList } finally { Pop-Location }
    }
}

function Start-TestProcess {
    [OutputType([Diagnostics.Process])]
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter(Mandatory)] $Context, [Parameter(Mandatory)][string] $FilePath, [string[]] $ArgumentList = @(), [hashtable] $Environment = @{}, [string] $WorkingDirectory = $Context.Root, [switch] $RedirectOutput)
    Assert-TestPath -Context $Context -LiteralPath $WorkingDirectory
    $variables = Assert-TestLaunch -Context $Context -FilePath $FilePath -ArgumentList $ArgumentList -Environment $Environment -WorkingDirectory $WorkingDirectory
    if (-not $PSCmdlet.ShouldProcess($FilePath, 'Start isolated test child')) { return }
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $FilePath
    $info.Arguments = (($ArgumentList | ForEach-Object { '"' + [regex]::Replace([regex]::Replace($_, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1') + '"' }) -join ' ')
    $info.WorkingDirectory = $WorkingDirectory
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    $info.RedirectStandardOutput = $RedirectOutput
    $info.RedirectStandardError = $RedirectOutput
    $info.EnvironmentVariables.Clear()
    foreach ($key in $variables.Keys) { $info.EnvironmentVariables[$key] = $variables[$key] }
    return [Diagnostics.Process]::Start($info)
}
