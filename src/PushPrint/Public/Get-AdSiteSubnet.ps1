function Get-AdSiteSubnet {
    <#
    .SYNOPSIS
        Returns the subnet -> site mapping from Active Directory Sites and Services (ADSI, no RSAT needed),
        merged with the optional "sites" table in settings.json. This is the zone boundary for discovery.
    .PARAMETER Site
        Only subnets of these sites (wildcards allowed).
    .PARAMETER Server
        Domain controller to query. Defaults to the current domain.
    .PARAMETER NoActiveDirectory
        Skip the AD query; use only the config table (handy off-domain or in tests).
    .EXAMPLE
        Get-AdSiteSubnet | Group-Object Site | Sort-Object Count -Descending
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string[]] $Site,
        [string] $Server,
        [switch] $NoActiveDirectory,
        [string] $ConfigPath
    )
    $cfg = if ($ConfigPath) { Get-PushPrintConfig -Path $ConfigPath } else { Get-PushPrintConfig }
    $results = New-Object System.Collections.Generic.List[object]

    if (-not $NoActiveDirectory) {
        try {
            $rootPath = if ($Server) { "LDAP://$Server/RootDSE" } else { 'LDAP://RootDSE' }
            $root = [ADSI]$rootPath
            $cfgNc = [string]$root.Properties['configurationNamingContext'].Value
            if (-not $cfgNc) { throw 'RootDSE returned no configurationNamingContext' }
            $base = if ($Server) { "LDAP://$Server/CN=Subnets,CN=Sites,$cfgNc" } else { "LDAP://CN=Subnets,CN=Sites,$cfgNc" }
            $ds = New-Object System.DirectoryServices.DirectorySearcher([ADSI]$base)
            $ds.Filter = '(objectClass=subnet)'
            $ds.PageSize = 1000
            foreach ($p in 'cn', 'siteObject', 'location', 'description') { [void]$ds.PropertiesToLoad.Add($p) }
            foreach ($r in $ds.FindAll()) {
                $cn = Get-LdapValue $r 'cn'
                $siteDn = Get-LdapValue $r 'siteobject'
                $siteName = if ($siteDn -match '^CN=([^,]+)') { $Matches[1] } else { '(unassigned)' }
                $results.Add([pscustomobject]@{
                    Site        = $siteName
                    Subnet      = $cn
                    Location    = Get-LdapValue $r 'location'
                    Description = Get-LdapValue $r 'description'
                    Source      = 'AD'
                })
            }
        }
        catch {
            if ($cfg.sites.Count -eq 0) { throw "Active Directory Sites and Services query failed ($($_.Exception.Message)). Off-domain? Define 'sites' in settings.json or pass -NoActiveDirectory." }
            Write-Verbose "AD subnet query failed: $($_.Exception.Message). Using config sites only."
        }
    }
    foreach ($s in $cfg.sites.Keys) {
        foreach ($subnet in @($cfg.sites[$s])) {
            if ($results | Where-Object { $_.Subnet -eq $subnet }) { continue }
            $results.Add([pscustomobject]@{ Site = $s; Subnet = $subnet; Location = ''; Description = 'settings.json'; Source = 'Config' })
        }
    }
    $out = $results | Where-Object { $_.Subnet -match '/' }
    if ($Site) { $out = $out | Where-Object { $s = $_.Site; @($Site | Where-Object { $s -like $_ }).Count -gt 0 } }
    $out | Sort-Object Site, Subnet
}
