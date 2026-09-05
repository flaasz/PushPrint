function Remove-RemotePrinter {
    <#
    .SYNOPSIS
        Removes a printer from a remote computer.
        Machine printers go through Win32_Printer (and the IP_ port is deleted when nothing else uses it);
        per-user print server connections are removed inside the console user's session.
    .EXAMPLE
        Remove-RemotePrinter -ComputerName PC-1234 -PrinterName 'KM Office 2F' -Credential $cred
    .EXAMPLE
        Remove-RemotePrinter -ComputerName PC-1234 -PrinterName '\\print01\HPM426HR' -Kind User -Credential $cred
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ValueFromPipelineByPropertyName, Position = 0)] [string] $ComputerName,
        [Parameter(Mandatory, ValueFromPipelineByPropertyName, Position = 1)] [Alias('Name')] [string] $PrinterName,
        [Parameter(ValueFromPipelineByPropertyName)] [ValidateSet('Machine', 'User', 'Connection')] [string] $Kind = 'Machine',
        [pscredential] $Credential,
        [int] $TimeoutSec = 120,
        [string] $ConfigPath
    )
    begin {
        $cfg = if ($ConfigPath) { Get-PushPrintConfig -Path $ConfigPath } else { Get-PushPrintConfig }
        if (-not $Credential) {
            $Credential = Get-Credential -UserName (Resolve-AdminUserName -Pattern $cfg.adminUserPattern) -Message 'Admin account for the target computer'
            if (-not $Credential) { throw 'No credential supplied.' }
        }
    }
    process {
        if (-not $PSCmdlet.ShouldProcess($ComputerName, "Remove printer '$PrinterName' ($Kind)")) { return }
        $result = [ordered]@{ ComputerName = $ComputerName; PrinterName = $PrinterName; Kind = $Kind; Success = $false; Message = '' }
        try {
            if ($Kind -eq 'User') {
                $r = Invoke-RemoteWorker -ComputerName $ComputerName -Credential $Credential -WorkerName 'Remove-Connection.worker.ps1' -Parameters @{ PrinterName = $PrinterName } -RunAs ConsoleUser -TimeoutSec $TimeoutSec -Config $cfg
                $result.Success = $r.Success
                $result.Message = if ($r.Success) { "Removed $PrinterName" } else { $r.Error }
            }
            else {
                $cim = New-RemoteCimSession -ComputerName $ComputerName -Credential $Credential
                try {
                    $filter = "Name = '$($PrinterName.Replace("'", "''"))'"
                    $pr = Get-CimInstance -CimSession $cim -ClassName Win32_Printer -Filter $filter
                    if (-not $pr) { throw "Printer '$PrinterName' not found on $ComputerName" }
                    $port = $pr.PortName
                    Write-PmLog -Target $ComputerName "Removing printer '$PrinterName'"
                    $pr | Remove-CimInstance
                    if ($port -like 'IP_*') {
                        $others = Get-CimInstance -CimSession $cim -ClassName Win32_Printer -Filter "PortName = '$port'"
                        if (-not $others) {
                            $removed = $false
                            foreach ($try in 1..3) {
                                Start-Sleep -Seconds 2   # the spooler can hold the port briefly after the printer goes
                                try {
                                    $p = Get-CimInstance -CimSession $cim -ClassName Win32_TCPIPPrinterPort -Filter "Name = '$port'"
                                    if (-not $p) { $removed = $true; break }
                                    $p | Remove-CimInstance -ErrorAction Stop; $removed = $true
                                    Write-PmLog -Target $ComputerName "Removed unused port $port"; break
                                }
                                catch { Write-Verbose "Port removal attempt $try failed: $($_.Exception.Message)" }
                            }
                            if (-not $removed) { Write-PmLog -Target $ComputerName -Level WARN "Port $port could not be deleted (left in place, harmless)" }
                        }
                    }
                    $result.Success = $true; $result.Message = "Removed $PrinterName"
                    Write-PmLog -Target $ComputerName -Level RESULT "removed $PrinterName"
                }
                finally { Remove-CimSession $cim -ErrorAction SilentlyContinue }
            }
        }
        catch {
            $result.Message = $_.Exception.Message
            Write-PmLog -Target $ComputerName -Level ERROR $_.Exception.Message
        }
        [pscustomobject]$result
    }
}
