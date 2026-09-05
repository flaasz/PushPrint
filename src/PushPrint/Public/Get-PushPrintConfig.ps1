function Get-PushPrintDefaultConfig {
    # Built-in defaults. Everything here can be overridden in settings.json (deep-merged).
    # MAC prefixes are a hint for DHCP filtering only; SNMP sysDescr matching (matchPattern) is authoritative.
    [ordered]@{
        adminUserPattern = '{domain}\adm{user}'
        driverRoot       = '%ProgramData%\PushPrint\drivers'
        catalogPath      = '%APPDATA%\PushPrint\printers.json'
        remoteTempDir    = 'C:\Temp\PushPrint'
        timeoutSec       = 600
        printServers     = [ordered]@{}
        sites            = [ordered]@{}      # optional manual site -> subnets map, merged with AD Sites & Services
        pullPrintServers = @()
        pullQueueMarkers = @('SafeQ', 'YSoft', 'PaperCut', 'Printix', 'PrinterLogic', 'Vasion', 'uniFLOW', 'FollowMe', 'Follow-Me', 'Pull', 'Secure')
        # Order matters for matchPattern: the first vendor whose pattern matches wins, so specific ones (HPDJ) go before general ones (HP).
        drivers          = [ordered]@{
            KM      = [ordered]@{ displayName = 'Konica Minolta'; driverName = 'KONICA MINOLTA Universal PCL';    matchPattern = 'KONICA|MINOLTA|bizhub'; macPrefixes = @('00206B', '0050AA') }
            HPDJ    = [ordered]@{ displayName = 'HP DesignJet'; driverName = 'HP DesignJet Universal Print Driver'; matchPattern = 'DesignJet'; macPrefixes = @() }
            HP      = [ordered]@{ displayName = 'HP LaserJet / OfficeJet'; driverName = 'HP Universal Printing PCL 6'; matchPattern = 'HP |Hewlett|LaserJet|OfficeJet|PageWide'; macPrefixes = @('001B78', '0017A4', '3CD92B', '98E7F4', '10604B', 'A0D3C1', '00215A', '00237D', '0025B3', '78E3B5', '1CC1DE', '2C4138', '30E171', '40B034', '9457A5', 'B499BA', 'ECB1D7', 'E4E749', 'D48564', 'C8CBB8', '80CE62', '6CC217', '645106', '5CB901', '3C5282', '2C27D7', '28924A', '9C8E99', '002655', '001E0B', '001F29', '002264', '002481', '00306E', '000E7F', '000F20', '001083', '00110A', '001185', '001279', '001321', '001438', '0014C2', '001560', '001635', '001708', '001871', '0018FE', '0019BB', '001A4B', '001CC4', '0060B0', '080009') }
            XEROX   = [ordered]@{ displayName = 'Xerox'; driverName = 'Xerox Global Print Driver PCL6';   matchPattern = 'Xerox|VersaLink|AltaLink|WorkCentre|Phaser'; macPrefixes = @('0000AA', '080037', '9C934E', '000000') }
            RICOH   = [ordered]@{ displayName = 'Ricoh'; driverName = 'PCL6 Driver for Universal Print';  matchPattern = 'RICOH|Aficio|Lanier|Savin'; macPrefixes = @('000074', '002673', '583879') }
            CANON   = [ordered]@{ displayName = 'Canon'; driverName = 'Canon Generic Plus PCL6';          matchPattern = 'Canon|imageRUNNER|imageCLASS|i-SENSYS'; macPrefixes = @('000085', '001E8F', '180CAC', '2C9EFC', '00BBC1', 'F48139', '888717') }
            KYOCERA = [ordered]@{ displayName = 'Kyocera'; driverName = 'Kyocera Universal Printing Driver'; matchPattern = 'Kyocera|TASKalfa|ECOSYS'; macPrefixes = @('00C0EE', '0017C8') }
            BROTHER = [ordered]@{ displayName = 'Brother'; driverName = 'Brother Universal Printer (PCL)'; matchPattern = 'Brother'; macPrefixes = @('008077', '001BA9', '30055C') }
            LEXMARK = [ordered]@{ displayName = 'Lexmark'; driverName = 'Lexmark Universal v2 PCL 6'; matchPattern = 'Lexmark'; macPrefixes = @('002000', '000400', '0021B7') }
            EPSON   = [ordered]@{ displayName = 'Epson'; driverName = 'EPSON Universal Print Driver'; matchPattern = 'EPSON'; macPrefixes = @('000048', '0026AB', '64EB8C', '44D244') }
        }
        snmp             = [ordered]@{ community = 'public'; timeoutMs = 800; retries = 1; port = 161 }
        discovery        = [ordered]@{ dhcpServers = @(); probePorts = @(9100, 631, 515); tcpTimeoutMs = 400; maxThreads = 64; excludeSubnets = @(); maxHostsPerScan = 65536 }
    }
}

