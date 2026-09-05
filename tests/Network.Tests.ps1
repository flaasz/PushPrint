BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\PushPrint\PushPrint.psd1') -Force
    $script:M = Get-Module PushPrint
}

Describe 'Expand-IPRange' {
    It 'expands a /29 to six hosts' {
        $ips = & $M { Expand-IPRange '10.0.0.0/29' }
        $ips | Should -Be @('10.0.0.1', '10.0.0.2', '10.0.0.3', '10.0.0.4', '10.0.0.5', '10.0.0.6')
    }
    It 'expands a /24 to 254 hosts' {
        (& $M { Expand-IPRange '192.168.1.0/24' }).Count | Should -Be 254
    }
    It 'treats /31 and /32 without dropping network/broadcast' {
        (& $M { Expand-IPRange '10.0.0.4/31' }) | Should -Be @('10.0.0.4', '10.0.0.5')
        (& $M { Expand-IPRange '10.0.0.9/32' }) | Should -Be @('10.0.0.9')
    }
    It 'expands a-b ranges across octet boundaries' {
        (& $M { Expand-IPRange '10.0.0.254-10.0.1.1' }) | Should -Be @('10.0.0.254', '10.0.0.255', '10.0.1.0', '10.0.1.1')
    }
    It 'passes single addresses through' {
        (& $M { Expand-IPRange '172.16.5.7' }) | Should -Be @('172.16.5.7')
    }
    It 'refuses ranges above the host limit' {
        { & $M { Expand-IPRange '10.0.0.0/8' -MaxHosts 65536 } } | Should -Throw '*limit*'
    }
    It 'rejects garbage' {
        { & $M { Expand-IPRange 'printer01' } } | Should -Throw
    }
}

Describe 'Test-IPInSubnet' {
    It 'matches inside and rejects outside' {
        (& $M { Test-IPInSubnet -Cidr '10.16.17.0/24' -IPAddress '10.16.17.200' }) | Should -BeTrue
        (& $M { Test-IPInSubnet -Cidr '10.16.17.0/24' -IPAddress '10.16.18.1' }) | Should -BeFalse
        (& $M { Test-IPInSubnet -Cidr '10.16.16.0/22' -IPAddress '10.16.19.255' }) | Should -BeTrue
        (& $M { Test-IPInSubnet -Cidr '10.16.16.0/22' -IPAddress '10.16.20.0' }) | Should -BeFalse
    }
    It 'returns false for malformed input' {
        (& $M { Test-IPInSubnet -Cidr 'nope' -IPAddress '10.0.0.1' }) | Should -BeFalse
        (& $M { Test-IPInSubnet -Cidr '10.0.0.0/24' -IPAddress 'host' }) | Should -BeFalse
    }
}

Describe 'Test-TcpPort' {
    It 'returns false quickly for a closed port on an unroutable address' {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        (& $M { Test-TcpPort -ComputerName '192.0.2.1' -Port 9100 -TimeoutMs 300 }) | Should -BeFalse
        $sw.ElapsedMilliseconds | Should -BeLessThan 3000
    }
}

Describe 'Get-PrinterSite' {
    It 'picks the longest matching prefix' {
        $table = @(
            [pscustomobject]@{ Site = 'BIG';   Subnet = '10.16.0.0/16' }
            [pscustomobject]@{ Site = 'KUJ';   Subnet = '10.16.17.0/24' }
            [pscustomobject]@{ Site = 'KUJ-2'; Subnet = '10.16.17.128/25' }
        )
        (Get-PrinterSite -IPAddress '10.16.17.200' -SubnetTable $table).Site | Should -Be 'KUJ-2'
        (Get-PrinterSite -IPAddress '10.16.17.5' -SubnetTable $table).Site | Should -Be 'KUJ'
        (Get-PrinterSite -IPAddress '10.16.99.1' -SubnetTable $table).Site | Should -Be 'BIG'
        (Get-PrinterSite -IPAddress '10.99.0.1' -SubnetTable $table).Site | Should -BeNullOrEmpty
    }
}
