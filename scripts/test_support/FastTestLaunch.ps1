function Get-FastFlutterTestArgumentList {
    param([Parameter(Mandatory)][string] $Target, $Filters)

    $arguments = @('test')
    if ($Target -ne 'test') { $arguments += $Target }
    $filter = if ($Filters) { $Filters.PSObject.Properties[$Target] } else { $null }
    if ($filter -and [string]$filter.Value) { $arguments += @('--plain-name', [string]$filter.Value) }
    return $arguments
}
