function Get-RemotePrinter {
    <#
    .SYNOPSIS
        Lists printers on remote computers: machine-wide printers (Win32_Printer, with port host address) and the
        console user's own print server connections (HKU\<sid>\Printers\Connections via StdRegProv). DCOM only.
    .EXAMPLE
        Get-RemotePrinter -ComputerName PC-1234 -Credential $cred | Format-Table
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName, Position = 0)] [string[]] $ComputerName,
        [pscredential] $Credential,
        [string] $ConfigPath
    )
    begin {
        $cfg = if ($ConfigPath) { Get-PushPrintConfig -Path $ConfigPath } else { Get-PushPrintConfig }
        if (-not $Credential) {
            $Credential = Get-Credential -UserName (Resolve-AdminUserName -Pattern $cfg.adminUserPattern) -Message 'Admin account for the target computers'
            if (-not $Credential) { throw 'No credential supplied.' }
        }
        $HKU = [uint32]2147483651
    }
    process {
        foreach ($pc in $ComputerName) {
            $pc = $pc.Trim(); if (-not $pc) { continue }
            $cim = $null
            try {
                $cim = New-RemoteCimSession -ComputerName $pc -Credential $Credential
                $console = Get-ConsoleUser -CimSession $cim
                $ports = @{}
                Get-CimInstance -CimSession $cim -ClassName Win32_TCPIPPrinterPort -ErrorAction SilentlyContinue | ForEach-Object { $ports[$_.Name] = $_.HostAddress }
                foreach ($pr in (Get-CimInstance -CimSession $cim -ClassName Win32_Printer -ErrorAction Stop)) {
                    [pscustomobject]@{
                        ComputerName = $pc
                        Name         = $pr.Name
                        Kind         = if ($pr.Network) { 'Connection' } else { 'Machine' }
                        Port         = $pr.PortName
                        HostAddress  = $ports[$pr.PortName]
                        Driver       = $pr.DriverName
                        Default      = [bool]$pr.Default
                        Shared       = [bool]$pr.Shared
                        Status       = $pr.PrinterStatus
                        User         = ''
                    }
                }
                if ($console -and $console.Sid) {
                    $r = Invoke-CimMethod -CimSession $cim -ClassName StdRegProv -MethodName EnumKey -Arguments @{ hDefKey = $HKU; sSubKeyName = "$($console.Sid)\Printers\Connections" } -ErrorAction SilentlyContinue
                    foreach ($k in @($r.sNames)) {
                        $parts = "$k" -split ','      # ,,server,queue
                        if ($parts.Count -ge 4) {
                            [pscustomobject]@{
                                ComputerName = $pc; Name = "\\$($parts[2])\$($parts[3])"; Kind = 'User'; Port = ''; HostAddress = $parts[2]
                                Driver = ''; Default = $false; Shared = $false; Status = $null; User = $console.UserName
                            }
                        }
                    }
                }
            }
            catch { Write-Error -Message "$pc : $($_.Exception.Message)" -TargetObject $pc }
            finally { if ($cim) { Remove-CimSession $cim -ErrorAction SilentlyContinue } }
        }
    }
}
