function Install-RemotePrinter {
    <#
    .SYNOPSIS
        Installs a network printer on one or more remote AD computers without WinRM or an agent.
    .DESCRIPTION
        Direct mode  : the vendor's universal driver is pushed (if missing) and installed as admin via WMI, a Standard
                       TCP/IP port is created and the printer is added machine-wide.
        Server mode  : a per-user Point-and-Print connection to \\PrintServer\Queue is created inside the console
                       user's own session (interactive scheduled task). Someone must be logged on. No driver copy.
        Transport    : SMB admin share (C$) for files + DCOM for execution. Needs TCP 445 and 135 + RPC on the target.
    .PARAMETER ComputerName
        One or more target computers. Accepts pipeline input. Each computer produces one result object.
    .PARAMETER PrinterName
        Direct mode: the local printer name to create. Server mode: the share name (or display name) of the queue.
    .PARAMETER PrinterIP
        IPv4 address of the printer (direct mode).
    .PARAMETER PrintServer
        Print server host name/IP, or a key from the printServers table in settings.json (server mode).
    .PARAMETER Vendor
        Key in the drivers table of settings.json (KM, HP, XEROX, ...). Selects the universal driver. Defaults to
        the first configured vendor.
    .PARAMETER DriverName
        Override the driver name from the config (must match the INF model name exactly).
    .PARAMETER Credential
        Local admin on the target. Prompted once (using adminUserPattern) when omitted.
    .EXAMPLE
        Install-RemotePrinter -ComputerName PC-1234 -PrinterName 'KM Office 2F' -PrinterIP 10.1.2.20 -Vendor KM -SetDefault
    .EXAMPLE
        'PC-1','PC-2' | Install-RemotePrinter -PrinterName HPM426HR -PrintServer Krakow -Credential $cred
    .EXAMPLE
        Get-PrinterCatalog | Where-Object site -eq 'KUJ' | Select-Object -First 1 | ForEach-Object { Install-RemotePrinter -ComputerName PC-9 -PrinterName $_.name -PrinterIP $_.ip -Vendor $_.vendor }
    #>
    [CmdletBinding(DefaultParameterSetName = 'Direct', SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName, Position = 0)]
        [string[]] $ComputerName,

        [Parameter(Mandatory, Position = 1)] [ValidateNotNullOrEmpty()] [string] $PrinterName,

        [Parameter(Mandatory, ParameterSetName = 'Direct')]
        [ValidateScript({ if ($_ -match '^\d{1,3}(\.\d{1,3}){3}$') { $true } else { throw "'$_' is not an IPv4 address" } })]
        [string] $PrinterIP,

        [Parameter(Mandatory, ParameterSetName = 'Server')] [string] $PrintServer,

        [string] $Vendor,
        [string] $DriverName,
        [string] $PortName,
        [ValidateSet('RAW', 'LPR')] [string] $Protocol = 'RAW',
        [string] $Location,
        [string] $Comment,
        [switch] $SetDefault,
        [switch] $TestPage,
        [switch] $SkipServerCheck,
        [pscredential] $Credential,
        [int] $TimeoutSec,
        [string] $ConfigPath
    )
    begin {
        $cfg = if ($ConfigPath) { Get-PushPrintConfig -Path $ConfigPath } else { Get-PushPrintConfig }
        if (-not $TimeoutSec) { $TimeoutSec = [int]$cfg.timeoutSec }
        $PrinterName = $PrinterName.Trim()
        if ($PrinterName -match '[\\,!]') { throw "Printer name contains characters Windows rejects (\ , !): '$PrinterName'" }
        if (-not $Credential) {
            $Credential = Get-Credential -UserName (Resolve-AdminUserName -Pattern $cfg.adminUserPattern) -Message 'Admin account for the target computers'
            if (-not $Credential) { throw 'No credential supplied.' }
        }
        $useServer = $PSCmdlet.ParameterSetName -eq 'Server'
        $driver = $null; $zip = $null
        if ($useServer) {
            $key = $cfg.printServers.Keys | Where-Object { $_ -ieq $PrintServer } | Select-Object -First 1
            if ($key) { $PrintServer = [string]$cfg.printServers[$key] }
            if (-not $SkipServerCheck) {
                $shared = @(Get-Printer -ComputerName $PrintServer -ErrorAction SilentlyContinue | Where-Object Shared)
                $q = $shared | Where-Object { $_.ShareName -eq $PrinterName } | Select-Object -First 1
                if (-not $q) { $q = $shared | Where-Object { $_.Name -eq $PrinterName } | Select-Object -First 1 }
                if (-not $q) {
                    if ($shared.Count -eq 0) { Write-PmLog -Level WARN "Could not enumerate shared queues on $PrintServer (no access?) - continuing without verification" }
                    else { throw "No shared queue '$PrinterName' on $PrintServer. Available: $(($shared.ShareName | Sort-Object) -join ', ')" }
                }
                elseif ($q.ShareName -ne $PrinterName) { $PrinterName = $q.ShareName; Write-PmLog "Using share name '$PrinterName'" }
            }
        }
        else {
            if (-not $Vendor) { $Vendor = [string]@($cfg.drivers.Keys)[0] }
            $driver = Resolve-PrinterDriver -Vendor $Vendor -Config $cfg
            if ($DriverName) { $driver.DriverName = $DriverName }
        }
    }
    process {
        foreach ($pc in $ComputerName) {
            $pc = $pc.Trim()
            if (-not $pc) { continue }
            $desc = if ($useServer) { "\\$PrintServer\$PrinterName" } else { "$PrinterName @ $PrinterIP ($($driver.Vendor))" }
            if (-not $PSCmdlet.ShouldProcess($pc, "Install $desc")) { continue }
            $result = [ordered]@{ ComputerName = $pc; PrinterName = $PrinterName; Mode = $PSCmdlet.ParameterSetName; Success = $false; Message = ''; Log = @() }
            try {
                Write-PmLog -Target $pc -Level STEP "Install $desc"
                if (-not (Test-Connection -ComputerName $pc -Count 1 -Quiet -ErrorAction SilentlyContinue)) { throw "$pc does not respond to ping." }

                if ($useServer) {
                    $params = @{ PrinterName = $PrinterName; PrintServer = $PrintServer; SetDefault = $SetDefault.IsPresent; TestPage = $TestPage.IsPresent }
                    $r = Invoke-RemoteWorker -ComputerName $pc -Credential $Credential -WorkerName 'Connect-Queue.worker.ps1' -Parameters $params -RunAs ConsoleUser -TimeoutSec $TimeoutSec -Config $cfg
                }
                else {
                    $files = @()
                    # Skip the (large) zip when the target already has the driver.
                    $hasDriver = $false
                    try {
                        $cim = New-RemoteCimSession -ComputerName $pc -Credential $Credential
                        try {
                            $filter = "Name LIKE '$($driver.DriverName.Replace("'", "''"))%'"
                            $hasDriver = [bool](Get-CimInstance -CimSession $cim -ClassName Win32_PrinterDriver -Filter $filter -ErrorAction Stop)
                        } finally { Remove-CimSession $cim }
                    }
                    catch { Write-PmLog -Target $pc -Level WARN "Could not query remote drivers ($($_.Exception.Message)) - sending the package anyway" }
                    if ($hasDriver) { Write-PmLog -Target $pc "Driver '$($driver.DriverName)' already on target" }
                    else { if (-not $zip) { $zip = Get-DriverPackage -Vendor $driver.Vendor -DriverRoot $cfg.driverRoot }; $files = @($zip) }

                    $params = @{
                        PrinterName = $PrinterName; PrinterIP = $PrinterIP; Vendor = $driver.Vendor; DriverName = $driver.DriverName
                        PortName = $PortName; Protocol = $Protocol; Location = $Location; Comment = $Comment
                        SetDefault = $SetDefault.IsPresent; TestPage = $TestPage.IsPresent
                    }
                    $r = Invoke-RemoteWorker -ComputerName $pc -Credential $Credential -WorkerName 'Install-Printer.worker.ps1' -Parameters $params -CopyFile $files -RunAs Admin -TimeoutSec $TimeoutSec -Config $cfg
                }
                $result.Log = $r.Log
                $result.Success = $r.Success
                $result.Message = if ($r.Success) { ($r.Results | Select-Object -First 1) } else { $r.Error }
                if (-not $r.Success) { Write-PmLog -Target $pc -Level ERROR "Install failed: $($r.Error)" }
            }
            catch {
                $result.Message = $_.Exception.Message
                Write-PmLog -Target $pc -Level ERROR $_.Exception.Message
            }
            [pscustomobject]$result
        }
    }
}
