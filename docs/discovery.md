# Discovery: how the catalog gets built and verified

Generated printer lists drift: printers get replaced, IPs get reused, queue names stop matching the device. Discovery rebuilds the list from what is actually on the network and tells you where the sources disagree.

## Zones first

Scanning a whole /8 finds every printer in the company, and thousands elsewhere. Discovery is therefore scoped to **AD sites**: `Get-AdSiteSubnet` reads *Sites and Services* over ADSI (no RSAT needed) and each site's subnets become the scan range. Sites without subnets in AD can be defined in `settings.json`:

```json
"sites": { "Warehouse-East": ["10.99.10.0/24"] }
```

## Three sources, reconciled by IP

| Source | Cmdlet | What it contributes | Cost |
| --- | --- | --- | --- |
| SNMP scan | `Find-SnmpPrinter` | What the device says about itself: sysName, model, serial, MAC, location, status | seconds per /24 (parallel) |
| DHCP | `Find-DhcpPrinter` | Leases/reservations whose MAC belongs to a printer vendor: host names, confirmation | instant; needs RSAT DHCP tools |
| Print servers | `Get-PrintServerQueue` | Share names users see, port host address, **Direct vs Pull** | fast; read access to the spooler |

`Invoke-PrinterDiscovery` runs the sources that are available and merges everything by IP. The result uses the catalog schema:

```text
name, ip, mac, vendor, model, serial, site, location,
printServer, shareName, queueKind, hostName, snmpName, dhcpName,
sources[], flags[], note, lastSeen
```

The proposed `name` is, in order: print server share name, DNS host name, DHCP host name, SNMP sysName, model + IP.

## Flags: what needs a human

| Flag | Meaning |
| --- | --- |
| `name-mismatch` | The queue/DNS name differs from the printer's own SNMP name. Probably a swapped device or a stale queue. |
| `duplicate-ip` | Several print server queues point at the same IP (the others are listed in `note`). |
| `pull-queue` | The queue goes through a pull-print server (SafeQ, PaperCut...) rather than straight to a device. Install it as a print server queue, not direct IP, or accounting is bypassed. |
| `no-snmp` | Seen in DHCP or on a print server but not answering SNMP: powered off, SNMP disabled, or a wrong community string. |
| `unknown-vendor` | No configured driver pattern matched. Add a vendor to `drivers` in `settings.json`. |

## Direct vs Pull detection

A print server queue is classified by `Resolve-QueueKind` using, in order:

1. Port host address is in `pullPrintServers` -> **Pull**
2. Port monitor, port description, driver, queue name or comment contains a marker from `pullQueueMarkers` (`SafeQ`, `YSoft`, `PaperCut`, `Printix`, `Secure`, ...) -> **Pull**
3. Non-network port (LPT, FILE, PORTPROMPT...) -> **Local**
4. With `-Probe` (default in discovery): the port host answers the Printer-MIB over SNMP or accepts a connection on 9100/631/515 -> **Direct**; answers SMB/RPC but no printer port -> **Pull** (medium confidence)
5. Otherwise **Direct** with low confidence

Direct-IP installs of a printer that users are supposed to reach through a pull queue take them out of accounting and secure release. The GUI switches to *Print server queue* mode automatically when a pull queue is picked.

## Typical workflow

```powershell
Import-Module .\src\PushPrint

# one site
Invoke-PrinterDiscovery -Site KUJ | Save-PrinterCatalog -Merge

# what changed since last time?
Compare-PrinterCatalog -Reference (Get-PrinterCatalog -Site KUJ) -Difference (Invoke-PrinterDiscovery -Site KUJ) | Format-Table

# everything, nightly
Invoke-PrinterDiscovery -All | Save-PrinterCatalog -Merge
Get-PrinterCatalog | Test-PrinterOnline | Where-Object { -not $_.Online }
```

`Save-PrinterCatalog -Merge` keeps hand-edited names and notes; discovered facts (model, serial, MAC, site) are updated. Printers not seen in this run stay in the file, so a powered-off device does not vanish from the catalog.

## SNMP details

The module implements SNMP v2c GET/GETNEXT itself (BER encoding over UDP), so it works identically on PowerShell 5.1 and 7 with no COM objects or DLLs. Community string, timeout and retries are in the `snmp` section of `settings.json`. OIDs used: system group, `hrDeviceDescr`, `hrPrinterStatus`, `hrPrinterDetectedErrorState`, `prtGeneralPrinterName`, `prtGeneralSerialNumber`, `prtMarkerLifeCount`, `prtMarkerSupplies*`, `ifPhysAddress`.