function Get-PushPrintConfig {
    <#
    .SYNOPSIS
        Loads the effective configuration: built-in defaults deep-merged with the first settings.json found.
    .DESCRIPTION
        Search order for the settings file:
          1. -Path
          2. $env:PUSHPRINT_CONFIG
          3. %APPDATA%\PushPrint\settings.json
          4. %ProgramData%\PushPrint\settings.json
          5. <repo>\config\settings.json (when running from a checkout)
        Environment variables in path values (%APPDATA% etc.) are expanded. The result is cached per session;
        use -Force to reload.
    .EXAMPLE
        (Get-PushPrintConfig).printServers
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [string] $Path,
        [switch] $Force
    )
    if ($script:ConfigCache -and -not $Force -and -not $Path) { return $script:ConfigCache }

    $candidates = @(
        $Path
        $env:PUSHPRINT_CONFIG
        $(if ($env:APPDATA) { Join-Path $env:APPDATA 'PushPrint\settings.json' })
        $(if ($env:ProgramData) { Join-Path $env:ProgramData 'PushPrint\settings.json' })
        (Join-Path (Split-Path (Split-Path $script:ModuleRoot -Parent) -Parent) 'config\settings.json')
    ) | Where-Object { $_ }

    $file = $candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    $defaults = Get-PushPrintDefaultConfig
    $override = $null
    if ($file) {
        try {
            $json = Get-Content -LiteralPath $file -Raw -Encoding UTF8
            $override = ConvertTo-Hashtable (ConvertFrom-Json $json)
        }
        catch { throw "Config file '$file' is not valid JSON: $($_.Exception.Message)" }
    }
    elseif ($Path) { throw "Config file not found: $Path" }

    $cfg = Merge-Hashtable -Base $defaults -Override $override
    foreach ($k in 'driverRoot', 'catalogPath', 'remoteTempDir') {
        if ($cfg[$k]) { $cfg[$k] = [Environment]::ExpandEnvironmentVariables([string]$cfg[$k]) }
    }
    $cfg['sourcePath'] = $file
    if (-not $Path) { $script:ConfigCache = $cfg }
    return $cfg
}

function Resolve-AdminUserName {
    <#
    .SYNOPSIS  Applies adminUserPattern ({domain}, {user}) for the current user.
    #>
    param([string] $Pattern = (Get-PushPrintConfig).adminUserPattern)
    return $Pattern.Replace('{domain}', $env:USERDOMAIN).Replace('{user}', $env:USERNAME)
}

function Resolve-PrinterDriver {
    <#
    .SYNOPSIS  Returns the driver entry for a vendor key, throwing a helpful error when unknown.
    #>
    param([Parameter(Mandatory)] [string] $Vendor, $Config = (Get-PushPrintConfig))
    $key = $Config.drivers.Keys | Where-Object { $_ -ieq $Vendor } | Select-Object -First 1
    if (-not $key) { throw "Unknown vendor '$Vendor'. Configured vendors: $($Config.drivers.Keys -join ', ')" }
    $entry = $Config.drivers[$key]
    return [pscustomobject]@{ Vendor = $key; DriverName = $entry.driverName; DisplayName = $entry.displayName }
}
