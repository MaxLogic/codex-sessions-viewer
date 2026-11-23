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
function Initialize-TestSandboxFileApi {
    if ('CxvTest.SandboxFileApi' -as [type]) { return }
    Add-Type -Namespace CxvTest -Name SandboxFileApi -MemberDefinition @'
[DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
private static extern bool CreateDirectoryW(string path, IntPtr security);
[DllImport("libc", SetLastError = true)]
private static extern int mkdir(string path, uint mode);
[DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
private static extern Microsoft.Win32.SafeHandles.SafeFileHandle CreateFileW(string path,
    uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
[DllImport("kernel32.dll", SetLastError = true)]
private static extern bool SetFileInformationByHandle(Microsoft.Win32.SafeHandles.SafeFileHandle handle,
    int infoClass, ref uint info, uint size);

private static string ExtendedPath(string path) {
    if (path.StartsWith(@"\\?\")) return path;
    return path.StartsWith(@"\\") ? @"\\?\UNC\" + path.Substring(2) : @"\\?\" + path;
}

public static int CreateExclusiveDirectory(string path, bool windows) {
    bool created = windows ? CreateDirectoryW(ExtendedPath(path), IntPtr.Zero) : mkdir(path, 448) == 0;
    return created ? 0 : Marshal.GetLastWin32Error();
}

public static void UnlinkReadOnlyFile(string path) {
    // DELETE access, share all, OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT.
    using (var handle = CreateFileW(ExtendedPath(path), 0x10000, 7, IntPtr.Zero, 3, 0x00200000, IntPtr.Zero)) {
        if (handle.IsInvalid) throw new System.ComponentModel.Win32Exception();
        // FileDispositionInfoEx: DELETE | POSIX_SEMANTICS | IGNORE_READONLY_ATTRIBUTE.
        uint flags = 0x1 | 0x2 | 0x10;
        if (!SetFileInformationByHandle(handle, 21, ref flags, 4)) throw new System.ComponentModel.Win32Exception();
    }
}
'@
}

function New-TestRunDirectory {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Caller owns the ShouldProcess decision.')]
    param([string] $LiteralPath)

    $volume = [IO.Path]::GetPathRoot($LiteralPath)
    $LiteralPath = $LiteralPath.TrimEnd('\', '/')
    if ($LiteralPath -eq $volume.TrimEnd('\', '/')) {
        throw "Test sandbox must be a new directory: $LiteralPath"
    }
    Initialize-TestSandboxFileApi
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($LiteralPath)) | Out-Null
    $windows = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
    $code = [CxvTest.SandboxFileApi]::CreateExclusiveDirectory($LiteralPath, $windows)
    $alreadyExists = if ($windows) { $code -in @(80, 183) } else { $code -eq 17 }
    if ($alreadyExists) { throw "Test sandbox must be a new directory: $LiteralPath" }
    if ($code) { throw "Could not create test run directory '$LiteralPath' (OS error $code)." }
}

function Get-TestPathComparisonForm {
    param([string] $Path)
    if ($Path.StartsWith('\\?\UNC\', [StringComparison]::OrdinalIgnoreCase)) { return '\\' + $Path.Substring(8) }
    if ($Path -match '^\\\\\?\\[A-Za-z]:\\') { return $Path.Substring(4) }
    if ($Path.StartsWith('\\?\') -or $Path.StartsWith('\\.\')) { throw "Test profile isolation rejected device path: $Path" }
    return $Path
}

function New-TestEnvironment {
    [CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = 'Parent')]
    param(
        [Parameter(ParameterSetName = 'Parent')][string] $Parent = $env:CXV_TEST_SANDBOX_PARENT,
        [Parameter(Mandatory, ParameterSetName = 'RunRoot')][string] $RunRoot
    )
    if (-not $RunRoot) {
        if (-not $Parent) { $Parent = Join-Path $PSScriptRoot '../../app/build/test-sandboxes' }
        # Leave room for nested profiles, SQLite sidecars and Win32 path limits.
        $id = [guid]::NewGuid().ToString('N').Substring(0, 12)
        $RunRoot = Join-Path $Parent "powershell-$id"
    }
    $keys = @('LOCALAPPDATA', 'APPDATA', 'USERPROFILE', 'HOME', 'XDG_CONFIG_HOME', 'XDG_DATA_HOME', 'XDG_STATE_HOME', 'XDG_CACHE_HOME', 'XDG_RUNTIME_DIR', 'XDG_CONFIG_DIRS', 'XDG_DATA_DIRS', 'CODEX_HOME', 'CLAUDE_CONFIG_DIR', 'CLAUDE_HOME', 'CODEX_SESSIONS_COLLECTOR_QUEUE', 'TEMP', 'TMP', 'TMPDIR')
    $original = @{}
    foreach ($entry in [Environment]::GetEnvironmentVariables('Process').GetEnumerator()) { $original[$entry.Key] = [string]$entry.Value }
    $root = [IO.Path]::GetFullPath((Get-TestPathComparisonForm $RunRoot))
    # Reject reparse traversal rather than guessing a physical destination.
    $context = [pscustomobject]@{ Root = $root; Keys = $keys; Original = $original; Variables = @{}; Endpoints = @{} }
    Assert-TestSystemVariable $context $original
    # Construct from a closed set, never inherit arbitrary tool/profile overrides.
    foreach ($key in @('PATH','SYSTEMROOT','WINDIR','COMSPEC','SYSTEMDRIVE','PATHEXT','PROGRAMFILES','PROGRAMFILES(X86)','PROGRAMW6432','PROGRAMDATA','ALLUSERSPROFILE','COMMONPROGRAMFILES','COMMONPROGRAMFILES(X86)','COMMONPROGRAMW6432','INCLUDE','LIB','LIBPATH','FLUTTER_ROOT','CARGO_HOME','RUSTUP_HOME','PUB_CACHE','CODEX_SESSIONS_COLLECTOR_EXE','CODEX_SESSIONS_HUB_EXE')) {
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
    New-TestRunDirectory $root
    foreach ($key in $keys) { [IO.Directory]::CreateDirectory($context.Variables[$key]) | Out-Null }
    $context.Variables['CXV_TEST_SANDBOX_PARENT'] = Join-Path $root 'children'
    [IO.Directory]::CreateDirectory($context.Variables['CXV_TEST_SANDBOX_PARENT']) | Out-Null
    # Flutter's desktop integration tests enumerate devices before selecting
    # Windows. Disable Android only in the synthetic tool profile.
    $flutterConfigHome = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { 'APPDATA' } else { 'HOME' }
    [IO.File]::WriteAllText((Join-Path $context.Variables[$flutterConfigHome] '.flutter_settings'), '{"enable-android":false}')
    $context | Add-Member -NotePropertyName GetOwnedRoot -NotePropertyValue ({ $root }.GetNewClosure())
    return $context
}

function Complete-TestEnvironment {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    param([Parameter(Mandatory)] $Context, [switch] $Passed)
    $root = & $Context.GetOwnedRoot
    if (-not $Passed) {
        Write-Warning "Retained test sandbox: $root"
        return
    }
    try {
        Assert-TestPath -Context $Context -LiteralPath $root
        if ($PSCmdlet.ShouldProcess($root, 'Remove passing test sandbox')) {
            Invoke-TestSandboxDeletion ([IO.DirectoryInfo]::new($root))
        }
    } catch {
        Write-Warning "Retained test sandbox: $root ($($_.Exception.Message))"
    }
}

function Test-PesterSandboxBlock {
    param([Pester.Block] $Block)

    if ($Block.ErrorRecord.Count -or (-not $Block.IsRoot -and -not $Block.OwnPassed)) { return $false }
    foreach ($test in $Block.Tests) {
        if ($test.ShouldRun -and -not ($test.Executed -and $test.Passed)) { return $false }
    }
    foreach ($child in $Block.Blocks) {
        if ($child.ShouldRun -and -not (Test-PesterSandboxBlock $child)) { return $false }
    }
    return $true
}

function Complete-PesterTestEnvironment {
    param([AllowNull()] $Context, [AllowNull()] $PesterState)

    if (-not $Context) { return }
    # Pester 5 exposes its runtime state in AfterAll. The root aggregate is
    # populated later, but the selected tests and child blocks have finished.
    # Keep the profile if a future Pester version no longer exposes that state.
    $root = if ($PesterState -and $PesterState.PSObject.Properties['CurrentBlock']) { $PesterState.CurrentBlock }
    $passed = $root -is [Pester.Block] -and $root.IsRoot -and (Test-PesterSandboxBlock $root)
    Complete-TestEnvironment -Context $Context -Passed:$passed
}

function Invoke-TestSandboxDeletion {
    param([IO.FileSystemInfo] $Entry)
    $Entry.Refresh()
    if ($Entry -is [IO.DirectoryInfo] -and -not ($Entry.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        foreach ($child in $Entry.EnumerateFileSystemInfos()) {
            Invoke-TestSandboxDeletion $child
        }
    }
    # A nonrecursive call unlinks junctions without enumerating their targets.
    if ($Entry -is [IO.FileInfo] -and ($Entry.Attributes -band [IO.FileAttributes]::ReadOnly) -and
        [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        Initialize-TestSandboxFileApi
        [CxvTest.SandboxFileApi]::UnlinkReadOnlyFile($Entry.FullName)
    } else {
        $Entry.Delete()
    }
}

function Assert-TestPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Context, [Parameter(Mandatory)][AllowEmptyString()][string] $LiteralPath, [string] $WorkingDirectory = $Context.Root)
    if ([string]::IsNullOrWhiteSpace($LiteralPath)) { return }
    $LiteralPath = Get-TestPathComparisonForm $LiteralPath
    $path = if ([IO.Path]::IsPathRooted($LiteralPath)) { [IO.Path]::GetFullPath($LiteralPath) } else { [IO.Path]::GetFullPath((Join-Path $WorkingDirectory $LiteralPath)) }
    $root = $Context.Root.TrimEnd('\', '/')
    if ($path -ne $root -and -not $path.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw "Test profile isolation rejected unowned path: $LiteralPath" }
    foreach ($key in $Context.Keys) {
        $real = $Context.Original[$key]
        if ($real -and [IO.Path]::IsPathRooted($real)) {
            $real = [IO.Path]::GetFullPath((Get-TestPathComparisonForm $real)).TrimEnd('\', '/')
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
    if ($Variables['CXV_TEST_SANDBOX_PARENT']) {
        Assert-TestPath $Context $Variables['CXV_TEST_SANDBOX_PARENT']
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
    # Compare normalized spellings: a PATH entry such as a CI FLUTTER_ROOT can use '/'.
    $resolved = [IO.Path]::GetFullPath($resolved)
    # Rustup's installed cargo proxy is a known tool alias. Resolve that one
    # leaf link explicitly; every parent and every build-output reparse is denied.
    $cargoProxy = [IO.Path]::GetFullPath((Get-Command cargo -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source)
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
        @('collector','hub','scan-launcher') | ForEach-Object { [IO.Path]::GetFullPath((Join-Path $repo "collector/target/$mode/codex-sessions-$_.exe")) }
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
    $python = [IO.Path]::GetFullPath((Get-Command python -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source)
    if ($resolved -eq $python -and $ArgumentList.Count -eq 3 -and $ArgumentList[0] -eq '-I' -and $ArgumentList[1] -eq (Join-Path $PSScriptRoot 'validate_settings.py')) {
        Assert-TestPath $Context $ArgumentList[2] -WorkingDirectory $WorkingDirectory
        return
    }
    # Release invocations plus change-scoped targets. Do not admit arbitrary
    # cargo/Flutter flags: these are existing test files in this checkout only.
    $cargo = [IO.Path]::GetFullPath((Get-Command cargo -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source)
    $flutter = [IO.Path]::GetFullPath((Get-Command flutter -ErrorAction Stop | Select-Object -First 1).Source)
    if ($resolved -eq $cargo -and ($ArgumentList -join '|') -eq 'test|--locked|--no-fail-fast' -and $WorkingDirectory -eq (Join-Path $repo 'collector')) { return }
    if ($resolved -eq $flutter -and ($ArgumentList -join '|') -in @('test','test|integration_test') -and $WorkingDirectory -eq (Join-Path $repo 'app')) { return }
    if ($resolved -eq $cargo -and $WorkingDirectory -eq (Join-Path $repo 'collector')) {
        if (($ArgumentList -join '|') -eq 'test|--locked|--lib') { return }
        if ($ArgumentList.Count -eq 4 -and ($ArgumentList[0..2] -join '|') -eq 'test|--locked|--test' -and $ArgumentList[3] -cmatch '^[a-zA-Z0-9_]+$' -and (Test-Path -LiteralPath (Join-Path $repo ('collector/tests/' + $ArgumentList[3] + '.rs')) -PathType Leaf)) { return }
    }
    if ($resolved -eq $flutter -and $WorkingDirectory -eq (Join-Path $repo 'app') -and $ArgumentList.Count -eq 2 -and $ArgumentList[0] -eq 'test' -and $ArgumentList[1] -cmatch '^(test|integration_test)/[a-zA-Z0-9_/]+_test\.dart$' -and (Test-Path -LiteralPath (Join-Path $repo ('app/' + $ArgumentList[1])) -PathType Leaf)) { return }
    if ($resolved -eq $flutter -and $WorkingDirectory -eq (Join-Path $repo 'app') -and $ArgumentList.Count -ge 3 -and ($ArgumentList[0..1] -join '|') -eq 'test|--machine') {
        $validTargets = $true
        foreach ($target in $ArgumentList[2..($ArgumentList.Count-1)]) {
            if ($target -cnotmatch '^(test|integration_test)/[a-zA-Z0-9_/]+_test\.dart$' -or -not (Test-Path -LiteralPath (Join-Path $repo ('app/' + $target)) -PathType Leaf)) { $validTargets = $false; break }
        }
        if ($validTargets) { return }
    }
    if ($resolved -eq $flutter -and $WorkingDirectory -eq (Join-Path $repo 'app') -and ($ArgumentList -join '|') -eq 'test|test/app/runtime_scan_app_test.dart|--plain-name|pricing commits between background scan batches before scan completion') { return }
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
