# Minimal SNMP v1/v2c GET / GETNEXT implementation over UDP (BER encoding done by hand).
# No COM objects, no external DLLs: works identically on Windows PowerShell 5.1 and PowerShell 7.

$script:SnmpOid = @{
    sysDescr                    = '1.3.6.1.2.1.1.1.0'
    sysObjectID                 = '1.3.6.1.2.1.1.2.0'
    sysUpTime                   = '1.3.6.1.2.1.1.3.0'
    sysContact                  = '1.3.6.1.2.1.1.4.0'
    sysName                     = '1.3.6.1.2.1.1.5.0'
    sysLocation                 = '1.3.6.1.2.1.1.6.0'
    ifPhysAddress               = '1.3.6.1.2.1.2.2.1.6'          # table - walk
    hrDeviceType                = '1.3.6.1.2.1.25.3.2.1.2.1'
    hrDeviceDescr               = '1.3.6.1.2.1.25.3.2.1.3.1'
    hrPrinterStatus             = '1.3.6.1.2.1.25.3.5.1.1.1'
    hrPrinterDetectedErrorState = '1.3.6.1.2.1.25.3.5.1.2.1'
    prtGeneralPrinterName       = '1.3.6.1.2.1.43.5.1.1.16.1'
    prtGeneralSerialNumber      = '1.3.6.1.2.1.43.5.1.1.17.1'
    prtMarkerLifeCount          = '1.3.6.1.2.1.43.10.2.1.4.1.1'
    prtMarkerSuppliesDescription = '1.3.6.1.2.1.43.11.1.1.6.1'   # table - walk
    prtMarkerSuppliesMaxCapacity = '1.3.6.1.2.1.43.11.1.1.8.1'   # table - walk
    prtMarkerSuppliesLevel      = '1.3.6.1.2.1.43.11.1.1.9.1'    # table - walk
    hrDeviceTypePrinter         = '1.3.6.1.2.1.25.3.1.5'
}

$script:HrPrinterStatusText = @{ 1 = 'other'; 2 = 'unknown'; 3 = 'idle'; 4 = 'printing'; 5 = 'warmup' }

function ConvertTo-BerLength {
    [OutputType([byte[]])]
    param([Parameter(Mandatory)] [int] $Length)
    # Leading commas: keep byte[] intact instead of unrolling it into the pipeline.
    if ($Length -lt 0x80) { return , [byte[]]@($Length) }
    if ($Length -le 0xFF) { return , [byte[]]@(0x81, $Length) }
    return , [byte[]]@(0x82, (($Length -shr 8) -band 0xFF), ($Length -band 0xFF))
}

function New-BerTlv {
    [OutputType([byte[]])]
    param([Parameter(Mandatory)] [byte] $Tag, [AllowEmptyCollection()] [byte[]] $Content = @())
    $len = ConvertTo-BerLength $Content.Length
    return , [byte[]](@($Tag) + $len + $Content)
}

function ConvertTo-BerInteger {
    [OutputType([byte[]])]
    param([Parameter(Mandatory)] [long] $Value)
    $bytes = New-Object System.Collections.Generic.List[byte]
    $v = $Value
    do {
        $bytes.Insert(0, [byte]($v -band 0xFF))
        $v = $v -shr 8
    } while (-not (($v -eq 0 -and ($bytes[0] -band 0x80) -eq 0) -or ($v -eq -1 -and ($bytes[0] -band 0x80) -ne 0)))
    return , (New-BerTlv -Tag 0x02 -Content $bytes.ToArray())
}

function ConvertTo-BerOid {
    [OutputType([byte[]])]
    param([Parameter(Mandatory)] [string] $Oid)
    $parts = @($Oid.Trim('.') -split '\.' | ForEach-Object { [uint32]$_ })
    if ($parts.Count -lt 2) { throw "OID '$Oid' must have at least two arcs" }
    $out = New-Object System.Collections.Generic.List[byte]
    $out.Add([byte](40 * $parts[0] + $parts[1]))
    for ($i = 2; $i -lt $parts.Count; $i++) {
        $arc = $parts[$i]
        $chunk = New-Object System.Collections.Generic.List[byte]
        $chunk.Insert(0, [byte]($arc -band 0x7F)); $arc = $arc -shr 7
        while ($arc -gt 0) { $chunk.Insert(0, [byte](($arc -band 0x7F) -bor 0x80)); $arc = $arc -shr 7 }
        $out.AddRange($chunk)
    }
    return , (New-BerTlv -Tag 0x06 -Content $out.ToArray())
}

