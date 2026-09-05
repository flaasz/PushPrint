function Invoke-Parallel {
    <#
    .SYNOPSIS
        Runs a script block against many inputs on a runspace pool. Works on Windows PowerShell 5.1 and 7+.
        Each runspace imports this module and the block executes inside the module scope, so private helpers
        (SNMP, TCP probe, config) are available.
    .PARAMETER ScriptBlock
        Must declare param($Item, $Params). $Item is the current input, $Params is -ArgumentList.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $InputObject,
        [Parameter(Mandatory)] [scriptblock] $ScriptBlock,
        [hashtable] $ArgumentList = @{},
        [ValidateRange(1, 256)] [int] $ThrottleLimit = 32,
        [string] $Activity
    )
    if (-not $InputObject -or $InputObject.Count -eq 0) { return }

    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $iss.ImportPSModule((Join-Path $script:ModuleRoot 'PushPrint.psd1'))
    $pool = [runspacefactory]::CreateRunspacePool(1, $ThrottleLimit, $iss, $Host)
    $pool.Open()

    $wrapper = {
        param($Item, $Params, $Text)
        $body = [scriptblock]::Create($Text)
        & (Get-Module PushPrint) $body $Item $Params
    }
    $text = $ScriptBlock.ToString()
    $jobs = New-Object System.Collections.Generic.List[object]
    try {
        foreach ($item in $InputObject) {
            $ps = [powershell]::Create()
            $ps.RunspacePool = $pool
            [void]$ps.AddScript($wrapper.ToString()).AddArgument($item).AddArgument($ArgumentList).AddArgument($text)
            $jobs.Add([pscustomobject]@{ PS = $ps; Handle = $ps.BeginInvoke(); Item = $item })
        }
        $total = $jobs.Count; $done = 0
        foreach ($j in $jobs) {
            try {
                $out = $j.PS.EndInvoke($j.Handle)
                foreach ($o in $out) { if ($null -ne $o) { Write-Output $o } }
                foreach ($e in $j.PS.Streams.Error) { Write-Verbose "Parallel item '$($j.Item)': $($e.Exception.Message)" }
            }
            catch { Write-Verbose "Parallel item '$($j.Item)' failed: $($_.Exception.Message)" }
            finally { $j.PS.Dispose() }
            $done++
            if ($Activity) { Write-Progress -Activity $Activity -Status "$done / $total" -PercentComplete ([int](100 * $done / $total)) }
        }
    }
    finally {
        if ($Activity) { Write-Progress -Activity $Activity -Completed }
        $pool.Close(); $pool.Dispose()
    }
}
