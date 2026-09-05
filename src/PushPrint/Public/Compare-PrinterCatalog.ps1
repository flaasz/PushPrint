function Compare-PrinterCatalog {
    <#
    .SYNOPSIS
        Compares an existing catalog with freshly discovered entries and reports Added / Removed / Changed printers.
    .EXAMPLE
        Compare-PrinterCatalog -Reference (Get-PrinterCatalog -Site KUJ) -Difference (Invoke-PrinterDiscovery -Site KUJ)
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Reference,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Difference,
        [string[]] $Property = @('name', 'vendor', 'model', 'serial', 'site', 'shareName', 'queueKind', 'mac')
    )
    $ref = @{}; foreach ($e in $Reference) { if ($e) { $ref[(Get-CatalogKey $e)] = $e } }
    $dif = @{}; foreach ($e in $Difference) { if ($e) { $dif[(Get-CatalogKey $e)] = $e } }
    foreach ($k in $dif.Keys) {
        $n = $dif[$k]
        if (-not $ref.ContainsKey($k)) {
            [pscustomobject]@{ Change = 'Added'; Key = $k; Name = (Get-PropertyValue $n 'name'); IP = (Get-PropertyValue $n 'ip'); Details = "new: $(Get-PropertyValue $n 'name') [$(Get-PropertyValue $n 'vendor') $(Get-PropertyValue $n 'model')]" }
            continue
        }
        $o = $ref[$k]
        $diffs = foreach ($p in $Property) {
            $ov = "$(Get-PropertyValue $o $p)"; $nv = "$(Get-PropertyValue $n $p)"
            if ($nv -and $ov -ne $nv) { "$p : '$ov' -> '$nv'" }
        }
        if ($diffs) { [pscustomobject]@{ Change = 'Changed'; Key = $k; Name = (Get-PropertyValue $n 'name'); IP = (Get-PropertyValue $n 'ip'); Details = ($diffs -join '; ') } }
    }
    foreach ($k in $ref.Keys) {
        if (-not $dif.ContainsKey($k)) {
            $o = $ref[$k]
            [pscustomobject]@{ Change = 'Removed'; Key = $k; Name = (Get-PropertyValue $o 'name'); IP = (Get-PropertyValue $o 'ip'); Details = 'not found by discovery' }
        }
    }
}

function Get-CatalogKey {
    <#
    .SYNOPSIS  Identity of a catalog entry: IP for devices, server\share for pull queues, name as last resort.
    #>
    param([Parameter(Mandatory)] $Entry)
    $ip = Get-PropertyValue $Entry 'ip'
    if ($ip) { return "ip:$ip" }
    $srv = Get-PropertyValue $Entry 'printServer'; $share = Get-PropertyValue $Entry 'shareName'
    if ($srv -and $share) { return "q:$srv\$share" }
    return "n:$(Get-PropertyValue $Entry 'name')"
}