function New-SnmpRequest {
    <#
    .SYNOPSIS  Builds an SNMP v2c GetRequest (0xA0) or GetNextRequest (0xA1) message.
    #>
    [OutputType([byte[]])]
    param(
        [Parameter(Mandatory)] [string[]] $Oid,
        [string] $Community = 'public',
        [ValidateSet('Get', 'GetNext')] [string] $Type = 'Get',
        [int] $RequestId = (Get-Random -Minimum 1 -Maximum 0x7FFFFFFF),
        [ValidateSet(1, 2)] [int] $Version = 2
    )
    $varbinds = New-Object System.Collections.Generic.List[byte]
    foreach ($o in $Oid) {
        $vb = New-BerTlv -Tag 0x30 -Content ([byte[]]((ConvertTo-BerOid $o) + (New-BerTlv -Tag 0x05)))
        $varbinds.AddRange($vb)
    }
    $pduContent = [byte[]]((ConvertTo-BerInteger $RequestId) + (ConvertTo-BerInteger 0) + (ConvertTo-BerInteger 0) + (New-BerTlv -Tag 0x30 -Content $varbinds.ToArray()))
    $pduTag = if ($Type -eq 'Get') { 0xA0 } else { 0xA1 }
    $pdu = New-BerTlv -Tag $pduTag -Content $pduContent
    # NB: not "$community" - PowerShell variables are case-insensitive and the [string] constraint on the parameter
    # would silently stringify the byte array.
    $communityTlv = New-BerTlv -Tag 0x04 -Content ([System.Text.Encoding]::ASCII.GetBytes($Community))
    return , (New-BerTlv -Tag 0x30 -Content ([byte[]]((ConvertTo-BerInteger ($Version - 1)) + $communityTlv + $pdu)))
}

function Read-BerTlv {
    param([Parameter(Mandatory)] [byte[]] $Buffer, [Parameter(Mandatory)] [ref] $Position)
    $pos = $Position.Value
    if ($pos -ge $Buffer.Length) { throw 'BER: unexpected end of buffer' }
    $tag = $Buffer[$pos++]
    $len = [int]$Buffer[$pos++]
    if ($len -band 0x80) {
        $n = $len -band 0x7F; $len = 0
        for ($i = 0; $i -lt $n; $i++) { $len = ($len -shl 8) -bor $Buffer[$pos++] }
    }
    if ($pos + $len -gt $Buffer.Length) { throw 'BER: length exceeds buffer' }
    $content = New-Object byte[] $len
    if ($len -gt 0) { [Array]::Copy($Buffer, $pos, $content, 0, $len) }
    $Position.Value = $pos + $len
    return [pscustomobject]@{ Tag = $tag; Length = $len; Content = $content }
}

function ConvertFrom-BerInteger {
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [byte[]] $Content, [switch] $Unsigned)
    if ($Content.Length -eq 0) { return 0 }
    [long]$v = if (-not $Unsigned -and ($Content[0] -band 0x80)) { -1 } else { 0 }
    foreach ($b in $Content) { $v = ($v -shl 8) -bor $b }
    return $v
}

function ConvertFrom-BerOid {
    param([Parameter(Mandatory)] [byte[]] $Content)
    if ($Content.Length -eq 0) { return '' }
    $first = [int]$Content[0]
    $a = [Math]::Min([int][Math]::Floor($first / 40), 2); $b = $first - 40 * $a
    $parts = New-Object System.Collections.Generic.List[string]
    $parts.Add("$a"); $parts.Add("$b")
    [uint64]$acc = 0
    for ($i = 1; $i -lt $Content.Length; $i++) {
        $acc = ($acc -shl 7) -bor ($Content[$i] -band 0x7F)
        if (-not ($Content[$i] -band 0x80)) { $parts.Add("$acc"); $acc = 0 }
    }
    return ($parts -join '.')
}

