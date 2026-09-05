BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\PushPrint\PushPrint.psd1') -Force
    $script:TempDir = Join-Path ([IO.Path]::GetTempPath()) "PushPrintCatalog-$([guid]::NewGuid())"
    New-Item -ItemType Directory -Path $script:TempDir | Out-Null
}
AfterAll { Remove-Item $script:TempDir -Recurse -Force -ErrorAction SilentlyContinue }

Describe 'Get-PrinterCatalog' {
    It 'reads the legacy v1 array and maps location to site' {
        $file = Join-Path $script:TempDir 'v1.json'
        '[ { "name": "HPM426HR", "ip": "10.1.1.31", "vendor": "HP", "location": "HQ", "note": "same IP as: X" } ]' | Set-Content $file -Encoding UTF8
        $c = @(Get-PrinterCatalog -Path $file)
        $c.Count | Should -Be 1
        $c[0].site | Should -Be 'HQ'
        $c[0].location | Should -BeNullOrEmpty
        $c[0].flags | Should -Be @()
    }
    It 'returns nothing for a missing file' {
        @(Get-PrinterCatalog -Path (Join-Path $script:TempDir 'nope.json')).Count | Should -Be 0
    }
}

Describe 'Save-PrinterCatalog / Get-PrinterCatalog round trip' {
    BeforeAll {
        $script:file = Join-Path $script:TempDir 'cat.json'
        $script:a = [pscustomobject]@{ name = 'KM-HR'; ip = '10.1.1.20'; vendor = 'KM'; model = 'bizhub C3351'; serial = 'A1'; site = 'HQ'; sources = @('snmp'); flags = @(); note = 'manual note' }
        $script:b = [pscustomobject]@{ name = 'HP-KADR'; ip = '10.1.1.31'; vendor = 'HP'; model = $null; serial = $null; site = 'HQ'; sources = @('dhcp'); flags = @('no-snmp'); note = $null }
    }
    It 'writes a v2 envelope' {
        @($script:a, $script:b) | Save-PrinterCatalog -Path $script:file
        $doc = Get-Content $script:file -Raw | ConvertFrom-Json
        $doc.version | Should -Be 2
        $doc.count | Should -Be 2
        @(Get-PrinterCatalog -Path $script:file).Count | Should -Be 2
    }
    It 'filters by site, vendor and search' {
        @(Get-PrinterCatalog -Path $script:file -Vendor HP).name | Should -Be 'HP-KADR'
        @(Get-PrinterCatalog -Path $script:file -Search 'C3351').name | Should -Be 'KM-HR'
        @(Get-PrinterCatalog -Path $script:file -Site 'H*').Count | Should -Be 2
    }
    It 'merges by IP, keeps manual name/note, updates discovered facts, keeps unseen printers' {
        $upd = [pscustomobject]@{ name = 'bizhub-c3351-hr'; ip = '10.1.1.20'; vendor = 'KM'; model = 'bizhub C3351'; serial = 'A1-NEW'; site = 'HQ'; sources = @('snmp', 'printserver'); flags = @('name-mismatch'); note = $null }
        $new = [pscustomobject]@{ name = 'XRX-1'; ip = '10.1.1.40'; vendor = 'XEROX'; site = 'HQ'; sources = @('snmp'); flags = @() }
        @($upd, $new) | Save-PrinterCatalog -Path $script:file -Merge
        $c = Get-PrinterCatalog -Path $script:file
        @($c).Count | Should -Be 3
        $km = $c | Where-Object ip -eq '10.1.1.20'
        $km.name | Should -Be 'KM-HR'             # manual name preserved
        $km.note | Should -Be 'manual note'
        $km.serial | Should -Be 'A1-NEW'          # fact updated
        $km.flags | Should -Contain 'name-mismatch'
        ($c | Where-Object ip -eq '10.1.1.31').name | Should -Be 'HP-KADR'   # untouched
    }
    It 'overwrites names when asked' {
        $upd = [pscustomobject]@{ name = 'renamed'; ip = '10.1.1.20' }
        @($upd) | Save-PrinterCatalog -Path $script:file -Merge -OverwriteNames
        (Get-PrinterCatalog -Path $script:file | Where-Object ip -eq '10.1.1.20').name | Should -Be 'renamed'
    }
    It 'keys pull queues by server\share when they have no IP' {
        $pull = [pscustomobject]@{ name = 'SafeQ-Secure'; ip = $null; printServer = 'print01'; shareName = 'SafeQ-Secure'; queueKind = 'Pull'; flags = @('pull-queue') }
        @($pull) | Save-PrinterCatalog -Path $script:file -Merge
        @($pull) | Save-PrinterCatalog -Path $script:file -Merge
        @(Get-PrinterCatalog -Path $script:file | Where-Object queueKind -eq 'Pull').Count | Should -Be 1
    }
}

Describe 'Compare-PrinterCatalog' {
    It 'reports added, removed and changed' {
        $ref = @(
            [pscustomobject]@{ name = 'A'; ip = '10.0.0.1'; vendor = 'KM'; model = 'X' }
            [pscustomobject]@{ name = 'B'; ip = '10.0.0.2'; vendor = 'HP' }
        )
        $dif = @(
            [pscustomobject]@{ name = 'A'; ip = '10.0.0.1'; vendor = 'KM'; model = 'Y' }
            [pscustomobject]@{ name = 'C'; ip = '10.0.0.3'; vendor = 'XEROX' }
        )
        $r = Compare-PrinterCatalog -Reference $ref -Difference $dif
        ($r | Where-Object Change -eq 'Changed').Details | Should -Match "model : 'X' -> 'Y'"
        ($r | Where-Object Change -eq 'Added').Name | Should -Be 'C'
        ($r | Where-Object Change -eq 'Removed').Name | Should -Be 'B'
    }
}
