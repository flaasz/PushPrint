@{
    RootModule        = 'PushPrint.psm1'
    ModuleVersion     = '0.2.0'
    GUID              = '7f1d5b0e-3c7a-4e7b-9d2a-5a2f1c8e4b61'
    Author            = 'Bartłomiej Profic'
    Copyright         = '(c) 2026 Bartłomiej Profic. MIT License.'
    Description       = 'Agentless network printer management for Active Directory environments: remote install/remove over SMB + WMI (no WinRM, no agent), printer discovery via DHCP, print servers and SNMP scoped to AD sites, and pull-queue vs direct-print detection.'
    PowerShellVersion = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')
    FunctionsToExport = @(
        'Get-PushPrintConfig'
        'Install-RemotePrinter'
        'Remove-RemotePrinter'
        'Get-RemotePrinter'
        'Get-AdSiteSubnet'
        'Get-PrinterSite'
        'Get-PrintServerQueue'
        'Find-DhcpPrinter'
        'Find-SnmpPrinter'
        'Get-PrinterSnmpInfo'
        'Test-PrinterOnline'
        'Invoke-PrinterDiscovery'
        'Get-PrinterCatalog'
        'Save-PrinterCatalog'
        'Compare-PrinterCatalog'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            Tags         = @('Printer', 'PrintManagement', 'ActiveDirectory', 'SNMP', 'DHCP', 'Windows', 'Sysadmin')
            LicenseUri   = 'https://github.com/flaasz/pushprint/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/flaasz/pushprint'
            ReleaseNotes = 'See CHANGELOG.md'
        }
    }
}
