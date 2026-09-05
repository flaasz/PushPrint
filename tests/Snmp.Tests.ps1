BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\PushPrint\PushPrint.psd1') -Force
    $script:M = Get-Module PushPrint
}

Describe 'BER encoding' {
    It 'encodes short and long lengths' {
        & $M { (ConvertTo-BerLength 5) } | Should -Be @(5)
        & $M { (ConvertTo-BerLength 200) } | Should -Be @(0x81, 200)
        & $M { (ConvertTo-BerLength 300) } | Should -Be @(0x82, 0x01, 0x2C)
    }
    It 'encodes integers as minimal two''s complement' {
        (& $M { ConvertTo-BerInteger 0 })   | Should -Be @(0x02, 0x01, 0x00)
        (& $M { ConvertTo-BerInteger 127 }) | Should -Be @(0x02, 0x01, 0x7F)
        (& $M { ConvertTo-BerInteger 128 }) | Should -Be @(0x02, 0x02, 0x00, 0x80)
        (& $M { ConvertTo-BerInteger -1 })  | Should -Be @(0x02, 0x01, 0xFF)
        (& $M { ConvertTo-BerInteger 1234 }) | Should -Be @(0x02, 0x02, 0x04, 0xD2)
    }
    It 'round-trips OIDs including multi-byte arcs' {
        foreach ($oid in '1.3.6.1.2.1.1.1.0', '1.3.6.1.2.1.43.11.1.1.9.1.1', '1.3.6.1.4.1.2699.1.2.1.2.1.1.3.1', '2.16.840.1.113730.3.4.2') {
            $enc = & $M { param($o) ConvertTo-BerOid $o } $oid
            $enc[0] | Should -Be 0x06
            (& $M { param($b) ConvertFrom-BerOid $b } ($enc[2..($enc.Length - 1)])) | Should -Be $oid
        }
    }
    It 'builds a GetRequest that decodes back to the same OIDs when wrapped as a response' {
        $pkt = & $M { New-SnmpRequest -Oid '1.3.6.1.2.1.1.5.0' -Community 'public' -RequestId 42 }
        # sequence, version 1 (v2c), community "public"
        $pkt[0] | Should -Be 0x30
        ([System.Text.Encoding]::ASCII.GetString($pkt[7..12])) | Should -Be 'public'
        # Turn the request into a response by flipping the PDU tag (0xA0 -> 0xA2) and check the parser.
        $idx = [Array]::IndexOf($pkt, [byte]0xA0)
        $resp = [byte[]]$pkt.Clone(); $resp[$idx] = 0xA2
        $parsed = & $M { param($b) ConvertFrom-SnmpResponse $b } $resp
        $parsed.RequestId | Should -Be 42
        $parsed.VarBinds.Keys | Should -Be @('1.3.6.1.2.1.1.5.0')
        $parsed.VarBinds['1.3.6.1.2.1.1.5.0'].Type | Should -Be 'Null'
    }
}

Describe 'SNMP response decoding' {
    It 'decodes a captured GetResponse with string, integer and counter values' {
        # Hand-built v2c response: requestId 7, varbinds sysName="prn01" (octet string), hrPrinterStatus=3 (int), pages=123456 (Counter32)
        $vb1 = & $M { [byte[]]((ConvertTo-BerOid '1.3.6.1.2.1.1.5.0') + (New-BerTlv -Tag 0x04 -Content ([Text.Encoding]::ASCII.GetBytes('prn01')))) }
        $vb2 = & $M { [byte[]]((ConvertTo-BerOid '1.3.6.1.2.1.25.3.5.1.1.1') + (ConvertTo-BerInteger 3)) }
        $vb3 = & $M { [byte[]]((ConvertTo-BerOid '1.3.6.1.2.1.43.10.2.1.4.1.1') + (New-BerTlv -Tag 0x41 -Content ([byte[]]@(0x01, 0xE2, 0x40)))) }
        $resp = & $M {
            param($a, $b, $c)
            $vbl = New-BerTlv -Tag 0x30 -Content ([byte[]]((New-BerTlv -Tag 0x30 -Content $a) + (New-BerTlv -Tag 0x30 -Content $b) + (New-BerTlv -Tag 0x30 -Content $c)))
            $pdu = New-BerTlv -Tag 0xA2 -Content ([byte[]]((ConvertTo-BerInteger 7) + (ConvertTo-BerInteger 0) + (ConvertTo-BerInteger 0) + $vbl))
            New-BerTlv -Tag 0x30 -Content ([byte[]]((ConvertTo-BerInteger 1) + (New-BerTlv -Tag 0x04 -Content ([Text.Encoding]::ASCII.GetBytes('public'))) + $pdu))
        } $vb1 $vb2 $vb3
        $p = & $M { param($b) ConvertFrom-SnmpResponse $b } $resp
        $p.RequestId | Should -Be 7
        $p.VarBinds['1.3.6.1.2.1.1.5.0'].Value | Should -Be 'prn01'
        $p.VarBinds['1.3.6.1.2.1.25.3.5.1.1.1'].Value | Should -Be 3
        $p.VarBinds['1.3.6.1.2.1.43.10.2.1.4.1.1'].Type | Should -Be 'Counter32'
        $p.VarBinds['1.3.6.1.2.1.43.10.2.1.4.1.1'].Value | Should -Be 123456
    }
    It 'renders non-printable octet strings (MAC addresses) as hex' {
        $tlv = [pscustomobject]@{ Tag = 0x04; Content = [byte[]]@(0x00, 0x20, 0x6B, 0xAA, 0xBB, 0xCC) }
        (& $M { param($t) ConvertFrom-SnmpValue $t } $tlv).Value | Should -Be '00:20:6B:AA:BB:CC'
    }
    It 'decodes hrPrinterDetectedErrorState bit flags' {
        (& $M { ConvertFrom-PrinterErrorState ([byte[]]@(0x50, 0x00)) }) | Should -Be 'noPaper,noToner'
        (& $M { ConvertFrom-PrinterErrorState ([byte[]]@(0x00, 0x08)) }) | Should -Be 'outputFull'
    }
    It 'returns $null for unreachable hosts instead of throwing' {
        (& $M { Invoke-SnmpGet -IPAddress '192.0.2.1' -Oid '1.3.6.1.2.1.1.1.0' -TimeoutMs 150 -Retries 0 }) | Should -BeNullOrEmpty
    }
}
