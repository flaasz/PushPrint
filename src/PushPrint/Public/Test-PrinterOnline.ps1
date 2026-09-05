function Test-PrinterOnline {
    <#
    .SYNOPSIS
        Quick health check for printers: ICMP, print port (9100), SNMP reachability, status and error flags.
    .EXAMPLE
        Get-PrinterCatalog -Site KUJ | Test-PrinterOnline | Where-Object { -not $_.Online }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)] [Alias('ip', 'HostAddress')] [string[]] $IPAddress,
        [Parameter(ValueFromPipelineByPropertyName)] [string] $Name,
        [int] $ThrottleLimit,
        [string] $ConfigPath
    )
    begin {
        $cfg = if ($ConfigPath) { Get-PushPrintConfig -Path $ConfigPath } else { Get-PushPrintConfig }
        if (-not $ThrottleLimit) { $ThrottleLimit = [int]$cfg.discovery.maxThreads }
        $items = New-Object System.Collections.Generic.List[object]
    }
    process { foreach ($ip in $IPAddress) { $items.Add([pscustomobject]@{ IP = $ip; Name = $Name }) } }
    end {
        $args_ = @{ Community = [string]$cfg.snmp.community; TimeoutMs = [int]$cfg.snmp.timeoutMs; Port = [int]$cfg.snmp.port; TcpTimeoutMs = [int]$cfg.discovery.tcpTimeoutMs; ConfigPath = $ConfigPath }
        Invoke-Parallel -InputObject $items.ToArray() -ThrottleLimit $ThrottleLimit -ArgumentList $args_ -ScriptBlock {
            param($Item, $Params)
            $ping = $false
            try { $ping = (New-Object System.Net.NetworkInformation.Ping).Send($Item.IP, 1000).Status -eq 'Success' }
            catch { Write-Verbose "Ping $($Item.IP): $($_.Exception.Message)" }
            $p9100 = Test-TcpPort -ComputerName $Item.IP -Port 9100 -TimeoutMs $Params.TcpTimeoutMs
            $getArgs = @{ IPAddress = $Item.IP; Community = $Params.Community; TimeoutMs = $Params.TimeoutMs; Retries = 0 }
            if ($Params.ConfigPath) { $getArgs.ConfigPath = $Params.ConfigPath }
            $info = Get-PrinterSnmpInfo @getArgs
            [pscustomobject]@{
                IPAddress  = $Item.IP
                Name       = $Item.Name
                Online     = ($ping -or $p9100 -or $info.Reachable)
                Ping       = $ping
                Port9100   = $p9100
                Snmp       = $info.Reachable
                Status     = $info.Status
                ErrorState = $info.ErrorState
                SysName    = $info.SysName
                Model      = $info.Model
            }
        }
    }
}
