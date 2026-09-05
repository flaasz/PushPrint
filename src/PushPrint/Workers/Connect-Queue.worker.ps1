<#
    Runs ON THE TARGET inside the console user's interactive session (scheduled task).
    Adds a per-user connection to \\PrintServer\Queue exactly as if the user double-clicked the queue
    (Point and Print delivers the driver). Optionally sets default / prints a test page.
#>
param([Parameter(Mandatory)] [string] $Dir)
$ErrorActionPreference = 'Continue'
$log = Join-Path $Dir 'result.log'
function Log($m) { "$(Get-Date -Format HH:mm:ss) $m" | Out-File -FilePath $log -Append -Encoding utf8 }
$exit = 0
try {
    $p = Get-Content -LiteralPath (Join-Path $Dir 'params.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $queue = "\\$($p.PrintServer)\$($p.PrinterName)"
    Log "Connecting $queue as $env:USERDOMAIN\$env:USERNAME"
    Add-Printer -ConnectionName $queue -ErrorAction Stop
    $deadline = (Get-Date).AddSeconds(90)
    do {
        $pr = Get-Printer -Name $queue -ErrorAction SilentlyContinue
        if (-not $pr) { Start-Sleep -Seconds 3 }
    } while (-not $pr -and (Get-Date) -lt $deadline)
    if (-not $pr) { throw "Connection not visible after 90 s. Point and Print driver download may have been blocked (RestrictDriverInstallationToAdministrators) or is waiting for a prompt." }
    if ([bool]$p.SetDefault) { (New-Object -ComObject WScript.Network).SetDefaultPrinter($queue); Log "Set as default" }
    if ([bool]$p.TestPage) { "PushPrint test page - $env:COMPUTERNAME - $queue - $(Get-Date -Format 'yyyy-MM-dd HH:mm')" | Out-Printer -Name $queue; Log "Test page sent" }
    Log "RESULT $($pr.Name) | $($pr.DriverName) | $($pr.PrinterStatus)"
}
catch { Log "ERROR $($_.Exception.Message)"; $exit = 1 }
$exit | Out-File -FilePath (Join-Path $Dir 'done.txt') -Encoding ascii
exit $exit
