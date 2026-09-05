function Get-PropertyValue {
    <#
    .SYNOPSIS  Strict-mode-safe property read: $null when the object or property does not exist.
    #>
    param([AllowNull()] $InputObject, [Parameter(Mandatory)] [string] $Name)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) { if ($InputObject.Contains($Name)) { return $InputObject[$Name] } else { return $null } }
    $match = $InputObject.PSObject.Properties.Match($Name)
    if ($match.Count -gt 0) { return $match[0].Value }
    return $null
}

function Test-HasProperty {
    param([AllowNull()] $InputObject, [Parameter(Mandatory)] [string] $Name)
    if ($null -eq $InputObject) { return $false }
    if ($InputObject -is [System.Collections.IDictionary]) { return $InputObject.Contains($Name) }
    return ($InputObject.PSObject.Properties.Match($Name).Count -gt 0)
}

function Get-LdapValue {
    <#
    .SYNOPSIS  First value of an LDAP attribute from a SearchResult, or '' when absent.
    #>
    param([Parameter(Mandatory)] $SearchResult, [Parameter(Mandatory)] [string] $Attribute)
    try {
        $col = $SearchResult.Properties[$Attribute]
        if ($col -and $col.Count -gt 0) { return [string]$col[0] }
    }
    catch { Write-Verbose "LDAP attribute '$Attribute' unreadable: $($_.Exception.Message)" }
    return ''
}
