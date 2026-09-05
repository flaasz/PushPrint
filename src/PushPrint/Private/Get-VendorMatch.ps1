function ConvertTo-NormalizedMac {
    <#
    .SYNOPSIS  "00-20-6b-aa-bb-cc" / "00:20:6B:..." / "00206baabbcc" -> "00206BAABBCC"; $null when not a MAC.
    #>
    param([AllowNull()] [string] $Mac)
    if ([string]::IsNullOrWhiteSpace($Mac)) { return $null }
    $clean = ($Mac -replace '[^0-9A-Fa-f]', '').ToUpperInvariant()
    if ($clean.Length -ne 12) { return $null }
    return $clean
}

function Get-VendorMatch {
    <#
    .SYNOPSIS
        Resolves a vendor key from the configured driver table using, in priority order,
        SNMP description text (sysDescr / hrDeviceDescr) and MAC OUI prefix.
    .OUTPUTS  Vendor key (e.g. 'KM') or $null.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Drivers,
        [string] $Description,
        [string] $Mac
    )
    if ($Description) {
        foreach ($key in $Drivers.Keys) {
            $pattern = $Drivers[$key]['matchPattern']
            if ($pattern -and $Description -match $pattern) { return $key }
        }
    }
    $norm = ConvertTo-NormalizedMac $Mac
    if ($norm) {
        $oui = $norm.Substring(0, 6)
        foreach ($key in $Drivers.Keys) {
            $prefixes = $Drivers[$key]['macPrefixes']
            if ($prefixes -and ($prefixes | ForEach-Object { ($_ -replace '[^0-9A-Fa-f]', '').ToUpperInvariant() }) -contains $oui) { return $key }
        }
    }
    return $null
}
