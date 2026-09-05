function ConvertTo-UInt32Address {
    param([Parameter(Mandatory)] [System.Net.IPAddress] $Address)
    $b = $Address.GetAddressBytes()
    return ([uint32]$b[0] -shl 24) -bor ([uint32]$b[1] -shl 16) -bor ([uint32]$b[2] -shl 8) -bor [uint32]$b[3]
}

function ConvertFrom-UInt32Address {
    param([Parameter(Mandatory)] [uint32] $Value)
    return ('{0}.{1}.{2}.{3}' -f (($Value -shr 24) -band 0xFF), (($Value -shr 16) -band 0xFF), (($Value -shr 8) -band 0xFF), ($Value -band 0xFF))
}

function Test-IPv4Address {
    param([string] $Value)
    $ip = $null
    return [System.Net.IPAddress]::TryParse($Value, [ref]$ip) -and $ip.AddressFamily -eq 'InterNetwork' -and $Value -match '^\d{1,3}(\.\d{1,3}){3}$'
}

function Test-IPInSubnet {
    <#
    .SYNOPSIS  True when $IPAddress is inside $Cidr (e.g. 10.16.17.0/24).
    #>
    param([Parameter(Mandatory)] [string] $Cidr, [Parameter(Mandatory)] [string] $IPAddress)
    if ($Cidr -notmatch '^(\d{1,3}(?:\.\d{1,3}){3})/(\d{1,2})$') { return $false }
    if (-not (Test-IPv4Address $IPAddress)) { return $false }
    $net = ConvertTo-UInt32Address ([System.Net.IPAddress]::Parse($Matches[1]))
    $bits = [int]$Matches[2]
    $mask = if ($bits -eq 0) { [uint32]0 } else { [uint32]((([uint64][uint32]::MaxValue) -shl (32 - $bits)) -band [uint32]::MaxValue) }
    $ip = ConvertTo-UInt32Address ([System.Net.IPAddress]::Parse($IPAddress))
    return (($ip -band $mask) -eq ($net -band $mask))
}

function Expand-IPRange {
    <#
    .SYNOPSIS
        Expands "10.16.17.0/24", "10.16.17.5", or "10.16.17.10-10.16.17.50" into host addresses.
        For CIDR /30 and larger networks the network and broadcast addresses are skipped.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)] [string[]] $Range,
        [int] $MaxHosts = 65536
    )
    process {
        foreach ($r in $Range) {
            $r = $r.Trim()
            if ($r -match '^(\d{1,3}(?:\.\d{1,3}){3})/(\d{1,2})$') {
                $bits = [int]$Matches[2]
                if ($bits -lt 8 -or $bits -gt 32) { throw "Prefix length out of range in '$r' (8-32 supported)" }
                $net = ConvertTo-UInt32Address ([System.Net.IPAddress]::Parse($Matches[1]))
                $size = [uint32]([Math]::Pow(2, 32 - $bits))
                if ($size -gt $MaxHosts) { throw "'$r' expands to $size hosts; limit is $MaxHosts. Split it or raise -MaxHosts." }
                $mask = [uint32]((([uint64][uint32]::MaxValue) -shl (32 - $bits)) -band [uint32]::MaxValue)
                $start = $net -band $mask
                $first = $start; $last = $start + $size - 1
                if ($bits -le 30) { $first++; $last-- }
                for ([uint64]$i = $first; $i -le $last; $i++) { ConvertFrom-UInt32Address ([uint32]$i) }
            }
            elseif ($r -match '^(\d{1,3}(?:\.\d{1,3}){3})\s*-\s*(\d{1,3}(?:\.\d{1,3}){3})$') {
                $a = ConvertTo-UInt32Address ([System.Net.IPAddress]::Parse($Matches[1]))
                $b = ConvertTo-UInt32Address ([System.Net.IPAddress]::Parse($Matches[2]))
                if ($b -lt $a) { $t = $a; $a = $b; $b = $t }
                if (($b - $a + 1) -gt $MaxHosts) { throw "'$r' expands to more than $MaxHosts hosts." }
                for ([uint64]$i = $a; $i -le $b; $i++) { ConvertFrom-UInt32Address ([uint32]$i) }
            }
            elseif (Test-IPv4Address $r) { $r }
            else { throw "Unrecognised range '$r'. Use CIDR (10.0.0.0/24), a single IPv4 address, or a-b range." }
        }
    }
}

function Test-TcpPort {
    <#
    .SYNOPSIS  Non-blocking TCP connect test with a timeout.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [string] $ComputerName,
        [Parameter(Mandatory)] [int] $Port,
        [int] $TimeoutMs = 400
    )
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $ar = $client.BeginConnect($ComputerName, $Port, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { return $false }
        $client.EndConnect($ar)
        return $client.Connected
    }
    catch { return $false }
    finally { $client.Close() }
}

function Resolve-HostName {
    <#
    .SYNOPSIS  Reverse DNS lookup that never throws; returns $null when unresolvable.
    #>
    param([Parameter(Mandatory)] [string] $IPAddress, [int] $TimeoutMs = 1500)
    try {
        $task = [System.Net.Dns]::GetHostEntryAsync($IPAddress)
        if ($task.Wait($TimeoutMs)) { return $task.Result.HostName }
    }
    catch { Write-Verbose "Reverse lookup of $IPAddress failed: $($_.Exception.InnerException.Message)" }
    return $null
}

function Resolve-IPv4Address {
    <#
    .SYNOPSIS  Forward DNS lookup that never throws; returns first IPv4 or $null. Passes IPs through.
    #>
    param([Parameter(Mandatory)] [string] $HostName, [int] $TimeoutMs = 1500)
    if (Test-IPv4Address $HostName) { return $HostName }
    try {
        $task = [System.Net.Dns]::GetHostAddressesAsync($HostName)
        if ($task.Wait($TimeoutMs)) {
            $v4 = $task.Result | Where-Object AddressFamily -eq 'InterNetwork' | Select-Object -First 1
            if ($v4) { return $v4.IPAddressToString }
        }
    }
    catch { Write-Verbose "Forward lookup of $HostName failed: $($_.Exception.InnerException.Message)" }
    return $null
}
