function Save-PrinterCatalog {
    <#
    .SYNOPSIS
        Writes catalog entries to JSON (v2 envelope). With -Merge, entries are merged into the existing file by IP
        (or by printServer\shareName for pull queues): discovered facts update the record, hand-edited names and
        notes are kept unless -OverwriteNames is given, and printers not seen this time stay in the file.
    .EXAMPLE
        Invoke-PrinterDiscovery -Site KUJ | Save-PrinterCatalog -Merge
    .EXAMPLE
        Get-PrinterCatalog | Where-Object site -ne 'OLD' | Save-PrinterCatalog -Path .\printers.json
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, ValueFromPipeline)] [AllowNull()] [object[]] $InputObject,
        [string] $Path,
        [switch] $Merge,
        [switch] $OverwriteNames,
        [string] $ConfigPath
    )
    begin {
        if (-not $Path) {
            $cfg = if ($ConfigPath) { Get-PushPrintConfig -Path $ConfigPath } else { Get-PushPrintConfig }
            $Path = $cfg.catalogPath
        }
        $incoming = New-Object System.Collections.Generic.List[object]
    }
    process { foreach ($i in $InputObject) { if ($i) { $incoming.Add($i) } } }
    end {
        $keyOf = { param($e) Get-CatalogKey $e }
        $final = [ordered]@{}
        if ($Merge -and (Test-Path -LiteralPath $Path)) {
            foreach ($e in (Get-PrinterCatalog -Path $Path)) { $final[(& $keyOf $e)] = $e }
        }
        foreach ($n in $incoming) {
            $k = & $keyOf $n
            if ($final.Contains($k)) {
                $old = $final[$k]
                foreach ($p in $n.PSObject.Properties) {
                    $v = $p.Value
                    if ($null -eq $v -or ($v -is [array] -and $v.Count -eq 0) -or $v -eq '') { continue }
                    $hasOld = Test-HasProperty $old $p.Name
                    if ($p.Name -in 'name', 'note' -and -not $OverwriteNames -and $hasOld -and (Get-PropertyValue $old $p.Name)) { continue }
                    if ($hasOld) { $old.PSObject.Properties[$p.Name].Value = $v } else { $old | Add-Member -NotePropertyName $p.Name -NotePropertyValue $v }
                }
                $final[$k] = $old
            }
            else { $final[$k] = $n }
        }
        $list = @($final.Values | Sort-Object { "$(Get-PropertyValue $_ 'site')" }, { "$(Get-PropertyValue $_ 'name')" })
        $doc = [ordered]@{ version = 2; generated = (Get-Date).ToString('s'); count = $list.Count; printers = $list }
        if ($PSCmdlet.ShouldProcess($Path, "Write $($list.Count) printers")) {
            $dir = Split-Path -Parent $Path
            if ($dir -and -not (Test-Path -LiteralPath $dir)) { $null = New-Item -Path $dir -ItemType Directory -Force }
            $jsonText = $doc | ConvertTo-Json -Depth 6
            [System.IO.File]::WriteAllText($Path, $jsonText, (New-Object System.Text.UTF8Encoding $false))
            Write-PmLog "Catalog saved: $($list.Count) printers -> $Path"
        }
    }
}
