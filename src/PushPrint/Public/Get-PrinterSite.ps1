function Get-PrinterSite {
    <#
    .SYNOPSIS
        Maps IP addresses to the AD site whose subnet contains them (longest prefix wins).
    .EXAMPLE
        Get-PrinterCatalog | Get-PrinterSite | Group-Object Site
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)] [Alias('ip', 'HostAddress')] [string[]] $IPAddress,
        [object[]] $SubnetTable,
        [string] $ConfigPath
    )
    begin {
        if (-not $SubnetTable) { $SubnetTable = @(Get-AdSiteSubnet -ConfigPath $ConfigPath -ErrorAction Stop) }
        $table = $SubnetTable | ForEach-Object {
            if ($_.Subnet -match '/(\d+)$') { [pscustomobject]@{ Site = $_.Site; Subnet = $_.Subnet; Bits = [int]$Matches[1] } }
        } | Sort-Object Bits -Descending
    }
    process {
        foreach ($ip in $IPAddress) {
            $hit = $table | Where-Object { Test-IPInSubnet -Cidr $_.Subnet -IPAddress $ip } | Select-Object -First 1
            [pscustomobject]@{ IPAddress = $ip; Site = if ($hit) { $hit.Site } else { $null }; Subnet = if ($hit) { $hit.Subnet } else { $null } }
        }
    }
}
