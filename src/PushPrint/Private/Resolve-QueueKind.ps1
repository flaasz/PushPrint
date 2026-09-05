function Resolve-QueueKind {
    <#
    .SYNOPSIS
        Classifies a print server queue as Direct (port points at a physical printer), Pull (port points at a
        pull-print / secure-print server such as YSoft SafeQ, PaperCut, Printix), Local (non-network port) or Unknown.
    .DESCRIPTION
        Pure function so it is unit-testable. Signals, in priority order:
          1. Port host address is one of the configured pullPrintServers               -> Pull   (High)
          2. Port monitor / port description / driver / queue name / comment matches a pull marker -> Pull (High)
          3. Port has no TCP/IP host address (LPT, USB, FILE, nul, ...)               -> Local  (High)
          4. Probe result: host speaks Printer-MIB or answers on 9100/631/515         -> Direct (High)
                           host answers SMB (445) or RPC (135) but no printer port    -> Pull   (Medium)
          5. No probe: TCP/IP port                                                    -> Direct (Low)
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string] $QueueName,
        [string] $PortName,
        [string] $PortMonitor,
        [string] $PortDescription,
        [string] $HostAddress,
        [string] $DriverName,
        [string] $Comment,
        [string[]] $PullMarkers = @(),
        [string[]] $PullServers = @(),
        [hashtable] $Probe          # keys: IsPrinter, PrinterPortOpen, SmbOpen (bool or $null)
    )
    $mk = { param($kind, $conf, $reason) [pscustomobject]@{ Kind = $kind; Confidence = $conf; Reason = $reason } }

    if ($HostAddress -and $PullServers) {
        foreach ($s in $PullServers) {
            if ($s -and ($HostAddress -ieq $s -or $HostAddress -like "$s.*")) { return & $mk 'Pull' 'High' "port points at configured pull-print server '$s'" }
        }
    }
    $fields = [ordered]@{ 'port monitor' = $PortMonitor; 'port description' = $PortDescription; driver = $DriverName; 'queue name' = $QueueName; comment = $Comment; 'port name' = $PortName }
    foreach ($m in $PullMarkers) {
        if (-not $m) { continue }
        $rx = '(?i)(?<![A-Za-z0-9])' + [regex]::Escape($m) + '(?![A-Za-z0-9])'
        foreach ($f in $fields.Keys) {
            if ($fields[$f] -and $fields[$f] -match $rx) { return & $mk 'Pull' 'High' "marker '$m' in $f" }
        }
    }
    if (-not $HostAddress) {
        if ($PortName -match '^(LPT\d|COM\d|USB|FILE:|nul:|PORTPROMPT:|SHRFAX:|Microsoft\.Office|OneNote|PDF|XPS)') { return & $mk 'Local' 'High' 'non-network port' }
        return & $mk 'Unknown' 'Low' 'port has no host address'
    }
    if ($Probe) {
        if ($Probe['IsPrinter'] -eq $true) { return & $mk 'Direct' 'High' 'device answers Printer-MIB over SNMP' }
        if ($Probe['PrinterPortOpen'] -eq $true) { return & $mk 'Direct' 'High' 'device accepts print protocol connection (9100/631/515)' }
        if ($Probe['SmbOpen'] -eq $true) { return & $mk 'Pull' 'Medium' 'host answers SMB/RPC but no printer port: looks like a print/pull server' }
        if ($Probe['IsPrinter'] -eq $false -and $Probe['PrinterPortOpen'] -eq $false) { return & $mk 'Unknown' 'Low' 'host unreachable during probe' }
    }
    return & $mk 'Direct' 'Low' 'TCP/IP port (not probed)'
}
