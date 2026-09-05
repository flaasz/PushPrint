BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\PushPrint\PushPrint.psd1') -Force
    $script:M = Get-Module PushPrint
    $script:TempDir = Join-Path ([IO.Path]::GetTempPath()) "PushPrintTests-$([guid]::NewGuid())"
    New-Item -ItemType Directory -Path $script:TempDir | Out-Null
}
AfterAll { Remove-Item $script:TempDir -Recurse -Force -ErrorAction SilentlyContinue }

Describe 'Get-PushPrintConfig' {
    It 'throws when an explicit path does not exist' {
        { Get-PushPrintConfig -Path (Join-Path $script:TempDir 'missing.json') } | Should -Throw '*not found*'
    }
    It 'defaults expose every vendor with a driver name and a match pattern' {
        $cfg = & $M { Get-PushPrintDefaultConfig }
        foreach ($k in $cfg.drivers.Keys) {
            $cfg.drivers[$k].driverName | Should -Not -BeNullOrEmpty -Because "$k needs driverName"
            $cfg.drivers[$k].matchPattern | Should -Not -BeNullOrEmpty -Because "$k needs matchPattern"
        }
        $cfg.pullQueueMarkers | Should -Contain 'SafeQ'
    }
    It 'deep-merges a settings file over the defaults' {
        $file = Join-Path $script:TempDir 'settings.json'
        @'
{
  "adminUserPattern": "{domain}\\svc-{user}",
  "printServers": { "HQ": "print01" },
  "drivers": { "KM": { "driverName": "KONICA MINOLTA Universal V4 PCL" }, "NEW": { "driverName": "X", "matchPattern": "NewCo", "macPrefixes": ["AABBCC"] } },
  "discovery": { "excludeSubnets": [], "maxThreads": 8 }
}
'@ | Set-Content -Path $file -Encoding UTF8
        $cfg = Get-PushPrintConfig -Path $file
        $cfg.adminUserPattern | Should -Be '{domain}\svc-{user}'
        $cfg.printServers.HQ | Should -Be 'print01'
        $cfg.drivers.KM.driverName | Should -Be 'KONICA MINOLTA Universal V4 PCL'
        $cfg.drivers.KM.matchPattern | Should -Not -BeNullOrEmpty     # kept from defaults
        $cfg.drivers.HP.driverName | Should -Be 'HP Universal Printing PCL 6'
        $cfg.drivers.NEW.macPrefixes | Should -Be @('AABBCC')
        $cfg.discovery.maxThreads | Should -Be 8
        $cfg.discovery.probePorts | Should -Be @(9100, 631, 515)
        @($cfg.discovery.excludeSubnets).Count | Should -Be 0        # empty array stays an empty array, not $null
        $cfg.sourcePath | Should -Be $file
    }
    It 'expands environment variables in paths' {
        $file = Join-Path $script:TempDir 'paths.json'
        '{ "catalogPath": "%TEMP%\\printers.json" }' | Set-Content -Path $file -Encoding UTF8
        (Get-PushPrintConfig -Path $file).catalogPath | Should -Be (Join-Path $env:TEMP 'printers.json')
    }
    It 'reports invalid JSON clearly' {
        $file = Join-Path $script:TempDir 'bad.json'
        '{ not json' | Set-Content -Path $file
        { Get-PushPrintConfig -Path $file } | Should -Throw '*not valid JSON*'
    }
}

Describe 'Resolve-AdminUserName / Resolve-PrinterDriver' {
    It 'substitutes domain and user' {
        (& $M { Resolve-AdminUserName -Pattern '{domain}\adm{user}' }) | Should -Be "$env:USERDOMAIN\adm$env:USERNAME"
    }
    It 'resolves vendor keys case-insensitively and rejects unknown ones' {
        $cfg = & $M { Get-PushPrintDefaultConfig }
        (& $M { param($c) Resolve-PrinterDriver -Vendor 'km' -Config $c } $cfg).DriverName | Should -Be 'KONICA MINOLTA Universal PCL'
        { & $M { param($c) Resolve-PrinterDriver -Vendor 'NOPE' -Config $c } $cfg } | Should -Throw '*Unknown vendor*'
    }
}

Describe 'Get-VendorMatch' {
    BeforeAll { $script:drivers = (& $M { Get-PushPrintDefaultConfig }).drivers }
    It 'prefers description over MAC' {
        (& $M { param($d) Get-VendorMatch -Drivers $d -Description 'KONICA MINOLTA bizhub C3351' -Mac '00:1B:78:00:00:01' } $script:drivers) | Should -Be 'KM'
    }
    It 'falls back to MAC OUI' {
        (& $M { param($d) Get-VendorMatch -Drivers $d -Mac '00-20-6b-12-34-56' } $script:drivers) | Should -Be 'KM'
        (& $M { param($d) Get-VendorMatch -Drivers $d -Mac '9C934E123456' } $script:drivers) | Should -Be 'XEROX'
    }
    It 'distinguishes DesignJet from other HP' {
        (& $M { param($d) Get-VendorMatch -Drivers $d -Description 'HP DesignJet T830' } $script:drivers) | Should -Be 'HPDJ'
        (& $M { param($d) Get-VendorMatch -Drivers $d -Description 'HP LaserJet M426' } $script:drivers) | Should -Be 'HP'
    }
    It 'returns $null when nothing matches' {
        (& $M { param($d) Get-VendorMatch -Drivers $d -Description 'Cisco IOS' -Mac 'FFFFFF000000' } $script:drivers) | Should -BeNullOrEmpty
    }
}
