# Agentless transport: SMB admin share (C$) for files + WMI/DCOM (Win32_Process / Scheduled Tasks) for execution.
# Requirements on the target: TCP 445 and TCP 135 + dynamic RPC reachable; the credential is a local admin there.
# No WinRM, no agent. The credential's password never touches a command line (New-SmbMapping takes it as a parameter).

function Connect-AdminShare {
    <#
    .SYNOPSIS  Authenticates an SMB session to \\Computer\C$ and returns a disposable handle object.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ComputerName,
        [Parameter(Mandatory)] [pscredential] $Credential
    )
    $remote = "\\$ComputerName\C$"
    $created = $false
    if (-not (Test-Path -LiteralPath $remote -ErrorAction SilentlyContinue)) {
        try {
            $null = New-SmbMapping -RemotePath $remote -UserName $Credential.UserName -Password $Credential.GetNetworkCredential().Password -Persistent:$false -ErrorAction Stop
            $created = $true
        }
        catch {
            # 1219: a session with different credentials already exists for this server. Fall through to Test-Path.
            if ($_.Exception.Message -notmatch '1219|Multiple connections|Wiele po') { throw "Cannot open $remote as $($Credential.UserName): $($_.Exception.Message)" }
        }
        if (-not (Test-Path -LiteralPath $remote -ErrorAction SilentlyContinue)) { throw "$remote is not accessible (admin share disabled, firewall, or credential lacks local admin)." }
    }
    return [pscustomobject]@{ ComputerName = $ComputerName; RemotePath = $remote; Created = $created }
}

function Disconnect-AdminShare {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Share)
    if ($Share.Created) {
        Remove-SmbMapping -RemotePath $Share.RemotePath -Force -UpdateProfile:$false -ErrorAction SilentlyContinue
    }
}

function New-RemoteCimSession {
    <#
    .SYNOPSIS  DCOM CIM session (works where WinRM is disabled).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ComputerName,
        [Parameter(Mandatory)] [pscredential] $Credential
    )
    $opt = New-CimSessionOption -Protocol Dcom
    return New-CimSession -ComputerName $ComputerName -Credential $Credential -SessionOption $opt -ErrorAction Stop
}

function Get-ConsoleUser {
    <#
    .SYNOPSIS  Returns DOMAIN\user logged on at the console (or $null) plus their SID.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [Microsoft.Management.Infrastructure.CimSession] $CimSession)
    $user = (Get-CimInstance -CimSession $CimSession -ClassName Win32_ComputerSystem -ErrorAction Stop).UserName
    if (-not $user) { return $null }
    $sid = $null
    try { $sid = (New-Object System.Security.Principal.NTAccount($user)).Translate([System.Security.Principal.SecurityIdentifier]).Value }
    catch { Write-Verbose "Cannot translate '$user' to a SID: $($_.Exception.Message)" }
    return [pscustomobject]@{ UserName = $user; Sid = $sid }
}

function ConvertTo-AdminSharePath {
    <#
    .SYNOPSIS  "C:\Temp\X" on PC -> "\\PC\C$\Temp\X"
    #>
    param([Parameter(Mandatory)] [string] $ComputerName, [Parameter(Mandatory)] [string] $LocalPath)
    if ($LocalPath -notmatch '^([A-Za-z]):\\(.*)$') { throw "remoteTempDir must be an absolute local path like C:\Temp\PushPrint (got '$LocalPath')" }
    return "\\$ComputerName\$($Matches[1])`$\$($Matches[2])"
}

