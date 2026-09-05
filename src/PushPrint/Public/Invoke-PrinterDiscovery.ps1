function Invoke-PrinterDiscovery {
    <#
    .SYNOPSIS
        Builds a verified printer catalog for one or more AD sites by combining three sources and reconciling them by IP:
          SNMP scan of the site's subnets (what the device says about itself: model, serial, name, MAC)
          DHCP leases/reservations filtered by printer MAC vendors (fast confirmation, host names)
          Print server queues (what users see: share names; Direct vs Pull classification)
    .DESCRIPTION
        Output objects use the catalog schema (see Get-PrinterCatalog). Flags highlight what needs a human:
          name-mismatch   queue/DNS name differs from the printer's own SNMP name
          duplicate-ip    several print server queues point at the same IP
          pull-queue      the queue goes through a pull-print server (SafeQ etc.), not straight to the device
          no-snmp         seen in DHCP or on a print server but not answering SNMP (off, or SNMP disabled)
          unknown-vendor  no configured driver matches
    .PARAMETER Site
        AD sites to discover. Use -All for every site with subnets.
    .PARAMETER Subnet
        Explicit CIDR ranges instead of sites.
    .PARAMETER Source
        Which sources to use. Default: all that are available (DHCP is skipped when the RSAT module is missing).
    .EXAMPLE
        Invoke-PrinterDiscovery -Site KUJ | Save-PrinterCatalog -Merge
    .EXAMPLE
        Invoke-PrinterDiscovery -Subnet 10.16.17.0/24 -Source Snmp | Format-Table name, ip, model, serial, flags
    #>
    [CmdletBinding(DefaultParameterSetName = 'Site')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(ParameterSetName = 'Site', Position = 0)] [string[]] $Site,
        [Parameter(ParameterSetName = 'All')] [switch] $All,
        [Parameter(Mandatory, ParameterSetName = 'Subnet')] [string[]] $Subnet,
        [ValidateSet('Snmp', 'Dhcp', 'PrintServer')] [string[]] $Source = @('Snmp', 'Dhcp', 'PrintServer'),
        [string[]] $PrintServer,
        [string[]] $DhcpServer,
        [switch] $NoProbe,
        [string] $ConfigPath
    )
    $cfg = if ($ConfigPath) { Get-PushPrintConfig -Path $ConfigPath } else { Get-PushPrintConfig }
    $cp = @{}; if ($ConfigPath) { $cp.ConfigPath = $ConfigPath }

    # --- zones ---
    $subnetTable = @()
    $ranges = @()
    switch ($PSCmdlet.ParameterSetName) {
        'Subnet' { $ranges = $Subnet; try { $subnetTable = @(Get-AdSiteSubnet @cp -ErrorAction Stop) } catch { $subnetTable = @() } }
        default {
            $subnetTable = @(Get-AdSiteSubnet @cp -ErrorAction Stop)
            $selected = if ($All) { $subnetTable } else {
                if (-not $Site) { throw 'Specify -Site, -All or -Subnet.' }
                $subnetTable | Where-Object { $s = $_.Site; @($Site | Where-Object { $s -like $_ }).Count -gt 0 }
            }
            if (-not $selected) { throw "No subnets found for site(s): $($Site -join ', ')" }
            $ranges = @($selected.Subnet | Sort-Object -Unique)
        }
    }
    Write-PmLog -Level STEP "Discovery over $($ranges.Count) subnet(s): $($ranges -join ', ')"
    $inZone = { param($ip) if (-not $ranges) { return $true }; foreach ($r in $ranges) { if (Test-IPInSubnet -Cidr $r -IPAddress $ip) { return $true } }; return $false }

    # --- collect ---
    $entries = @{}    # ip -> ordered entry
    $newEntry = {
        param($ip)
        [ordered]@{
            name = $null; ip = $ip; mac = $null; vendor = $null; model = $null; serial = $null; site = $null; location = $null
            printServer = $null; shareName = $null; queueKind = $null; hostName = $null; snmpName = $null; dhcpName = $null
            sources = @(); flags = @(); note = $null; lastSeen = (Get-Date).ToString('s')
        }
    }
    $get = { param($ip) if (-not $entries.ContainsKey($ip)) { $entries[$ip] = & $newEntry $ip }; $entries[$ip] }

    if ($Source -contains 'Snmp') {
        $snmp = @(Find-SnmpPrinter -Subnet $ranges @cp)
        Write-PmLog "SNMP: $($snmp.Count) device(s)"
        foreach ($d in $snmp) {
            $e = & $get $d.IPAddress
            $e.sources += 'snmp'
            $e.snmpName = if ($d.SysName) { $d.SysName } else { $d.PrinterName }
            $e.model = $d.Model; $e.serial = $d.SerialNumber; $e.mac = $d.MacAddress
            if ($d.Location) { $e.location = $d.Location }
            if ($d.Vendor) { $e.vendor = $d.Vendor }
            if (-not $d.Reachable) { $e.flags += 'no-snmp' }
        }
    }
    if ($Source -contains 'Dhcp') {
        if (Get-Module -ListAvailable DhcpServer) {
            $dhcpArgs = @{ Subnet = $ranges } + $cp
            if ($DhcpServer) { $dhcpArgs.DhcpServer = $DhcpServer }
            $dhcp = @(Find-DhcpPrinter @dhcpArgs -ErrorAction Continue)
            Write-PmLog "DHCP: $($dhcp.Count) printer-vendor lease(s)/reservation(s)"
            foreach ($d in $dhcp) {
                $e = & $get $d.IPAddress
                $e.sources += 'dhcp'
                if (-not $e.mac) { $e.mac = $d.MacAddress }
                if ($d.HostName) { $e.dhcpName = ($d.HostName -split '\.')[0] }
                if (-not $e.vendor) { $e.vendor = $d.Vendor }
            }
        }
        else { Write-PmLog -Level WARN 'DHCP source skipped: DhcpServer RSAT module not installed' }
    }
    if ($Source -contains 'PrintServer') {
        $psArgs = @{ Probe = (-not $NoProbe) } + $cp
        if ($PrintServer) { $psArgs.PrintServer = $PrintServer }
        $queues = @()
        if ($PrintServer -or $cfg.printServers.Count -gt 0) { $queues = @(Get-PrintServerQueue @psArgs -ErrorAction Continue) }
        else { Write-PmLog -Level WARN 'Print server source skipped: no printServers configured' }
        $queues = @($queues | Where-Object { $_.HostAddress })
        Write-PmLog "Print servers: $($queues.Count) queue(s) with a TCP/IP port"
        $byIp = @{}
        foreach ($q in $queues) {
            $ip = Resolve-IPv4Address $q.HostAddress
            if (-not $ip) { continue }
            if ($q.Kind -eq 'Pull') {
                # Pull queues do not identify a printer; keep them as their own entry keyed by server so users can pick them.
                $e = & $get "$($q.PrintServer)\$($q.ShareName)"
                $e.ip = $null; $e.name = $q.ShareName; $e.printServer = $q.PrintServer; $e.shareName = $q.ShareName
                $e.queueKind = 'Pull'; $e.sources += 'printserver'; $e.flags += 'pull-queue'; $e.note = $q.KindReason
                if ($q.Location) { $e.location = $q.Location }
                continue
            }
            if (-not (& $inZone $ip)) { continue }
            if (-not $byIp.ContainsKey($ip)) { $byIp[$ip] = New-Object System.Collections.Generic.List[object] }
            $byIp[$ip].Add($q)
        }
        foreach ($ip in $byIp.Keys) {
            $qs = $byIp[$ip]
            $e = & $get $ip
            $e.sources += 'printserver'
            $q = $qs | Sort-Object { -not $_.Published }, ShareName | Select-Object -First 1
            $e.printServer = $q.PrintServer; $e.shareName = $q.ShareName; $e.queueKind = $q.Kind
            if ($q.Location -and -not $e.location) { $e.location = $q.Location }
            if ($qs.Count -gt 1) { $e.flags += 'duplicate-ip'; $e.note = "also: " + (($qs | Select-Object -Skip 1 | ForEach-Object { "\\$($_.PrintServer)\$($_.ShareName)" }) -join ', ') }
        }
    }

    # --- reconcile ---
    foreach ($ip in @($entries.Keys)) {
        $e = $entries[$ip]
        if ($e.ip) {
            if ($subnetTable) { $e.site = (Get-PrinterSite -IPAddress $e.ip -SubnetTable $subnetTable).Site }
            $dns = Resolve-HostName $e.ip
            if ($dns) { $e.hostName = ($dns -split '\.')[0] }
        }
        elseif ($e.queueKind -eq 'Pull') { $e.site = $null }
        $e.sources = @($e.sources | Sort-Object -Unique)
        if (-not $e.name) {
            $e.name = @($e.shareName, $e.hostName, $e.dhcpName, $e.snmpName, $(if ($e.model) { "$($e.model) $($e.ip)" }), $e.ip) | Where-Object { $_ } | Select-Object -First 1
        }
        if ($e.shareName -and $e.snmpName -and ((ConvertTo-ComparableName $e.shareName) -ne (ConvertTo-ComparableName $e.snmpName)) -and ((ConvertTo-ComparableName $e.hostName) -ne (ConvertTo-ComparableName $e.snmpName))) { $e.flags += 'name-mismatch' }
        if ($e.ip -and -not $e.vendor) { $e.flags += 'unknown-vendor' }
        if ($e.ip -and $e.sources -notcontains 'snmp') { $e.flags += 'no-snmp' }
        $e.flags = @($e.flags | Sort-Object -Unique)
        [pscustomobject]$e
    }
}

function ConvertTo-ComparableName {
    param([string] $Value)
    if (-not $Value) { return '' }
    return (($Value -replace '[^A-Za-z0-9]', '').ToLowerInvariant())
}
