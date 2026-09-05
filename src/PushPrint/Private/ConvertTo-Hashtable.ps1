function ConvertTo-Hashtable {
    <#
    .SYNOPSIS
        Recursively converts PSCustomObjects (e.g. from ConvertFrom-Json) into ordered hashtables. Works on 5.1.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(ValueFromPipeline)] $InputObject)
    process {
        if ($null -eq $InputObject) { return $null }
        if ($InputObject -is [System.Collections.IDictionary]) {
            $out = [ordered]@{}
            foreach ($k in $InputObject.Keys) { $out[$k] = ConvertTo-Hashtable $InputObject[$k] }
            return $out
        }
        if ($InputObject -is [string] -or $InputObject.GetType().IsValueType) { return $InputObject }
        if ($InputObject -is [System.Collections.IEnumerable]) {
            # the leading comma keeps empty arrays as arrays instead of unrolling to $null
            return , [object[]]@(foreach ($i in $InputObject) { ConvertTo-Hashtable $i })
        }
        if ($InputObject -is [psobject]) {
            $out = [ordered]@{}
            foreach ($p in $InputObject.PSObject.Properties) { $out[$p.Name] = ConvertTo-Hashtable $p.Value }
            return $out
        }
        return $InputObject
    }
}

function Merge-Hashtable {
    <#
    .SYNOPSIS
        Deep-merges $Override into $Base (Base is not modified). Arrays are replaced, dictionaries merged.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Base,
        [System.Collections.IDictionary] $Override
    )
    $result = [ordered]@{}
    foreach ($k in $Base.Keys) { $result[$k] = $Base[$k] }
    if ($null -eq $Override) { return $result }
    foreach ($k in $Override.Keys) {
        if ($result.Contains($k) -and $result[$k] -is [System.Collections.IDictionary] -and $Override[$k] -is [System.Collections.IDictionary]) {
            $result[$k] = Merge-Hashtable -Base $result[$k] -Override $Override[$k]
        }
        else { $result[$k] = $Override[$k] }
    }
    return $result
}
