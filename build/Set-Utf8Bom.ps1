<#
.SYNOPSIS
    Ensures every PowerShell source file has a UTF-8 BOM. Windows PowerShell 5.1 reads BOM-less files as ANSI,
    which corrupts any non-ASCII character (e.g. in comments or the author name). Run after editing with tools
    that strip the BOM. Idempotent.
#>
[CmdletBinding()]
param([string] $Root = (Split-Path -Parent $PSScriptRoot))
$bom = [byte[]](0xEF, 0xBB, 0xBF)
$changed = 0
Get-ChildItem -Path $Root -Recurse -Include *.ps1, *.psm1, *.psd1 -File | Where-Object { $_.FullName -notmatch '\\(out|\.git)\\' } | ForEach-Object {
    $bytes = [IO.File]::ReadAllBytes($_.FullName)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { return }
    [IO.File]::WriteAllBytes($_.FullName, $bom + $bytes)
    $changed++
    Write-Verbose "BOM added: $($_.FullName)"
}
Write-Host "UTF-8 BOM: $changed file(s) updated"