function Invoke-RemoteWorker {
    <#
    .SYNOPSIS
        Stages a worker script + params.json (+ optional files) on the target over C$ and runs it either as the
        supplied admin credential (Win32_Process.Create) or inside the console user's interactive session
        (scheduled task, needed for per-user print server connections). Waits for done.txt, returns the log.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ComputerName,
        [Parameter(Mandatory)] [pscredential] $Credential,
        [Parameter(Mandatory)] [string] $WorkerName,
        [hashtable] $Parameters = @{},
        [string[]] $CopyFile = @(),
        [ValidateSet('Admin', 'ConsoleUser')] [string] $RunAs = 'Admin',
        [int] $TimeoutSec = 600,
        $Config = (Get-PushPrintConfig)
    )
    $workerPath = Join-Path $script:WorkerRoot $WorkerName
    if (-not (Test-Path -LiteralPath $workerPath)) { throw "Worker script not found: $workerPath" }
    $remoteDir = [string]$Config.remoteTempDir
    $unc = ConvertTo-AdminSharePath -ComputerName $ComputerName -LocalPath $remoteDir
    $taskName = "PushPrint-$([IO.Path]::GetFileNameWithoutExtension($WorkerName))"
    $log = New-Object System.Collections.Generic.List[string]
    $exit = -1

    $share = Connect-AdminShare -ComputerName $ComputerName -Credential $Credential
    $cim = $null
    try {
        # --- stage ---
        Remove-Item -LiteralPath $unc -Recurse -Force -ErrorAction SilentlyContinue
        $null = New-Item -Path $unc -ItemType Directory -Force
        Copy-Item -LiteralPath $workerPath -Destination (Join-Path $unc 'worker.ps1') -Force
        # Parameters travel as UTF-8 JSON, never on the command line: survives diacritics, spaces and quotes.
        $Parameters | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $unc 'params.json') -Encoding UTF8
        foreach ($f in $CopyFile) {
            Write-PmLog -Target $ComputerName "Copying $([IO.Path]::GetFileName($f)) ($([math]::Round((Get-Item -LiteralPath $f).Length / 1MB)) MB)"
            Copy-Item -LiteralPath $f -Destination $unc -Force
        }
        $cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$remoteDir\worker.ps1`" -Dir `"$remoteDir`""

        # --- execute ---
        $cim = New-RemoteCimSession -ComputerName $ComputerName -Credential $Credential
        if ($RunAs -eq 'ConsoleUser') {
            $console = Get-ConsoleUser -CimSession $cim
            if (-not $console) { throw "Nobody is logged on at the console of $ComputerName. This action must run in the user's own session." }
            # VBS launcher = no console window flashing on the user's screen.
            $vbs = 'CreateObject("WScript.Shell").Run "' + $cmd.Replace('"', '""') + '", 0, False'
            Set-Content -LiteralPath (Join-Path $unc 'run.vbs') -Value $vbs -Encoding ASCII
            Write-PmLog -Target $ComputerName "Running $WorkerName in the session of $($console.UserName)"
            $action    = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "//B //Nologo `"$remoteDir\run.vbs`""
            $principal = New-ScheduledTaskPrincipal -UserId $console.UserName -LogonType Interactive
            $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Seconds ([Math]::Max(60, $TimeoutSec)))
            Unregister-ScheduledTask -CimSession $cim -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
            $null = Register-ScheduledTask -CimSession $cim -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Force
            Start-ScheduledTask -CimSession $cim -TaskName $taskName
        }
        else {
            Write-PmLog -Target $ComputerName "Running $WorkerName as $($Credential.UserName)"
            $r = Invoke-CimMethod -CimSession $cim -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $cmd }
            if ($r.ReturnValue -ne 0) { throw "Win32_Process.Create returned $($r.ReturnValue) on $ComputerName" }
        }

        # --- wait ---
        $doneFile = Join-Path $unc 'done.txt'; $logFile = Join-Path $unc 'result.log'
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $seen = 0
        while (-not (Test-Path -LiteralPath $doneFile)) {
            if ($sw.Elapsed.TotalSeconds -gt $TimeoutSec) {
                $partial = Get-Content -LiteralPath $logFile -ErrorAction SilentlyContinue
                throw "Timed out after $TimeoutSec s waiting for $WorkerName on $ComputerName.`n$($partial -join "`n")"
            }
            Start-Sleep -Seconds 2
            # stream new log lines while waiting
            $lines = @(Get-Content -LiteralPath $logFile -ErrorAction SilentlyContinue)
            for ($i = $seen; $i -lt $lines.Count; $i++) { Write-RemoteLogLine $ComputerName $lines[$i]; $log.Add($lines[$i]) }
            $seen = $lines.Count
        }
        Start-Sleep -Milliseconds 300
        $lines = @(Get-Content -LiteralPath $logFile -ErrorAction SilentlyContinue)
        for ($i = $seen; $i -lt $lines.Count; $i++) { Write-RemoteLogLine $ComputerName $lines[$i]; $log.Add($lines[$i]) }
        $exit = [int](Get-Content -LiteralPath $doneFile -ErrorAction SilentlyContinue | Select-Object -First 1)
    }
    finally {
        if ($cim) {
            if ($RunAs -eq 'ConsoleUser') { Unregister-ScheduledTask -CimSession $cim -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue }
            Remove-CimSession $cim -ErrorAction SilentlyContinue
        }
        Remove-Item -LiteralPath $unc -Recurse -Force -ErrorAction SilentlyContinue
        Disconnect-AdminShare $share
    }
    return [pscustomobject]@{
        ComputerName = $ComputerName
        Worker       = $WorkerName
        ExitCode     = $exit
        Success      = ($exit -eq 0)
        Log          = $log.ToArray()
        Results      = @($log | Where-Object { $_ -match '\bRESULT\b' } | ForEach-Object { ($_ -replace '^\S+\s+RESULT\s*', '') })
        Error        = ($log | Where-Object { $_ -match '\bERROR\b' } | Select-Object -Last 1)
    }
}

function Write-RemoteLogLine {
    param([string] $ComputerName, [string] $Line)
    $level = if ($Line -match '\bERROR\b') { 'ERROR' } elseif ($Line -match '\bWARN\b') { 'WARN' } elseif ($Line -match '\bRESULT\b') { 'RESULT' } else { 'INFO' }
    $text = $Line -replace '^\d{2}:\d{2}:\d{2}\s+(ERROR|WARN|RESULT)?\s*', ''
    Write-PmLog -Target $ComputerName -Level $level $text
}
