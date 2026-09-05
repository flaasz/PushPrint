Set-StrictMode -Version 2.0

$script:ModuleRoot  = $PSScriptRoot
$script:WorkerRoot  = Join-Path $PSScriptRoot 'Workers'
$script:ConfigCache = $null

foreach ($folder in 'Private', 'Public') {
    Get-ChildItem -Path (Join-Path $PSScriptRoot $folder) -Filter '*.ps1' -File | Sort-Object Name | ForEach-Object {
        . $_.FullName
    }
}

Export-ModuleMember -Function (Get-ChildItem -Path (Join-Path $PSScriptRoot 'Public') -Filter '*.ps1' -File).BaseName
