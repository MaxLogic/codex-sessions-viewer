#Requires -Version 7.0
<#
.SYNOPSIS
Preview or remove retained test sandboxes in this checkout.
.DESCRIPTION
Run only in an idle checkout. Do not run while another process modifies the
sandbox parents or their contents. Files opened with delete sharing can be
removed even while a writer still has them open.
#>
[CmdletBinding(SupportsShouldProcess, PositionalBinding = $false)]
param([switch] $Execute)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'test_support/TestEnvironment.ps1')

function Get-PrunableSandboxParent {
    param([string] $Path)

    # Validate from the drive root down so even an ancestor link is refused
    # before descending into it. Missing parents simply have nothing to prune.
    $ancestry = [Collections.Generic.Stack[string]]::new()
    for ($cursor = [IO.Path]::GetFullPath($Path); $cursor; $cursor = [IO.Path]::GetDirectoryName($cursor)) {
        $ancestry.Push($cursor)
    }
    foreach ($ancestor in $ancestry) {
        try {
            $directory = Get-Item -LiteralPath $ancestor -Force
        } catch [Management.Automation.ItemNotFoundException] {
            return
        }
        if ($directory -isnot [IO.DirectoryInfo] -or ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Sandbox parent traverses a link or non-directory at '$ancestor'."
        }
    }
    return $directory
}

$repo = Split-Path -Parent $PSScriptRoot
$leftovers = [Collections.Generic.List[string]]::new()
foreach ($relativeParent in @('collector/target/test-sandboxes', 'app/build/test-sandboxes')) {
    $parent = [IO.Path]::GetFullPath((Join-Path $repo $relativeParent))
    try {
        $directory = Get-PrunableSandboxParent $parent
        if (-not $directory) { continue }
        foreach ($entry in $directory.GetFileSystemInfos()) {
            if (-not $Execute) {
                Write-Output "Would remove: $($entry.FullName)"
                continue
            }
            if ($PSCmdlet.ShouldProcess($entry.FullName, 'Remove test sandbox')) {
                $entryPath = $entry.FullName
                $remainingPath = $entryPath
                try {
                    if (-not (Get-PrunableSandboxParent $parent)) { throw 'Sandbox parent disappeared.' }
                    $staging = Join-Path $parent ('.prune-' + [guid]::NewGuid().ToString('N'))
                    # Rename on the same volume, with no copy/delete fallback.
                    # Windows refuses the directory rename if a descendant
                    # is open without delete sharing.
                    $entry.MoveTo($staging)
                    $remainingPath = $staging
                    Invoke-TestSandboxDeletion $entry
                    Write-Output "Removed: $entryPath"
                } catch {
                    $leftovers.Add("$remainingPath ($($_.Exception.Message))")
                }
            }
        }
    } catch {
        $leftovers.Add("$parent ($($_.Exception.Message))")
    }
}
foreach ($leftover in $leftovers) { Write-Output "Kept: $leftover" }
exit [int]($leftovers.Count -gt 0)
