function Get-DriverPackage {
    <#
    .SYNOPSIS
        Returns the path of <driverRoot>\<Vendor>.zip, (re)building it from <driverRoot>\<Vendor>\ when the folder is newer.
        The folder holds the extracted vendor driver package (INF, CAT, DLLs). The zip is what gets copied to targets.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $Vendor,
        [string] $DriverRoot = (Get-PushPrintConfig).driverRoot
    )
    $folder = Join-Path $DriverRoot $Vendor
    $zip    = "$folder.zip"
    if (Test-Path -LiteralPath $folder -PathType Container) {
        $files = @(Get-ChildItem -LiteralPath $folder -Recurse -File)
        if (-not $files) { throw "Driver folder '$folder' is empty. Extract the vendor package (INF + CAT + DLLs) into it." }
        $newest = ($files | Measure-Object LastWriteTime -Maximum).Maximum
        if (-not (Test-Path -LiteralPath $zip) -or (Get-Item -LiteralPath $zip).LastWriteTime -lt $newest) {
            Write-PmLog "Packaging $Vendor driver ($($files.Count) files) -> $zip"
            Compress-Archive -Path (Join-Path $folder '*') -DestinationPath $zip -CompressionLevel Optimal -Force
        }
    }
    if (-not (Test-Path -LiteralPath $zip)) {
        throw "No driver package for '$Vendor'. Expected '$zip' or a folder '$folder' containing the extracted driver (see docs/drivers.md)."
    }
    return $zip
}
