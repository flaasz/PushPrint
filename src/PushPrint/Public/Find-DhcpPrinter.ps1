function Find-DhcpPrinter {
    <#
    .SYNOPSIS
        Finds printer candidates in DHCP leases and reservations by MAC vendor prefix. Fast, no network scanning.
    .DESCRIPTION
        Requires the DhcpServer RSAT module and read rights on the DHCP servers. Servers default to
        discovery.dhcpServers in settings.json, then to the servers authorised in AD (Get-DhcpServerInDC).
    .PARAMETER Subnet
        Only return addresses inside these CIDR subnets (e.g. the subnets of one AD site).
    .PARAMETER IncludeUnknownVendor
        Return every lease, not just MACs matching a configured printer vendor.
    .EXAMPLE
        Find-DhcpPrinter -Subnet (Get-AdSiteSubnet -Site KUJ).Subnet
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string[]] $DhcpServer,
        [string[]] $Subnet,
        [switch] $IncludeUnknownVendor,
        [string] $ConfigPath
    )
    $cfg = if ($ConfigPath) { Get-PushPrintConfig -Path $ConfigPath } else { Get-PushPrintConfig }
    if (-not (Get-Module -ListAvailable DhcpServer)) {
        throw 'The DhcpServer module is not installed. Add the RSAT feature "DHCP Server Tools" (Add-WindowsCapability -Online -Name Rsat.DHCP.Tools~~~~0.0.1.0).'
    }
    Import-Module DhcpServer -ErrorAction Stop
    if (-not $DhcpServer) { $DhcpServer = @($cfg.discovery.dhcpServers) }
    if (-not $DhcpServer) {
        try { $DhcpServer = @((Get-DhcpServerInDC -ErrorAction Stop).DnsName) } catch { throw "No DHCP servers configured and Get-DhcpServerInDC failed: $($_.Exception.Message)" }
    }
    foreach ($srv in $DhcpServer) {
        Write-PmLog -Target $srv 'Reading DHCP scopes'
        try { $scopes = @(Get-DhcpServerv4Scope -ComputerName $srv -ErrorAction Stop) }
        catch { Write-Error -Message "$srv : $($_.Exception.Message)" -TargetObject $srv; continue }
        foreach ($scope in $scopes) {
            if ($Subnet) {
                # skip scopes that do not overlap any requested subnet
                $scopeCidr = "$($scope.ScopeId)/$((ConvertTo-UInt32Address $scope.SubnetMask).ToString(2).TrimEnd('0').Length)"
                $overlaps = $false
                foreach ($s in $Subnet) {
                    if ((Test-IPInSubnet -Cidr $s -IPAddress "$($scope.ScopeId)") -or (Test-IPInSubnet -Cidr $scopeCidr -IPAddress ($s -split '/')[0])) { $overlaps = $true; break }
                }
                if (-not $overlaps) { continue }
            }
            $entries = @()
            $entries += Get-DhcpServerv4Reservation -ComputerName $srv -ScopeId $scope.ScopeId -ErrorAction SilentlyContinue | ForEach-Object {
                [pscustomobject]@{ IP = "$($_.IPAddress)"; Mac = $_.ClientId; Host = $_.Name; Type = 'Reservation'; Description = $_.Description }
            }
            $entries += Get-DhcpServerv4Lease -ComputerName $srv -ScopeId $scope.ScopeId -AllLeases -ErrorAction SilentlyContinue | ForEach-Object {
                [pscustomobject]@{ IP = "$($_.IPAddress)"; Mac = $_.ClientId; Host = $_.HostName; Type = "Lease/$($_.AddressState)"; Description = $_.Description }
            }
            $seen = @{}
            foreach ($e in $entries) {
                if ($seen.ContainsKey($e.IP)) { continue }
                if ($Subnet -and -not ($Subnet | Where-Object { Test-IPInSubnet -Cidr $_ -IPAddress $e.IP })) { continue }
                $vendor = Get-VendorMatch -Drivers $cfg.drivers -Mac $e.Mac
                if (-not $vendor -and -not $IncludeUnknownVendor) { continue }
                $seen[$e.IP] = $true
                [pscustomobject]@{
                    IPAddress   = $e.IP
                    MacAddress  = ConvertTo-NormalizedMac $e.Mac
                    HostName    = $e.Host
                    Vendor      = $vendor
                    Type        = $e.Type
                    Description = $e.Description
                    Scope       = "$($scope.ScopeId)"
                    ScopeName   = $scope.Name
                    DhcpServer  = $srv
                    Source      = 'DHCP'
                }
            }
        }
    }
}
