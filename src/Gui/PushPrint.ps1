#Requires -Version 5.1
<#
.SYNOPSIS
    PushPrint - desktop GUI for the PushPrint module (install / inspect / discover / catalog).
.DESCRIPTION
    Start with PushPrint.cmd (no console window) or:
        powershell -STA -ExecutionPolicy Bypass -File .\PushPrint.ps1 [-ConfigPath <settings.json>] [-Theme Dark|Light|Auto]
    Long-running work executes in a background runspace; the module's Information stream is rendered in the activity log.
    Per-user state (recent computers, theme, last admin account) lives in %APPDATA%\PushPrint.
#>
[CmdletBinding()]
param(
    [string] $ConfigPath,
    [ValidateSet('Auto', 'Dark', 'Light')] [string] $Theme
)
$ErrorActionPreference = 'Stop'

try {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml, System.Data

    # ------------------------------------------------------------------ paths & module
    $Here           = Split-Path -Parent $MyInvocation.MyCommand.Path
    $ModuleManifest = Join-Path (Split-Path -Parent $Here) 'PushPrint\PushPrint.psd1'
    if (-not (Test-Path -LiteralPath $ModuleManifest)) { throw "PushPrint module not found next to the GUI: $ModuleManifest" }
    Import-Module $ModuleManifest -Force
    $Version = (Import-PowerShellDataFile $ModuleManifest).ModuleVersion

    $StateDir        = Join-Path $env:APPDATA 'PushPrint'
    $null            = New-Item -Path $StateDir -ItemType Directory -Force
    $RecentFile      = Join-Path $StateDir 'recent-computers.txt'
    $GuiSettingsFile = Join-Path $StateDir 'gui.json'
    $script:Gui = @{ theme = 'Auto'; adminUser = $null }
    if (Test-Path -LiteralPath $GuiSettingsFile) {
        try { (Get-Content -LiteralPath $GuiSettingsFile -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $script:Gui[$_.Name] = $_.Value } } catch { Write-Verbose $_ }
    }
    function Save-GuiState { $script:Gui | ConvertTo-Json | Set-Content -LiteralPath $GuiSettingsFile -Encoding UTF8 }

    $script:CfgArgs = @{}; if ($ConfigPath) { $script:CfgArgs.ConfigPath = $ConfigPath }
    function Get-Cfg { if ($ConfigPath) { Get-PushPrintConfig -Path $ConfigPath } else { Get-PushPrintConfig -Force } }
    $script:Cfg = Get-Cfg

    # ------------------------------------------------------------------ XAML
    function Import-Xaml([string] $Path) {
        [xml] $x = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $x))
    }
    [xml] $MainXml = Get-Content -LiteralPath (Join-Path $Here 'MainWindow.xaml') -Raw -Encoding UTF8
    $Window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $MainXml))
    $Window.Resources.MergedDictionaries.Add((Import-Xaml (Join-Path $Here 'Themes\Styles.xaml')))
    $UI = @{}
    foreach ($node in $MainXml.SelectNodes('//*[@Name]')) { $UI[$node.Name] = $Window.FindName($node.Name) }
    $UI.VersionText.Text = "v$Version"

    $script:ThemeDict = $null
    function Set-Theme([string] $Name) {
        if ($Name -eq 'Auto') {
            $light = 1
            try { $light = Get-ItemPropertyValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'AppsUseLightTheme' -ErrorAction Stop } catch { Write-Verbose $_ }
            $Name = if ($light -eq 0) { 'Dark' } else { 'Light' }
        }
        $dict = Import-Xaml (Join-Path $Here "Themes\$Name.xaml")
        if ($script:ThemeDict) { [void]$Window.Resources.MergedDictionaries.Remove($script:ThemeDict) }
        $Window.Resources.MergedDictionaries.Insert(0, $dict)
        $script:ThemeDict = $dict; $script:CurrentTheme = $Name
    }
    Set-Theme $(if ($Theme) { $Theme } else { [string]$script:Gui.theme })

    # ------------------------------------------------------------------ log
    $LogBrush = @{ INFO = 'TextBrush'; WARN = 'WarnBrush'; ERROR = 'DangerBrush'; RESULT = 'SuccessBrush'; STEP = 'InfoBrush' }
    function Write-GuiLog([string] $Text, [string] $Level = 'INFO') {
        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.Text = '{0}  {1}' -f (Get-Date -Format 'HH:mm:ss'), $Text
        $tb.TextWrapping = 'Wrap'
        if ($Level -eq 'STEP') { $tb.FontWeight = 'SemiBold' }
        $tb.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, $LogBrush[$Level])
        [void]$UI.LogList.Items.Add($tb)
        while ($UI.LogList.Items.Count -gt 3000) { $UI.LogList.Items.RemoveAt(0) }
        $UI.LogList.ScrollIntoView($tb)
    }
    function Write-InfoRecord($rec) {
        $msg = [string]$rec.MessageData
        $level = 'INFO'
        if ($rec.Tags -and $LogBrush.ContainsKey([string]$rec.Tags[0])) { $level = [string]$rec.Tags[0] }
        elseif ($msg -match '^(ERROR|WARN|RESULT|STEP)\b') { $level = $Matches[1] }
        Write-GuiLog ($msg -replace '^(ERROR|WARN|RESULT|STEP)\s+', '') $level
    }
    $UI.LogClear.Add_Click({ $UI.LogList.Items.Clear() })
    $UI.LogCopy.Add_Click({ $text = ($UI.LogList.Items | ForEach-Object { $_.Text }) -join "`r`n"; if ($text) { [System.Windows.Clipboard]::SetText($text) } })

    # ------------------------------------------------------------------ background runner
    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $iss.ImportPSModule($ModuleManifest)
    $Runspace = [runspacefactory]::CreateRunspace($iss)
    $Runspace.Open()
    $script:Job = $null
    $Buttons = @('InstallRun', 'InstallPing', 'MachineList', 'MachineRemove', 'DiscRun', 'DiscLoadSites', 'DiscMerge', 'DiscOnline', 'CatalogOnline')
    function Set-Busy([bool] $Busy, [string] $Status) {
        foreach ($b in $Buttons) { $UI[$b].IsEnabled = -not $Busy }
        $UI.Busy.Visibility = if ($Busy) { 'Visible' } else { 'Hidden' }
        $UI.StatusText.Text = if ($Status) { $Status } elseif ($Busy) { 'Working...' } else { 'Ready' }
    }
    function Start-Work {
        param([string] $Command, [scriptblock] $ScriptBlock, [hashtable] $Parameters = @{}, [object[]] $ArgumentList = @(), [scriptblock] $OnDone, [string] $Status)
        if ($script:Job) { Write-GuiLog 'Another task is still running.' 'WARN'; return }
        $ps = [powershell]::Create()
        $ps.Runspace = $Runspace
        if ($ScriptBlock) { [void]$ps.AddScript($ScriptBlock.ToString()); foreach ($a in $ArgumentList) { [void]$ps.AddArgument($a) } }
        else { [void]$ps.AddCommand($Command).AddParameters($Parameters) }
        $script:Job = @{ PS = $ps; Handle = $ps.BeginInvoke(); Seen = @{ i = 0; w = 0; e = 0 }; OnDone = $OnDone; Started = Get-Date }
        Set-Busy $true $Status
        $Timer.Start()
    }
    $Timer = New-Object System.Windows.Threading.DispatcherTimer
    $Timer.Interval = [TimeSpan]::FromMilliseconds(250)
    $Timer.Add_Tick({
        $j = $script:Job; if (-not $j) { $Timer.Stop(); return }
        $ps = $j.PS
        while ($j.Seen.i -lt $ps.Streams.Information.Count) { Write-InfoRecord $ps.Streams.Information[$j.Seen.i]; $j.Seen.i++ }
        while ($j.Seen.w -lt $ps.Streams.Warning.Count)     { Write-GuiLog $ps.Streams.Warning[$j.Seen.w].Message 'WARN'; $j.Seen.w++ }
        while ($j.Seen.e -lt $ps.Streams.Error.Count) {
            $er = $ps.Streams.Error[$j.Seen.e]
            Write-GuiLog "$($er.Exception.Message)" 'ERROR'
            $j.Seen.e++
        }
        if ($j.Handle.IsCompleted) {
            $Timer.Stop()
            $output = $null; $ok = $true
            try { $output = @($ps.EndInvoke($j.Handle)) }
            catch {
                $ok = $false
                $ex = $_.Exception; if ($ex.InnerException) { $ex = $ex.InnerException }
                Write-GuiLog $ex.Message 'ERROR'
            }
            $ps.Dispose(); $script:Job = $null
            $elapsed = [int]((Get-Date) - $j.Started).TotalSeconds
            Set-Busy $false "Done in ${elapsed}s"
            if ($ok -and $j.OnDone) { try { & $j.OnDone $output } catch { Write-GuiLog "UI update failed: $($_.Exception.Message)" 'ERROR' } }
        }
    })

    # ------------------------------------------------------------------ helpers
    function Get-Prop($obj, [string] $name) {
        if ($null -eq $obj) { return $null }
        if ($obj -is [System.Collections.IDictionary]) { return $obj[$name] }
        $p = $obj.PSObject.Properties.Match($name); if ($p.Count) { return $p[0].Value }
        return $null
    }
    function ConvertTo-DataTable {
        param([object[]] $Rows, [string[]] $Columns)
        $dt = New-Object System.Data.DataTable
        $Rows = @($Rows | Where-Object { $_ })
        if (-not $Columns) { $Columns = @($Rows | ForEach-Object { $_.PSObject.Properties.Name } | Select-Object -Unique) }
        $boolCols = @{}
        foreach ($c in $Columns) {
            $isBool = $false
            foreach ($r in $Rows) { $v = Get-Prop $r $c; if ($null -ne $v) { $isBool = $v -is [bool]; break } }
            $boolCols[$c] = $isBool
            $col = New-Object System.Data.DataColumn $c, $(if ($isBool) { [bool] } else { [string] })
            $col.AllowDBNull = $true
            $dt.Columns.Add($col)
        }
        foreach ($r in $Rows) {
            $row = $dt.NewRow()
            foreach ($c in $Columns) {
                $v = Get-Prop $r $c
                if ($null -eq $v) { $row[$c] = [DBNull]::Value }
                elseif ($boolCols[$c]) { $row[$c] = [bool]$v }
                elseif ($v -is [array]) { $row[$c] = (@($v) -join ', ') }
                else { $row[$c] = "$v" }
            }
            $dt.Rows.Add($row)
        }
        return , $dt    # comma: PowerShell would otherwise unroll the table into its rows
    }
    function Get-SelectedRow($grid) { @($grid.SelectedItems | ForEach-Object { $_ }) }
    function Split-ComputerList([string] $text) { @($text -split '[\s,;]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique) }
    function Get-Recent { if (Test-Path -LiteralPath $RecentFile) { @(Get-Content -LiteralPath $RecentFile | Where-Object { $_ }) } else { @() } }
    function Add-Recent([string[]] $names) {
        $list = @($names) + (Get-Recent) | Select-Object -Unique | Select-Object -First 20
        $list | Set-Content -LiteralPath $RecentFile
        foreach ($cb in $UI.InstallRecent, $UI.MachineName) { $cur = $cb.Text; $cb.Items.Clear(); $list | ForEach-Object { [void]$cb.Items.Add($_) }; if ($cb.IsEditable) { $cb.Text = $cur } }
    }
    function Show-Error([string] $text) { [void][System.Windows.MessageBox]::Show($Window, $text, 'PushPrint', 'OK', 'Warning') }
    function Confirm-Action([string] $text) { ([System.Windows.MessageBox]::Show($Window, $text, 'PushPrint', 'YesNo', 'Question')) -eq 'Yes' }

    # ------------------------------------------------------------------ credentials
    $script:Cred = $null
    function Get-AdminCred([switch] $Force) {
        if ($script:Cred -and -not $Force) { return $script:Cred }
        $default = if ($script:Gui.adminUser) { [string]$script:Gui.adminUser } else { ([string]$script:Cfg.adminUserPattern).Replace('{domain}', $env:USERDOMAIN).Replace('{user}', $env:USERNAME) }
        $c = Get-Credential -UserName $default -Message 'Admin account used on the target computers'
        if ($c) {
            $script:Cred = $c; $UI.CredText.Text = $c.UserName
            $script:Gui.adminUser = $c.UserName; Save-GuiState
        }
        return $script:Cred
    }
    $UI.CredButton.Add_Click({ [void](Get-AdminCred -Force) })
    $UI.ThemeToggle.Add_Click({
        $next = if ($script:CurrentTheme -eq 'Dark') { 'Light' } else { 'Dark' }
        Set-Theme $next; $script:Gui.theme = $next; Save-GuiState
    })

    # ------------------------------------------------------------------ navigation
    $Pages = @{ NavInstall = 'PageInstall'; NavMachines = 'PageMachines'; NavDiscovery = 'PageDiscovery'; NavCatalog = 'PageCatalog'; NavSettings = 'PageSettings' }
    foreach ($nav in $Pages.Keys) {
        $UI[$nav].Tag = $Pages[$nav]
        $UI[$nav].Add_Checked({
            param($src)
            foreach ($p in $Pages.Values) { $UI[$p].Visibility = if ($p -eq $src.Tag) { 'Visible' } else { 'Collapsed' } }
        })
    }

    # ------------------------------------------------------------------ catalog data
    $CatalogColumns = @('name', 'ip', 'vendor', 'model', 'serial', 'site', 'location', 'queueKind', 'note', 'printServer', 'shareName', 'mac', 'hostName', 'snmpName', 'dhcpName', 'sources', 'flags', 'lastSeen')
    $script:Catalog = @()
    $script:CatalogTable = $null
    function Update-Catalog {
        $script:Catalog = @(Get-PrinterCatalog @script:CfgArgs)
        $script:CatalogTable = ConvertTo-DataTable -Rows $script:Catalog -Columns $CatalogColumns
        $UI.CatalogGrid.ItemsSource = $script:CatalogTable.DefaultView
        $UI.CatalogPathText.Text = "$($script:Cfg.catalogPath)  -  $($script:Catalog.Count) printers"
        $sites = @($script:Catalog | ForEach-Object { "$($_.site)" } | Where-Object { $_ } | Sort-Object -Unique)
        foreach ($cb in $UI.InstallSite, $UI.CatalogSite) {
            $cb.Items.Clear(); [void]$cb.Items.Add('All sites'); $sites | ForEach-Object { [void]$cb.Items.Add($_) }; $cb.SelectedIndex = 0
        }
        Update-InstallGrid; Update-CatalogFilter
    }
    function ConvertTo-FilterLiteral([string] $s) { $s.Replace("'", "''").Replace('[', '[[]').Replace('%', '[%]').Replace('*', '[*]') }
    function Update-InstallGrid {
        $site = [string]$UI.InstallSite.SelectedItem; $q = $UI.InstallSearch.Text.Trim()
        $rows = $script:Catalog
        if ($site -and $site -ne 'All sites') { $rows = @($rows | Where-Object { "$($_.site)" -eq $site }) }
        if ($q) { $rows = @($rows | Where-Object { "$($_.name) $($_.ip) $($_.model) $($_.location) $($_.shareName) $($_.hostName)" -like "*$q*" }) }
        $UI.InstallGrid.ItemsSource = (ConvertTo-DataTable -Rows $rows -Columns @('name', 'ip', 'vendor', 'model', 'site', 'queueKind', 'location', 'printServer', 'shareName')).DefaultView
    }
    function Update-CatalogFilter {
        if (-not $script:CatalogTable) { return }
        $parts = @()
        $site = [string]$UI.CatalogSite.SelectedItem
        if ($site -and $site -ne 'All sites') { $parts += "site = '$(ConvertTo-FilterLiteral $site)'" }
        $q = $UI.CatalogSearch.Text.Trim()
        if ($q) { $like = "'%$(ConvertTo-FilterLiteral $q)%'"; $parts += "(name LIKE $like OR ip LIKE $like OR model LIKE $like OR location LIKE $like OR serial LIKE $like OR note LIKE $like)" }
        $script:CatalogTable.DefaultView.RowFilter = ($parts -join ' AND ')
    }
    function ConvertFrom-CatalogTable {
        foreach ($row in $script:CatalogTable.Rows) {
            if ($row.RowState -eq 'Deleted') { continue }
            $o = [ordered]@{}
            foreach ($c in $CatalogColumns) {
                $v = $row[$c]
                if ($v -is [DBNull] -or "$v" -eq '') { $v = $null }
                if ($c -in 'sources', 'flags') { $v = if ($v) { @("$v" -split ',\s*') } else { @() } }
                $o[$c] = $v
            }
            [pscustomobject]$o
        }
    }
    $UI.InstallSite.Add_SelectionChanged({ Update-InstallGrid })
    $UI.InstallSearch.Add_TextChanged({ Update-InstallGrid })
    $UI.InstallReload.Add_Click({ Update-Catalog; Write-GuiLog "Catalog reloaded ($($script:Catalog.Count) printers)" })
    $UI.CatalogSite.Add_SelectionChanged({ Update-CatalogFilter })
    $UI.CatalogSearch.Add_TextChanged({ Update-CatalogFilter })
    $UI.CatalogReload.Add_Click({ Update-Catalog; Write-GuiLog "Catalog reloaded ($($script:Catalog.Count) printers)" })
    $UI.CatalogDelete.Add_Click({
        $rows = Get-SelectedRow $UI.CatalogGrid
        if (-not $rows.Count) { return }
        if (-not (Confirm-Action "Remove $($rows.Count) printer(s) from the catalog? (Takes effect when you press Save.)")) { return }
        foreach ($r in $rows) { $r.Row.Delete() }
        $script:CatalogTable.AcceptChanges()
    })
    $UI.CatalogSave.Add_Click({
        try {
            $UI.CatalogGrid.CommitEdit([System.Windows.Controls.DataGridEditingUnit]::Row, $true) | Out-Null
            $items = @(ConvertFrom-CatalogTable)
            $items | Save-PrinterCatalog -Path $script:Cfg.catalogPath -InformationAction SilentlyContinue
            Write-GuiLog "Catalog saved: $($items.Count) printers -> $($script:Cfg.catalogPath)" 'RESULT'
            Update-Catalog
        }
        catch { Write-GuiLog "Save failed: $($_.Exception.Message)" 'ERROR' }
    })
    $UI.CatalogOnline.Add_Click({
        $ips = @($UI.CatalogGrid.Items | ForEach-Object { $_['ip'] } | Where-Object { $_ -and $_ -isnot [DBNull] })
        if (-not $ips.Count) { return }
        Write-GuiLog "Checking $($ips.Count) printers..." 'STEP'
        Start-Work -Command 'Test-PrinterOnline' -Parameters (@{ IPAddress = $ips } + $script:CfgArgs) -Status 'Checking printers' -OnDone {
            param($out)
            $off = @($out | Where-Object { -not $_.Online })
            foreach ($o in $off) { Write-GuiLog "$($o.IPAddress) offline" 'WARN' }
            foreach ($o in ($out | Where-Object { $_.Online -and $_.ErrorState })) { Write-GuiLog "$($o.IPAddress) $($o.SysName): $($o.ErrorState)" 'WARN' }
            Write-GuiLog "Online: $(@($out | Where-Object Online).Count) / $($out.Count)  (offline: $($off.Count))" 'RESULT'
        }
    })

    # ------------------------------------------------------------------ install page
    function Update-ConfigView {
        $UI.InstallVendor.Items.Clear(); foreach ($k in $script:Cfg.drivers.Keys) { [void]$UI.InstallVendor.Items.Add($k) }; if ($UI.InstallVendor.Items.Count) { $UI.InstallVendor.SelectedIndex = 0 }
        $UI.InstallServer.Items.Clear(); foreach ($k in $script:Cfg.printServers.Keys) { [void]$UI.InstallServer.Items.Add($k) }; if ($UI.InstallServer.Items.Count) { $UI.InstallServer.SelectedIndex = 0 }
        $src = if ($script:Cfg.sourcePath) { $script:Cfg.sourcePath } else { "(no settings.json found - using built-in defaults)`nSearched: -ConfigPath, %PUSHPRINT_CONFIG%, %APPDATA%\PushPrint\settings.json, %ProgramData%\PushPrint\settings.json, <repo>\config\settings.json" }
        $UI.SettingsConfigPath.Text = $src
        $UI.SettingsDriverRoot.Text = $script:Cfg.driverRoot
        $dump = [ordered]@{}; foreach ($k in $script:Cfg.Keys) { if ($k -ne 'sourcePath') { $dump[$k] = $script:Cfg[$k] } }
        $UI.SettingsDump.Text = ($dump | ConvertTo-Json -Depth 6)
    }
    $UI.ModeDirect.Add_Checked({ $UI.DirectPanel.Visibility = 'Visible'; $UI.ServerPanel.Visibility = 'Collapsed' })
    $UI.ModeServer.Add_Checked({ $UI.DirectPanel.Visibility = 'Collapsed'; $UI.ServerPanel.Visibility = 'Visible' })
    $UI.InstallGrid.Add_SelectionChanged({
        $row = $UI.InstallGrid.SelectedItem; if (-not $row) { return }
        $kind = "$($row['queueKind'])"; $share = "$($row['shareName'])"; $srv = "$($row['printServer'])"
        if ($kind -eq 'Pull' -and $srv) {
            $UI.ModeServer.IsChecked = $true
            $UI.InstallName.Text = if ($share) { $share } else { "$($row['name'])" }
            $UI.InstallServer.Text = $srv
        }
        else {
            $UI.ModeDirect.IsChecked = $true
            $UI.InstallName.Text = "$($row['name'])"
            $UI.InstallIp.Text = "$($row['ip'])"
            $v = "$($row['vendor'])"; if ($v -and $UI.InstallVendor.Items.Contains($v)) { $UI.InstallVendor.SelectedItem = $v }
            if ($srv -and $share) { $UI.InstallServer.Text = $srv }
        }
    })
    $UI.InstallRecent.Add_SelectionChanged({
        $sel = "$($UI.InstallRecent.SelectedItem)"; if (-not $sel) { return }
        $cur = Split-ComputerList $UI.InstallComputers.Text
        if ($cur -notcontains $sel) { $UI.InstallComputers.Text = (($cur + $sel) -join ', ') }
    })
    $UI.InstallPing.Add_Click({
        $pcs = Split-ComputerList $UI.InstallComputers.Text; if (-not $pcs.Count) { return }
        Start-Work -ScriptBlock { param($pcs) foreach ($pc in $pcs) { $ok = Test-Connection -ComputerName $pc -Count 1 -Quiet -ErrorAction SilentlyContinue; Write-Information -MessageData "$pc : $(if ($ok) { 'online' } else { 'no reply' })" -Tags $(if ($ok) { 'RESULT' } else { 'WARN' }) -InformationAction Continue } } -ArgumentList @(, $pcs) -Status 'Pinging'
    })
    $UI.InstallRun.Add_Click({
        $pcs = Split-ComputerList $UI.InstallComputers.Text
        $name = $UI.InstallName.Text.Trim()
        if (-not $pcs.Count -or -not $name) { Show-Error 'Enter at least one computer name and a printer name.'; return }
        $useServer = [bool]$UI.ModeServer.IsChecked
        $params = @{ ComputerName = $pcs; PrinterName = $name } + $script:CfgArgs
        if ($useServer) {
            $srv = $UI.InstallServer.Text.Trim(); if (-not $srv) { Show-Error 'Choose or type a print server.'; return }
            $params.PrintServer = $srv
        }
        else {
            $ip = $UI.InstallIp.Text.Trim()
            if ($ip -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { Show-Error "'$ip' is not a valid IPv4 address."; return }
            $params.PrinterIP = $ip
            $params.Vendor = [string]$UI.InstallVendor.SelectedItem
        }
        if ($UI.InstallDefault.IsChecked) { $params.SetDefault = $true }
        if ($UI.InstallTestPage.IsChecked) { $params.TestPage = $true }
        $cred = Get-AdminCred; if (-not $cred) { return }
        $params.Credential = $cred
        Add-Recent $pcs
        Write-GuiLog "Install '$name' on $($pcs.Count) computer(s): $($pcs -join ', ')" 'STEP'
        Start-Work -Command 'Install-RemotePrinter' -Parameters $params -Status "Installing on $($pcs.Count) computer(s)" -OnDone {
            param($out)
            $ok = @($out | Where-Object Success).Count; $bad = @($out | Where-Object { -not $_.Success })
            foreach ($b in $bad) { Write-GuiLog "$($b.ComputerName): $($b.Message)" 'ERROR' }
            Write-GuiLog "Install finished: $ok succeeded, $($bad.Count) failed" $(if ($bad.Count) { 'WARN' } else { 'RESULT' })
        }
    })

    # ------------------------------------------------------------------ machines page
    $script:MachineRows = @()
    function Invoke-MachineList {
        $pc = $UI.MachineName.Text.Trim(); if (-not $pc) { Show-Error 'Enter a computer name.'; return }
        $cred = Get-AdminCred; if (-not $cred) { return }
        Add-Recent @($pc)
        Write-GuiLog "Listing printers on $pc" 'STEP'
        Start-Work -Command 'Get-RemotePrinter' -Parameters (@{ ComputerName = $pc; Credential = $cred } + $script:CfgArgs) -Status "Querying $pc" -OnDone {
            param($out)
            $script:MachineRows = @($out)
            $UI.MachineGrid.ItemsSource = (ConvertTo-DataTable -Rows $script:MachineRows -Columns @('Name', 'Kind', 'Port', 'HostAddress', 'Driver', 'Default', 'User')).DefaultView
            Write-GuiLog "$($script:MachineRows.Count) printer(s) on $pc" 'RESULT'
        }
    }
    $UI.MachineList.Add_Click({ Invoke-MachineList })
    $UI.MachineName.AddHandler([System.Windows.Controls.Primitives.TextBoxBase]::TextChangedEvent, [System.Windows.Controls.TextChangedEventHandler] {})
    $UI.MachineRemove.Add_Click({
        $rows = Get-SelectedRow $UI.MachineGrid; if (-not $rows.Count) { return }
        $pc = $UI.MachineName.Text.Trim()
        $names = @($rows | ForEach-Object { "$($_['Name'])" })
        if (-not (Confirm-Action "Remove from ${pc}:`n`n$($names -join "`n")")) { return }
        $cred = Get-AdminCred; if (-not $cred) { return }
        $items = @($rows | ForEach-Object { @{ Name = "$($_['Name'])"; Kind = "$($_['Kind'])" } })
        Write-GuiLog "Removing $($items.Count) printer(s) from $pc" 'STEP'
        Start-Work -ScriptBlock {
            param($pc, $items, $cred, $cfgArgs)
            foreach ($i in $items) { Remove-RemotePrinter -ComputerName $pc -PrinterName $i.Name -Kind $i.Kind -Credential $cred -Confirm:$false @cfgArgs }
        } -ArgumentList @($pc, $items, $cred, $script:CfgArgs) -Status "Removing on $pc" -OnDone { Invoke-MachineList }
    })

    # ------------------------------------------------------------------ discovery page
    $script:SiteSubnets = @{}
    $script:DiscResults = @()
    $UI.DiscLoadSites.Add_Click({
        Write-GuiLog 'Loading AD sites and subnets' 'STEP'
        Start-Work -Command 'Get-AdSiteSubnet' -Parameters $script:CfgArgs -Status 'Reading AD Sites and Services' -OnDone {
            param($out)
            $script:SiteSubnets = @{}
            foreach ($s in $out) { if (-not $script:SiteSubnets.ContainsKey($s.Site)) { $script:SiteSubnets[$s.Site] = New-Object System.Collections.Generic.List[string] }; $script:SiteSubnets[$s.Site].Add($s.Subnet) }
            $UI.DiscSites.Items.Clear()
            foreach ($site in ($script:SiteSubnets.Keys | Sort-Object)) { [void]$UI.DiscSites.Items.Add("$site  ($($script:SiteSubnets[$site].Count) subnets)") }
            Write-GuiLog "$($script:SiteSubnets.Count) sites, $(@($out).Count) subnets" 'RESULT'
        }
    })
    $UI.DiscRun.Add_Click({
        $sources = @(); if ($UI.DiscSnmp.IsChecked) { $sources += 'Snmp' }; if ($UI.DiscDhcp.IsChecked) { $sources += 'Dhcp' }; if ($UI.DiscPrintServer.IsChecked) { $sources += 'PrintServer' }
        if (-not $sources.Count) { Show-Error 'Select at least one source.'; return }
        $params = @{ Source = $sources } + $script:CfgArgs
        if (-not $UI.DiscProbe.IsChecked) { $params.NoProbe = $true }
        $subnets = @($UI.DiscSubnets.Text -split '[\r\n,; ]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $sites = @($UI.DiscSites.SelectedItems | ForEach-Object { ("$_" -split '\s{2,}')[0] })
        if ($subnets.Count) { $params.Subnet = $subnets }
        elseif ($sites.Count) { $params.Site = $sites }
        else { Show-Error 'Select one or more AD sites, or type subnets.'; return }
        Write-GuiLog "Discovery: $(if ($subnets.Count) { $subnets -join ', ' } else { $sites -join ', ' }) via $($sources -join '+')" 'STEP'
        Start-Work -Command 'Invoke-PrinterDiscovery' -Parameters $params -Status 'Discovering printers' -OnDone {
            param($out)
            $script:DiscResults = @($out | ForEach-Object { $_ | Add-Member -NotePropertyName flagsText -NotePropertyValue (@($_.flags) -join ', ') -PassThru -Force })
            $UI.DiscGrid.ItemsSource = (ConvertTo-DataTable -Rows $script:DiscResults -Columns @('name', 'ip', 'vendor', 'model', 'serial', 'site', 'shareName', 'queueKind', 'flagsText')).DefaultView
            $flagged = @($script:DiscResults | Where-Object { $_.flags.Count }).Count
            $UI.DiscSummary.Text = "$($script:DiscResults.Count) printers found, $flagged with flags"
            Write-GuiLog $UI.DiscSummary.Text 'RESULT'
        }
    })
    $UI.DiscMerge.Add_Click({
        if (-not $script:DiscResults.Count) { Show-Error 'Run discovery first.'; return }
        if (-not (Confirm-Action "Merge $($script:DiscResults.Count) discovered printers into the catalog?`nExisting names and notes are kept; facts (model, serial, MAC, site) are updated.")) { return }
        $items = @($script:DiscResults | Select-Object -Property * -ExcludeProperty flagsText)
        Start-Work -Command 'Save-PrinterCatalog' -Parameters (@{ InputObject = $items; Merge = $true; Path = $script:Cfg.catalogPath }) -Status 'Merging catalog' -OnDone { Update-Catalog }
    })
    $UI.DiscExport.Add_Click({
        if (-not $script:DiscResults.Count) { return }
        $dlg = New-Object Microsoft.Win32.SaveFileDialog; $dlg.Filter = 'CSV|*.csv'; $dlg.FileName = "printers-discovery-$(Get-Date -Format yyyyMMdd-HHmm).csv"
        if ($dlg.ShowDialog($Window)) {
            $script:DiscResults | Select-Object name, ip, mac, vendor, model, serial, site, location, printServer, shareName, queueKind, hostName, snmpName, dhcpName, @{n = 'sources'; e = { $_.sources -join ' ' } }, @{n = 'flags'; e = { $_.flags -join ' ' } }, note | Export-Csv -Path $dlg.FileName -NoTypeInformation -Encoding UTF8
            Write-GuiLog "Exported to $($dlg.FileName)" 'RESULT'
        }
    })
    $UI.DiscOnline.Add_Click({
        $ips = @($script:DiscResults | ForEach-Object { $_.ip } | Where-Object { $_ })
        if (-not $ips.Count) { return }
        Start-Work -Command 'Test-PrinterOnline' -Parameters (@{ IPAddress = $ips } + $script:CfgArgs) -Status 'Checking printers' -OnDone {
            param($out)
            foreach ($o in ($out | Where-Object { -not $_.Online })) { Write-GuiLog "$($o.IPAddress) offline" 'WARN' }
            Write-GuiLog "Online: $(@($out | Where-Object Online).Count) / $($out.Count)" 'RESULT'
        }
    })

    # ------------------------------------------------------------------ settings page
    function Get-ExampleConfig {
        foreach ($p in (Join-Path (Split-Path (Split-Path $Here -Parent) -Parent) 'config\settings.example.json'), (Join-Path (Split-Path $Here -Parent) 'settings.example.json')) { if (Test-Path -LiteralPath $p) { return $p } }
        return $null
    }
    $UserConfig = Join-Path $StateDir 'settings.json'
    $UI.SettingsCreate.Add_Click({
        $target = if ($ConfigPath) { $ConfigPath } else { $UserConfig }
        if (Test-Path -LiteralPath $target) { Write-GuiLog "Already exists: $target" 'WARN' }
        else {
            $ex = Get-ExampleConfig
            if ($ex) { Copy-Item -LiteralPath $ex -Destination $target; Write-GuiLog "Created $target - edit it, then press Reload configuration" 'RESULT' }
            else { '{ }' | Set-Content -LiteralPath $target -Encoding UTF8; Write-GuiLog "Created empty $target" 'RESULT' }
        }
        Start-Process notepad.exe $target
    })
    $UI.SettingsOpen.Add_Click({ $p = if ($script:Cfg.sourcePath) { $script:Cfg.sourcePath } else { $UserConfig }; if (Test-Path -LiteralPath $p) { Start-Process notepad.exe $p } else { Write-GuiLog "No settings file yet - use 'Create settings.json from example'" 'WARN' } })
    $UI.SettingsFolder.Add_Click({ $p = if ($script:Cfg.sourcePath) { Split-Path $script:Cfg.sourcePath -Parent } else { $StateDir }; Start-Process explorer.exe $p })
    $UI.SettingsReload.Add_Click({
        try { $script:Cfg = Get-Cfg; Update-ConfigView; Update-Catalog; Write-GuiLog "Configuration reloaded from $(if ($script:Cfg.sourcePath) { $script:Cfg.sourcePath } else { 'built-in defaults' })" 'RESULT' }
        catch { Write-GuiLog "Reload failed: $($_.Exception.Message)" 'ERROR' }
    })
    $UI.SettingsDrivers.Add_Click({ $p = $script:Cfg.driverRoot; if (-not (Test-Path -LiteralPath $p)) { New-Item -Path $p -ItemType Directory -Force | Out-Null }; Start-Process explorer.exe $p })

    # ------------------------------------------------------------------ start
    Update-ConfigView
    Add-Recent @()
    Update-Catalog
    $UI.CredText.Text = if ($script:Gui.adminUser) { "$($script:Gui.adminUser) (password on first use)" } else { 'not set' }
    Write-GuiLog "PushPrint v$Version - module loaded from $(Split-Path $ModuleManifest -Parent)"
    if (-not $script:Cfg.sourcePath) { Write-GuiLog 'No settings.json found: using built-in defaults. Open Settings to create one.' 'WARN' }
    if (-not $script:Catalog.Count) { Write-GuiLog 'The catalog is empty. Use Discovery to build it, or add printers on the Catalog page.' 'WARN' }

    $Window.Add_Closing({ try { if ($script:Job) { $script:Job.PS.Stop() }; $Runspace.Close(); $Runspace.Dispose() } catch { Write-Verbose $_ } })
    if ($env:PUSHPRINT_GUI_SMOKE) {
        # test hook: render once, dump a screenshot, exit
        $Window.Add_ContentRendered({
            $script:SmokeTimer = New-Object System.Windows.Threading.DispatcherTimer; $script:SmokeTimer.Interval = [TimeSpan]::FromMilliseconds(800)
            $script:SmokeTimer.Add_Tick({ $script:SmokeTimer.Stop(); try { Save-WindowScreenshot $env:PUSHPRINT_GUI_SMOKE } catch { [Console]::Error.WriteLine("screenshot failed: $($_.Exception.Message)") }; $Window.Close() })
            $script:SmokeTimer.Start()
        })
    }
    function Save-WindowScreenshot([string] $Path) {
        Add-Type -AssemblyName System.Drawing
        $r = New-Object System.Drawing.Rectangle ([int]$Window.Left, [int]$Window.Top, [int]$Window.ActualWidth, [int]$Window.ActualHeight)
        $bmp = New-Object System.Drawing.Bitmap $r.Width, $r.Height
        $g = [System.Drawing.Graphics]::FromImage($bmp); $g.CopyFromScreen($r.Location, [System.Drawing.Point]::Empty, $r.Size); $g.Dispose()
        $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
    }
    [void]$Window.ShowDialog()
}
catch {
    $msg = "$($_.Exception.Message)`n`n$($_.ScriptStackTrace)"
    if ($env:PUSHPRINT_GUI_SMOKE) { $msg | Set-Content -LiteralPath "$($env:PUSHPRINT_GUI_SMOKE).error.txt"; exit 1 }
    Add-Type -AssemblyName PresentationFramework -ErrorAction SilentlyContinue
    try { [void][System.Windows.MessageBox]::Show($msg, 'PushPrint failed to start') } catch { [Console]::Error.WriteLine($msg) }
    exit 1
}