function ConvertFrom-SnmpValue {
    param([Parameter(Mandatory)] $Tlv)
    $c = $Tlv.Content
    switch ($Tlv.Tag) {
        0x02 { return [pscustomobject]@{ Type = 'Integer';    Value = (ConvertFrom-BerInteger $c);           Raw = $c } }
        0x04 {
            $printable = $true
            foreach ($b in $c) { if (($b -lt 0x20 -and $b -notin 9, 10, 13) -or $b -eq 0x7F) { $printable = $false; break } }
            $text = if ($printable) { [System.Text.Encoding]::UTF8.GetString($c).Trim() } else { ($c | ForEach-Object { $_.ToString('X2') }) -join ':' }
            return [pscustomobject]@{ Type = 'OctetString'; Value = $text; Raw = $c }
        }
        0x05 { return [pscustomobject]@{ Type = 'Null';       Value = $null; Raw = $c } }
        0x06 { return [pscustomobject]@{ Type = 'Oid';        Value = (ConvertFrom-BerOid $c); Raw = $c } }
        0x40 { return [pscustomobject]@{ Type = 'IpAddress';  Value = (($c | ForEach-Object { "$_" }) -join '.'); Raw = $c } }
        0x41 { return [pscustomobject]@{ Type = 'Counter32';  Value = (ConvertFrom-BerInteger $c -Unsigned); Raw = $c } }
        0x42 { return [pscustomobject]@{ Type = 'Gauge32';    Value = (ConvertFrom-BerInteger $c -Unsigned); Raw = $c } }
        0x43 { return [pscustomobject]@{ Type = 'TimeTicks';  Value = (ConvertFrom-BerInteger $c -Unsigned); Raw = $c } }
        0x46 { return [pscustomobject]@{ Type = 'Counter64';  Value = (ConvertFrom-BerInteger $c -Unsigned); Raw = $c } }
        0x80 { return [pscustomobject]@{ Type = 'NoSuchObject';   Value = $null; Raw = $c } }
        0x81 { return [pscustomobject]@{ Type = 'NoSuchInstance'; Value = $null; Raw = $c } }
        0x82 { return [pscustomobject]@{ Type = 'EndOfMibView';   Value = $null; Raw = $c } }
        default { return [pscustomobject]@{ Type = ('Unknown0x{0:X2}' -f $Tlv.Tag); Value = $null; Raw = $c } }
    }
}

function ConvertFrom-SnmpResponse {
    <#
    .SYNOPSIS  Parses an SNMP response datagram. Returns RequestId, ErrorStatus and an ordered OID -> value map.
    #>
    param([Parameter(Mandatory)] [byte[]] $Buffer)
    $pos = 0
    $msg = Read-BerTlv $Buffer ([ref]$pos)
    if ($msg.Tag -ne 0x30) { throw 'SNMP: message is not a SEQUENCE' }
    $p = 0
    $null = Read-BerTlv $msg.Content ([ref]$p)              # version
    $null = Read-BerTlv $msg.Content ([ref]$p)              # community
    $pdu  = Read-BerTlv $msg.Content ([ref]$p)
    if ($pdu.Tag -ne 0xA2) { throw ('SNMP: unexpected PDU type 0x{0:X2}' -f $pdu.Tag) }
    $p = 0
    $reqId  = ConvertFrom-BerInteger (Read-BerTlv $pdu.Content ([ref]$p)).Content
    $errSt  = ConvertFrom-BerInteger (Read-BerTlv $pdu.Content ([ref]$p)).Content
    $errIdx = ConvertFrom-BerInteger (Read-BerTlv $pdu.Content ([ref]$p)).Content
    $vbl    = Read-BerTlv $pdu.Content ([ref]$p)
    $vars = [ordered]@{}
    $p = 0
    while ($p -lt $vbl.Content.Length) {
        $vb = Read-BerTlv $vbl.Content ([ref]$p)
        $q = 0
        $oidTlv = Read-BerTlv $vb.Content ([ref]$q)
        $valTlv = Read-BerTlv $vb.Content ([ref]$q)
        $vars[(ConvertFrom-BerOid $oidTlv.Content)] = ConvertFrom-SnmpValue $valTlv
    }
    return [pscustomobject]@{ RequestId = $reqId; ErrorStatus = $errSt; ErrorIndex = $errIdx; VarBinds = $vars }
}

