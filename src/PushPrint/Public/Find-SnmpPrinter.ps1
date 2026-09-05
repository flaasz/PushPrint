function Find-SnmpPrinter {
    <#
    .SYNOPSIS
        Scans subnets (or whole AD sites) for printers: hosts answering a print protocol port or SNMP are then
        interrogated with Get-PrinterSnmpInfo. Runs in parallel; only IPv4.
    .PARAMETER Site
        AD site names (see Get-AdSiteSubnet). All subnets of the site are scanned.
    .PARAMETER Subnet
        CIDR ranges, single addresses or a-b ranges.
    .EXAMPLE
        Find-SnmpPrinter -Site KUJ | Where-Object IsPrinter | Format-Table IPAddress, SysName, Model, SerialNumber, Vendor
    #>
    [CmdletBinding(DefaultParameterSetName = 'Subnet')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Site')] [string[]] $Site,
        [Parameter(Mandatory, ParameterSetName = 'Subnet', ValueFromPipeline)] [Alias('Range', 'IPAddress')] [string[]] $Subnet,
        [switch] $IncludeNonPrinters,
        [switch] $IncludeSupplies,
        [int] $ThrottleLimit,
        [string] $ConfigPath
    )
    begin {
        $cfg = if ($ConfigPath) { Get-PushPrintConfig -Path $ConfigPath } else { Get-PushPrintConfig }
        if (-not $ThrottleLimit) { $ThrottleLimit = [int]$cfg.discovery.maxThreads }
        $ranges = New-Object System.Collections.Generic.List[string]
        $siteOf = @{}
    }
    process {
        if ($PSCmdlet.ParameterSetName -eq 'Subnet') { foreach ($s in $Subnet) { $ranges.Add($s) } }
    }
    end {
        if ($PSCmdlet.ParameterSetName -eq 'Site') {
            $subnets = @(Get-AdSiteSubnet -Site $Site -ConfigPath $ConfigPath)
            if (-not $subnets) { throw "No subnets found for site(s) $($Site -join ', ')" }
            foreach ($s in $subnets) { $ranges.Add($s.Subnet); $siteOf[$s.Subnet] = $s.Site }
        }
        $exclude = @($cfg.discovery.excludeSubnets)
        $hosts = New-Object System.Collections.Generic.List[object]
        foreach ($r in $ranges) {
            foreach ($ip in (Expand-IPRange -Range $r -MaxHosts ([int]$cfg.discovery.maxHostsPerScan))) {
                if ($exclude | Where-Object { Test-IPInSubnet -Cidr $_ -IPAddress $ip }) { continue }
                $hosts.Add([pscustomobject]@{ IP = $ip; Range = $r })
            }
        }
        Write-PmLog "Scanning $($hosts.Count) addresses in $($ranges.Count) range(s) with $ThrottleLimit threads"
        $args_ = @{
            Community = [string]$cfg.snmp.community; TimeoutMs = [int]$cfg.snmp.timeoutMs; Port = [int]$cfg.snmp.port
            TcpTimeoutMs = [int]$cfg.discovery.tcpTimeoutMs; Ports = @($cfg.discovery.probePorts)
            IncludeNonPrinters = $IncludeNonPrinters.IsPresent; IncludeSupplies = $IncludeSupplies.IsPresent; ConfigPath = $ConfigPath
        }
        $found = Invoke-Parallel -InputObject $hosts.ToArray() -ThrottleLimit $ThrottleLimit -ArgumentList $args_ -Activity 'Scanning for printers' -ScriptBlock {
            param($Item, $Params)
            $ip = $Item.IP
            $openPort = $null
            foreach ($p in $Params.Ports) { if (Test-TcpPort -ComputerName $ip -Port $p -TimeoutMs $Params.TcpTimeoutMs) { $openPort = $p; break } }
            $snmp = $null
            if (-not $openPort) {
                $snmp = Invoke-SnmpGet -IPAddress $ip -Port $Params.Port -Oid $script:SnmpOid.sysDescr -Community $Params.Community -TimeoutMs $Params.TimeoutMs -Retries 0
                if ($null -eq $snmp) { return }
            }
            $getArgs = @{ IPAddress = $ip; Community = $Params.Community; TimeoutMs = $Params.TimeoutMs; IncludeSupplies = $Params.IncludeSupplies }
            if ($Params.ConfigPath) { $getArgs.ConfigPath = $Params.ConfigPath }
            $info = Get-PrinterSnmpInfo @getArgs
            if (-not $info.IsPrinter -and -not $openPort -and -not $Params.IncludeNonPrinters) { return }
            if (-not $info.IsPrinter -and $openPort -and -not $info.Reachable) { $info.IsPrinter = $true }   # prints on 9100 but no SNMP: still a printer
            $info | Add-Member -NotePropertyName OpenPort -NotePropertyValue $openPort -PassThru | Add-Member -NotePropertyName Range -NotePropertyValue $Item.Range -PassThru
        }
        foreach ($f in $found) {
            $siteName = if ($siteOf.ContainsKey($f.Range)) { $siteOf[$f.Range] } else { $null }
            $f | Add-Member -NotePropertyName Site -NotePropertyValue $siteName -PassThru
        }
    }
}
