<#
    Runs ON THE TARGET inside the console user's interactive session (scheduled task).
    Removes a per-user print server connection (\\server\queue).
#>
param([Parameter(Mandatory)] [string] $Dir)
$ErrorActionPreference = 'Stop'
$log = Join-Path $Dir 'result.log'
function Log($m) { "$(Get-Date -Format HH:mm:ss) $m" | Out-File -FilePath $log -Append -Encoding utf8 }
$exit = 0
try {
    $p = Get-Content -LiteralPath (Join-Path $Dir 'params.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $queue = [string]$p.PrinterName
    Log "Removing connection $queue as $env:USERDOMAIN\$env:USERNAME"
    Remove-Printer -Name $queue -ErrorAction Stop
    Log "RESULT removed $queue"
}
catch { Log "ERROR $($_.Exception.Message)"; $exit = 1 }
$exit | Out-File -FilePath (Join-Path $Dir 'done.txt') -Encoding ascii
exit $exit
