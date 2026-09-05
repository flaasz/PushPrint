function Get-PrinterCatalog {
    <#
    .SYNOPSIS
        Reads the printer catalog (JSON). Understands the v2 envelope { version, generated, printers[] } and the
        legacy v1 plain array [{ name, ip, vendor, location, note }].
    .PARAMETER Path
        Catalog file. Default: catalogPath from settings.json.
    .EXAMPLE
        Get-PrinterCatalog -Site KUJ -Search 'HR'
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string] $Path,
        [string[]] $Site,
        [string] $Search,
        [string] $Vendor,
        [string] $ConfigPath
    )
    if (-not $Path) {
        $cfg = if ($ConfigPath) { Get-PushPrintConfig -Path $ConfigPath } else { Get-PushPrintConfig }
        $Path = $cfg.catalogPath
    }
    if (-not (Test-Path -LiteralPath $Path)) { Write-Verbose "Catalog not found at $Path"; return }
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) { return }
    $json = ConvertFrom-Json $raw
    $items = if ($json -is [array]) { $json } elseif ($json.PSObject.Properties['printers']) { @($json.printers) } else { @($json) }
    $out = foreach ($i in $items) {
        if (-not $i) { continue }
        $e = [ordered]@{}
        foreach ($k in 'name', 'ip', 'mac', 'vendor', 'model', 'serial', 'site', 'location', 'printServer', 'shareName', 'queueKind', 'hostName', 'snmpName', 'dhcpName', 'sources', 'flags', 'note', 'lastSeen') {
            $p = $i.PSObject.Properties[$k]
            $e[$k] = if ($p) { $p.Value } else { $null }
        }
        # v1 compatibility: "location" was the site code
        if (-not $e.site -and $e.location -and -not $i.PSObject.Properties['site']) { $e.site = $e.location; $e.location = $null }
        if ($null -eq $e.sources) { $e.sources = @() }
        if ($null -eq $e.flags) { $e.flags = @() }
        [pscustomobject]$e
    }
    if ($Site)   { $out = $out | Where-Object { $s = $_.site; @($Site | Where-Object { "$s" -like $_ }).Count -gt 0 } }
    if ($Vendor) { $out = $out | Where-Object { $_.vendor -ieq $Vendor } }
    if ($Search) { $out = $out | Where-Object { "$($_.name) $($_.ip) $($_.model) $($_.serial) $($_.location) $($_.shareName) $($_.hostName)" -like "*$Search*" } }
    $out
}
