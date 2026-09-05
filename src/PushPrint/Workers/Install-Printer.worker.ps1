<#
    Runs ON THE TARGET as the admin account (via Win32_Process.Create).
    Installs a direct-IP printer machine-wide: stages the driver from <Vendor>.zip if missing, creates the TCP/IP port,
    adds or updates the printer, optionally sets it as default for the console user and prints a test page.
    Reads params.json in $Dir, appends to result.log, writes the exit code to done.txt.
#>
param([Parameter(Mandatory)] [string] $Dir)
$ErrorActionPreference = 'Stop'
$log = Join-Path $Dir 'result.log'
function Log($m) { "$(Get-Date -Format HH:mm:ss) $m" | Out-File -FilePath $log -Append -Encoding utf8 }
$exit = 0
try {
    $p = Get-Content -LiteralPath (Join-Path $Dir 'params.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $PrinterName = [string]$p.PrinterName
    $PrinterIP   = [string]$p.PrinterIP
    $Vendor      = [string]$p.Vendor
    $DriverName  = [string]$p.DriverName
    $PortName    = if ($p.PortName) { [string]$p.PortName } else { "IP_$PrinterIP" }
    $Protocol    = if ($p.Protocol) { [string]$p.Protocol } else { 'RAW' }
    $SetDefault  = [bool]$p.SetDefault
    $TestPage    = [bool]$p.TestPage
    $Location    = [string]$p.Location
    $Comment     = [string]$p.Comment

    # --- driver ---
    if (Get-PrinterDriver -Name $DriverName -ErrorAction SilentlyContinue) {
        Log "Driver '$DriverName' already present"
    }
    else {
        $zip = Join-Path $Dir "$Vendor.zip"
        $tmp = Join-Path $Dir $Vendor
        if (-not (Test-Path -LiteralPath $zip)) { throw "Driver '$DriverName' is not installed and no package was sent ($zip missing)." }
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
        Log "Extracting $zip"
        Expand-Archive -LiteralPath $zip -DestinationPath $tmp -Force
        $allInf = @(Get-ChildItem -LiteralPath $tmp -Filter *.inf -Recurse)
        $infs   = @($allInf | Where-Object { Select-String -LiteralPath $_.FullName -Pattern ([regex]::Escape($DriverName)) -Quiet })
        if (-not $infs) { throw "No INF in the package references '$DriverName'. INFs found: $($allInf.Name -join ', ')" }
        # Unattended install cannot answer the "trust this publisher" dialog: trust the catalog signer up front.
        foreach ($cat in (Get-ChildItem -LiteralPath $tmp -Filter *.cat -Recurse)) {
            $sig = Get-AuthenticodeSignature -LiteralPath $cat.FullName
            if ($sig.SignerCertificate) {
                $store = New-Object System.Security.Cryptography.X509Certificates.X509Store('TrustedPublisher', 'LocalMachine')
                $store.Open('ReadWrite')
                try {
                    if (-not ($store.Certificates | Where-Object Thumbprint -eq $sig.SignerCertificate.Thumbprint)) {
                        $store.Add($sig.SignerCertificate); Log "Trusted publisher added: $($sig.SignerCertificate.Subject)"
                    }
                }
                finally { $store.Close() }
            }
        }
        foreach ($inf in $infs) {
            Log "pnputil /add-driver $($inf.Name)"
            $out = & pnputil.exe /add-driver $inf.FullName 2>&1
            if ($LASTEXITCODE -ne 0) { throw "pnputil failed ($LASTEXITCODE): $out" }
        }
        Add-PrinterDriver -Name $DriverName
        Log "Driver '$DriverName' installed"
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }

    # --- port ---
    if (-not (Get-PrinterPort -Name $PortName -ErrorAction SilentlyContinue)) {
        if ($Protocol -eq 'LPR') { Add-PrinterPort -Name $PortName -LprHostAddress $PrinterIP -LprQueueName 'lp' -LprByteCounting }
        else { Add-PrinterPort -Name $PortName -PrinterHostAddress $PrinterIP }
        Log "Port $PortName -> $PrinterIP ($Protocol)"
    }

    # --- printer ---
    $extra = @{}
    if ($Location) { $extra.Location = $Location }
    if ($Comment)  { $extra.Comment = $Comment }
    if (Get-Printer -Name $PrinterName -ErrorAction SilentlyContinue) {
        Set-Printer -Name $PrinterName -PortName $PortName -DriverName $DriverName @extra
        Log "Updated existing printer '$PrinterName'"
    }
    else {
        Add-Printer -Name $PrinterName -PortName $PortName -DriverName $DriverName @extra
        Log "Added printer '$PrinterName' on $PortName"
    }

    # --- default printer for the console user (their HKU hive) ---
    if ($SetDefault) {
        $user = (Get-CimInstance Win32_ComputerSystem).UserName
        if (-not $user) { Log "WARN nobody logged on at the console - default printer not set" }
        else {
            $sid = (New-Object System.Security.Principal.NTAccount($user)).Translate([System.Security.Principal.SecurityIdentifier]).Value
            $key = "Registry::HKEY_USERS\$sid\Software\Microsoft\Windows NT\CurrentVersion\Windows"
            if (-not (Test-Path $key)) { Log "WARN registry hive for $user is not loaded - default printer not set" }
            else {
                Set-ItemProperty -Path $key -Name LegacyDefaultPrinterMode -Value 1 -Type DWord
                Set-ItemProperty -Path $key -Name Device -Value "$PrinterName,winspool,$PortName"
                Log "Default printer set for $user"
            }
        }
    }

    if ($TestPage) {
        "PushPrint test page - $env:COMPUTERNAME - $PrinterName - $(Get-Date -Format 'yyyy-MM-dd HH:mm')" | Out-Printer -Name $PrinterName
        Log "Test page sent"
    }
    $found = Get-Printer -Name $PrinterName -ErrorAction SilentlyContinue
    if ($found) { Log "RESULT $($found.Name) | $($found.DriverName) | $($found.PortName) | $($found.PrinterStatus)" }
    else { Log "WARN '$PrinterName' not visible after install" }
}
catch { Log "ERROR $($_.Exception.Message)"; $exit = 1 }
$exit | Out-File -FilePath (Join-Path $Dir 'done.txt') -Encoding ascii
exit $exit