function Invoke-SnmpRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $IPAddress,
        [Parameter(Mandatory)] [string[]] $Oid,
        [string] $Community = 'public',
        [ValidateSet('Get', 'GetNext')] [string] $Type = 'Get',
        [int] $TimeoutMs = 800,
        [int] $Retries = 1,
        [int] $Port = 161
    )
    $reqId = Get-Random -Minimum 1 -Maximum 0x7FFFFFFF
    $packet = New-SnmpRequest -Oid $Oid -Community $Community -Type $Type -RequestId $reqId
    $attempt = 0
    while ($attempt -le $Retries) {
        $attempt++
        $udp = $null
        try {
            $udp = New-Object System.Net.Sockets.UdpClient
            $udp.Client.ReceiveTimeout = $TimeoutMs
            $udp.Connect($IPAddress, $Port)
            [void]$udp.Send($packet, $packet.Length)
            $ep = New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Any, 0)
            $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
            do {
                $resp = $udp.Receive([ref]$ep)
                $parsed = ConvertFrom-SnmpResponse $resp
                if ($parsed.RequestId -eq $reqId) { return $parsed }
            } while ([DateTime]::UtcNow -lt $deadline)
        }
        catch [System.Net.Sockets.SocketException] {
            if ($attempt -gt $Retries) { return $null }
        }
        catch {
            Write-Verbose "SNMP ${IPAddress}: $($_.Exception.Message)"
            if ($attempt -gt $Retries) { return $null }
        }
        finally { if ($udp) { $udp.Close() } }
    }
    return $null
}

function Invoke-SnmpGet {
    <#
    .SYNOPSIS  SNMP GET for one or more OIDs. Returns an ordered hashtable OID -> decoded value object, or $null on timeout.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $IPAddress,
        [Parameter(Mandatory)] [string[]] $Oid,
        [string] $Community = 'public',
        [int] $TimeoutMs = 800,
        [int] $Retries = 1,
        [int] $Port = 161
    )
    $r = Invoke-SnmpRequest -IPAddress $IPAddress -Oid $Oid -Community $Community -Type Get -TimeoutMs $TimeoutMs -Retries $Retries -Port $Port
    if ($null -eq $r) { return $null }
    return $r.VarBinds
}

function Invoke-SnmpWalk {
    <#
    .SYNOPSIS  Walks a subtree with GETNEXT. Returns ordered OID -> value for every OID under $BaseOid.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $IPAddress,
        [Parameter(Mandatory)] [string] $BaseOid,
        [string] $Community = 'public',
        [int] $TimeoutMs = 800,
        [int] $Retries = 1,
        [int] $MaxResults = 200,
        [int] $Port = 161
    )
    $result = [ordered]@{}
    $current = $BaseOid.Trim('.')
    $prefix = "$current."
    while ($result.Count -lt $MaxResults) {
        $r = Invoke-SnmpRequest -IPAddress $IPAddress -Oid $current -Community $Community -Type GetNext -TimeoutMs $TimeoutMs -Retries $Retries -Port $Port
        if ($null -eq $r -or $r.VarBinds.Count -eq 0) { break }
        $next = @($r.VarBinds.Keys)[0]
        $val = $r.VarBinds[$next]
        if (-not $next.StartsWith($prefix) -or $val.Type -eq 'EndOfMibView' -or $result.Contains($next)) { break }
        $result[$next] = $val
        $current = $next
    }
    return $result
}

function Get-SnmpValueText {
    <#
    .SYNOPSIS  Convenience: value text for an OID from an Invoke-SnmpGet result, or $null.
    #>
    param($VarBinds, [string] $Oid)
    if ($null -eq $VarBinds) { return $null }
    $key = $Oid.Trim('.')
    if (-not $VarBinds.Contains($key)) { return $null }
    $v = $VarBinds[$key]
    if ($v.Type -in 'NoSuchObject', 'NoSuchInstance', 'EndOfMibView', 'Null') { return $null }
    return $v.Value
}
