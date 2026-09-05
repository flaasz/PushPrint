BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\PushPrint\PushPrint.psd1') -Force
    $script:M = Get-Module PushPrint
    $script:markers = @('SafeQ', 'YSoft', 'PaperCut', 'Secure', 'Pull')
}

Describe 'Resolve-QueueKind (Direct vs Pull detection)' {
    It 'flags a queue whose port monitor is the SafeQ port monitor as Pull' {
        $r = & $M { param($m) Resolve-QueueKind -QueueName 'KM Office 2F' -PortName 'IP_10.1.1.5' -HostAddress '10.1.1.5' -PortMonitor 'YSoft SafeQ Port Monitor' -PullMarkers $m } $script:markers
        $r.Kind | Should -Be 'Pull'; $r.Confidence | Should -Be 'High'; $r.Reason | Should -Match 'port monitor'
    }
    It 'flags a queue pointing at a configured pull server as Pull even with a plain TCP/IP port' {
        $r = & $M { param($m) Resolve-QueueKind -QueueName 'Biuro' -PortName 'IP_10.9.9.9' -HostAddress '10.9.9.9' -PortMonitor 'Standard TCP/IP Port' -PullMarkers $m -PullServers @('10.9.9.9') } $script:markers
        $r.Kind | Should -Be 'Pull'; $r.Reason | Should -Match 'pull-print server'
    }
    It 'matches markers as whole words only (Secure does not match "Secured-Site")' {
        $r = & $M { param($m) Resolve-QueueKind -QueueName 'Secured-Site' -PortName 'IP_10.1.1.7' -HostAddress '10.1.1.7' -PullMarkers $m } $script:markers
        $r.Kind | Should -Be 'Direct'
        $r2 = & $M { param($m) Resolve-QueueKind -QueueName 'HQ Secure Print' -PortName 'IP_10.1.1.7' -HostAddress '10.1.1.7' -PullMarkers $m } $script:markers
        $r2.Kind | Should -Be 'Pull'
    }
    It 'classifies local ports' {
        (& $M { Resolve-QueueKind -QueueName 'PDF' -PortName 'PORTPROMPT:' }).Kind | Should -Be 'Local'
        (& $M { Resolve-QueueKind -QueueName 'Fax' -PortName 'SHRFAX:' }).Kind | Should -Be 'Local'
    }
    It 'uses probe results: Printer-MIB answer means Direct' {
        $r = & $M { Resolve-QueueKind -QueueName 'X' -PortName 'IP_1' -HostAddress '10.1.1.1' -Probe @{ IsPrinter = $true; PrinterPortOpen = $true; SmbOpen = $false } }
        $r.Kind | Should -Be 'Direct'; $r.Confidence | Should -Be 'High'
    }
    It 'uses probe results: SMB-only host means Pull (medium confidence)' {
        $r = & $M { Resolve-QueueKind -QueueName 'X' -PortName 'IP_1' -HostAddress '10.1.1.1' -Probe @{ IsPrinter = $false; PrinterPortOpen = $false; SmbOpen = $true } }
        $r.Kind | Should -Be 'Pull'; $r.Confidence | Should -Be 'Medium'
    }
    It 'uses probe results: nothing answered means Unknown' {
        $r = & $M { Resolve-QueueKind -QueueName 'X' -PortName 'IP_1' -HostAddress '10.1.1.1' -Probe @{ IsPrinter = $false; PrinterPortOpen = $false; SmbOpen = $false } }
        $r.Kind | Should -Be 'Unknown'
    }
    It 'without a probe a TCP/IP port is Direct with low confidence' {
        $r = & $M { Resolve-QueueKind -QueueName 'X' -PortName 'IP_1' -HostAddress '10.1.1.1' }
        $r.Kind | Should -Be 'Direct'; $r.Confidence | Should -Be 'Low'
    }
}
