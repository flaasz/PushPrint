function Get-PrinterSnmpInfo {
    <#
    .SYNOPSIS
        Reads identity and status from a printer over SNMP (v2c): system name, model, serial, location, MAC, vendor,
        printer status, page count and optionally supply levels. Returns $null-safe objects; unreachable hosts
        yield Reachable = $false.
    .EXAMPLE
        Get-PrinterSnmpInfo -IPAddress 10.1.2.20 -IncludeSupplies
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)] [Alias('ip', 'HostAddress')] [string[]] $IPAddress,
        [string] $Community,
        [int] $TimeoutMs,
        [int] $Retries = -1,
        [switch] $IncludeSupplies,
        [string] $ConfigPath
    )
    begin {
        $cfg = if ($ConfigPath) { Get-PushPrintConfig -Path $ConfigPath } else { Get-PushPrintConfig }
        if (-not $Community) { $Community = [string]$cfg.snmp.community }
        if (-not $TimeoutMs) { $TimeoutMs = [int]$cfg.snmp.timeoutMs }
        if ($Retries -lt 0) { $Retries = [int]$cfg.snmp.retries }
        $port = [int]$cfg.snmp.port
        $O = $script:SnmpOid
    }
    process {
        foreach ($ip in $IPAddress) {
            $info = [ordered]@{
                IPAddress = $ip; Reachable = $false; IsPrinter = $false; SysName = $null; PrinterName = $null; Model = $null; SysDescr = $null
                SerialNumber = $null; Location = $null; Contact = $null; MacAddress = $null; Vendor = $null; Status = $null; ErrorState = $null
                PageCount = $null; UpTime = $null; Supplies = @(); Source = 'SNMP'
            }
            $vb = Invoke-SnmpGet -IPAddress $ip -Port $port -Community $Community -TimeoutMs $TimeoutMs -Retries $Retries -Oid @(
                $O.sysDescr, $O.sysName, $O.sysLocation, $O.sysContact, $O.sysUpTime, $O.hrDeviceType, $O.hrDeviceDescr,
                $O.hrPrinterStatus, $O.hrPrinterDetectedErrorState, $O.prtGeneralPrinterName, $O.prtGeneralSerialNumber, $O.prtMarkerLifeCount)
            if ($null -eq $vb) { [pscustomobject]$info; continue }
            $info.Reachable    = $true
            $info.SysDescr     = Get-SnmpValueText $vb $O.sysDescr
            $info.SysName      = Get-SnmpValueText $vb $O.sysName
            $info.Location     = Get-SnmpValueText $vb $O.sysLocation
            $info.Contact      = Get-SnmpValueText $vb $O.sysContact
            $info.Model        = Get-SnmpValueText $vb $O.hrDeviceDescr
            $info.PrinterName  = Get-SnmpValueText $vb $O.prtGeneralPrinterName
            $info.SerialNumber = Get-SnmpValueText $vb $O.prtGeneralSerialNumber
            $info.PageCount    = Get-SnmpValueText $vb $O.prtMarkerLifeCount
            $up = Get-SnmpValueText $vb $O.sysUpTime
            if ($null -ne $up) { $info.UpTime = [TimeSpan]::FromMilliseconds([double]$up * 10) }
            $st = Get-SnmpValueText $vb $O.hrPrinterStatus
            if ($null -ne $st) { $info.Status = if ($script:HrPrinterStatusText.ContainsKey([int]$st)) { $script:HrPrinterStatusText[[int]$st] } else { "$st" } }
            $es = $vb[$O.hrPrinterDetectedErrorState]
            if ($es -and $es.Type -eq 'OctetString' -and $es.Raw.Length -ge 1) { $info.ErrorState = ConvertFrom-PrinterErrorState $es.Raw }
            $devType = Get-SnmpValueText $vb $O.hrDeviceType
            $info.IsPrinter = ($devType -eq $O.hrDeviceTypePrinter) -or ($null -ne $info.PrinterName) -or ($null -ne $info.SerialNumber)
            # MAC: first non-empty ifPhysAddress
            $mac = Invoke-SnmpWalk -IPAddress $ip -Port $port -BaseOid $O.ifPhysAddress -Community $Community -TimeoutMs $TimeoutMs -Retries 0 -MaxResults 8
            foreach ($k in $mac.Keys) {
                $raw = $mac[$k].Raw
                if ($raw.Length -eq 6 -and ($raw | Where-Object { $_ -ne 0 })) { $info.MacAddress = (($raw | ForEach-Object { $_.ToString('X2') }) -join ':'); break }
            }
            $info.Vendor = Get-VendorMatch -Drivers $cfg.drivers -Description "$($info.SysDescr) $($info.Model)" -Mac $info.MacAddress
            if ($IncludeSupplies) {
                $desc = Invoke-SnmpWalk -IPAddress $ip -Port $port -BaseOid $O.prtMarkerSuppliesDescription -Community $Community -TimeoutMs $TimeoutMs -Retries 0 -MaxResults 32
                $max  = Invoke-SnmpWalk -IPAddress $ip -Port $port -BaseOid $O.prtMarkerSuppliesMaxCapacity -Community $Community -TimeoutMs $TimeoutMs -Retries 0 -MaxResults 32
                $lvl  = Invoke-SnmpWalk -IPAddress $ip -Port $port -BaseOid $O.prtMarkerSuppliesLevel -Community $Community -TimeoutMs $TimeoutMs -Retries 0 -MaxResults 32
                $info.Supplies = @(foreach ($k in $desc.Keys) {
                    $idx = $k.Substring($O.prtMarkerSuppliesDescription.Length + 1)
                    $m = $max["$($O.prtMarkerSuppliesMaxCapacity).$idx"]; $l = $lvl["$($O.prtMarkerSuppliesLevel).$idx"]
                    $pct = if ($m -and $l -and $m.Value -gt 0 -and $l.Value -ge 0) { [int](100 * $l.Value / $m.Value) } else { $null }
                    [pscustomobject]@{ Description = $desc[$k].Value; Level = $(if ($l) { $l.Value }); MaxCapacity = $(if ($m) { $m.Value }); Percent = $pct }
                })
            }
            [pscustomobject]$info
        }
    }
}

function ConvertFrom-PrinterErrorState {
    # hrPrinterDetectedErrorState bit flags (RFC 2790). Byte 0 bits 7..0, byte 1 bits 7..0.
    param([byte[]] $Raw)
    $names = @('lowPaper', 'noPaper', 'lowToner', 'noToner', 'doorOpen', 'jammed', 'offline', 'serviceRequested',
               'inputTrayMissing', 'outputTrayMissing', 'markerSupplyMissing', 'outputNearFull', 'outputFull', 'inputTrayEmpty', 'overduePreventMaint')
    $flags = @()
    for ($i = 0; $i -lt [Math]::Min(2, $Raw.Length); $i++) {
        for ($b = 0; $b -lt 8; $b++) {
            $idx = $i * 8 + $b
            if ($idx -lt $names.Count -and ($Raw[$i] -band (0x80 -shr $b))) { $flags += $names[$idx] }
        }
    }
    return ($flags -join ',')
}
