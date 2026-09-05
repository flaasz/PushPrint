function Get-PrintServerQueue {
    <#
    .SYNOPSIS
        Lists shared queues on print servers with their port host address and a Direct / Pull classification.
    .DESCRIPTION
        Uses Get-Printer / Get-PrinterPort against the server (needs read rights on the spooler, no admin).
        With -Probe, every distinct port host is checked over SNMP + TCP so queues whose port points at a
        pull-print server (SafeQ, PaperCut, ...) instead of a physical printer are detected reliably.
    .PARAMETER PrintServer
        Host names/IPs or keys from the printServers table. Default: all configured print servers.
    .EXAMPLE
        Get-PrintServerQueue -Probe | Where-Object Kind -eq Pull
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(ValueFromPipeline, Position = 0)] [string[]] $PrintServer,
        [switch] $Probe,
        [switch] $IncludeUnshared,
        [string] $ConfigPath
    )
    begin {
        $cfg = if ($ConfigPath) { Get-PushPrintConfig -Path $ConfigPath } else { Get-PushPrintConfig }
        $servers = New-Object System.Collections.Generic.List[string]
    }
    process { foreach ($s in $PrintServer) { if ($s) { $servers.Add($s) } } }
    end {
        if ($servers.Count -eq 0) { foreach ($k in $cfg.printServers.Keys) { $servers.Add([string]$cfg.printServers[$k]) } }
        if ($servers.Count -eq 0) { throw 'No print servers given and none configured (printServers in settings.json).' }
        $pullServers = @($cfg.pullPrintServers | ForEach-Object { $_; $ip = Resolve-IPv4Address $_; if ($ip -and $ip -ne $_) { $ip } })

        foreach ($srv in $servers) {
            $key = $cfg.printServers.Keys | Where-Object { $_ -ieq $srv } | Select-Object -First 1
            $host_ = if ($key) { [string]$cfg.printServers[$key] } else { $srv }
            $label = if ($key) { $key } else { $host_ }
            Write-PmLog -Target $label 'Enumerating queues'
            try {
                $printers = @(Get-Printer -ComputerName $host_ -ErrorAction Stop)
                $ports = @{}
                Get-PrinterPort -ComputerName $host_ -ErrorAction SilentlyContinue | ForEach-Object { $ports[$_.Name] = $_ }
            }
            catch { Write-Error -Message "$host_ : $($_.Exception.Message)" -TargetObject $host_; continue }
            if (-not $IncludeUnshared) { $printers = @($printers | Where-Object Shared) }

            $probeCache = @{}
            if ($Probe) {
                $hosts = @($printers | ForEach-Object { $p = $ports[$_.PortName]; if ($p) { Get-PortHostAddress $p } } | Where-Object { $_ } | Sort-Object -Unique)
                Write-PmLog -Target $label "Probing $($hosts.Count) port hosts"
                $probeArgs = @{ Community = $cfg.snmp.community; TimeoutMs = [int]$cfg.snmp.timeoutMs; TcpTimeoutMs = [int]$cfg.discovery.tcpTimeoutMs; Ports = @($cfg.discovery.probePorts) }
                $probed = Invoke-Parallel -InputObject $hosts -ThrottleLimit ([int]$cfg.discovery.maxThreads) -ArgumentList $probeArgs -ScriptBlock {
                    param($Item, $Params)
                    $ip = Resolve-IPv4Address $Item
                    $r = @{ Host = $Item; IsPrinter = $null; PrinterPortOpen = $null; SmbOpen = $null }
                    if (-not $ip) { return [pscustomobject]$r }
                    $vb = Invoke-SnmpGet -IPAddress $ip -Oid $script:SnmpOid.hrDeviceType, $script:SnmpOid.sysDescr, $script:SnmpOid.prtGeneralPrinterName -Community $Params.Community -TimeoutMs $Params.TimeoutMs -Retries 0
                    if ($vb) {
                        $type = Get-SnmpValueText $vb $script:SnmpOid.hrDeviceType
                        $r.IsPrinter = ($type -eq $script:SnmpOid.hrDeviceTypePrinter) -or ($null -ne (Get-SnmpValueText $vb $script:SnmpOid.prtGeneralPrinterName))
                    }
                    else { $r.IsPrinter = $false }
                    $r.PrinterPortOpen = $false
                    foreach ($port in $Params.Ports) { if (Test-TcpPort -ComputerName $ip -Port $port -TimeoutMs $Params.TcpTimeoutMs) { $r.PrinterPortOpen = $true; break } }
                    $r.SmbOpen = (Test-TcpPort -ComputerName $ip -Port 445 -TimeoutMs $Params.TcpTimeoutMs) -or (Test-TcpPort -ComputerName $ip -Port 135 -TimeoutMs $Params.TcpTimeoutMs)
                    [pscustomobject]$r
                }
                foreach ($p in $probed) { $probeCache[$p.Host] = @{ IsPrinter = $p.IsPrinter; PrinterPortOpen = $p.PrinterPortOpen; SmbOpen = $p.SmbOpen } }
            }

            foreach ($pr in $printers) {
                $port = $ports[$pr.PortName]
                $hostAddr = if ($port) { Get-PortHostAddress $port } else { $null }
                $kind = Resolve-QueueKind -QueueName $pr.Name -PortName $pr.PortName -PortMonitor $(if ($port) { $port.PortMonitor }) `
                    -PortDescription $(if ($port) { $port.Description }) -HostAddress $hostAddr -DriverName $pr.DriverName -Comment $pr.Comment `
                    -PullMarkers @($cfg.pullQueueMarkers) -PullServers $pullServers -Probe $(if ($hostAddr -and $probeCache.ContainsKey($hostAddr)) { $probeCache[$hostAddr] })
                [pscustomobject]@{
                    PrintServer  = $host_
                    ServerLabel  = $label
                    Name         = $pr.Name
                    ShareName    = $pr.ShareName
                    Published    = [bool]$pr.Published
                    Driver       = $pr.DriverName
                    PortName     = $pr.PortName
                    PortMonitor  = if ($port) { $port.PortMonitor } else { $null }
                    HostAddress  = $hostAddr
                    Kind         = $kind.Kind
                    Confidence   = $kind.Confidence
                    KindReason   = $kind.Reason
                    Location     = $pr.Location
                    Comment      = $pr.Comment
                    Status       = $pr.PrinterStatus
                }
            }
        }
    }
}

function Get-PortHostAddress {
    param([Parameter(Mandatory)] $Port)
    foreach ($prop in 'PrinterHostAddress', 'LprHostAddress', 'HostAddress') {
        $v = Get-PropertyValue $Port $prop
        if ($v) { return [string]$v }
    }
    return $null
}
