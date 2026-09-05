# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.2.0] - 2026-09-06

First public structure. Everything company-specific from the original scripts was removed; configuration now lives in `settings.json`.

### Added
- `PushPrint` PowerShell module (Windows PowerShell 5.1 and PowerShell 7) with:
  - `Install-RemotePrinter`, `Remove-RemotePrinter`, `Get-RemotePrinter` - agentless remote management over SMB + DCOM, multiple computers per call, result objects.
  - `Invoke-PrinterDiscovery` - builds a verified catalog from SNMP, DHCP and print servers, reconciled by IP and scoped to AD sites.
  - `Find-SnmpPrinter`, `Get-PrinterSnmpInfo`, `Test-PrinterOnline` - pure PowerShell SNMP v2c (no COM, no DLLs): model, serial, MAC, status, supplies.
  - `Find-DhcpPrinter` - DHCP leases/reservations filtered by printer MAC vendors.
  - `Get-PrintServerQueue` - shared queues with **Direct vs Pull** classification (SafeQ, PaperCut, Printix... detected by port monitor, driver, configured pull servers or a live probe).
  - `Get-AdSiteSubnet`, `Get-PrinterSite` - AD Sites and Services subnets as discovery zones.
  - `Get-PrinterCatalog`, `Save-PrinterCatalog` (merge by IP, keeps manual edits), `Compare-PrinterCatalog`.
- PushPrint GUI (WPF, custom Fluent-style theme, dark/light): Install, Machines, Discovery, Catalog, Settings pages and a live activity log.
- Pester 5 tests, PSScriptAnalyzer settings, GitHub Actions CI (5.1 + 7), release packaging.

### Changed
- Credentials no longer touch a command line (`net use` replaced by `New-SmbMapping`).
- Worker scripts ship as files instead of embedded strings.
- Catalog format v2 (`{ version, generated, printers[] }`); legacy plain arrays are still read.

### Removed
- Hard-coded print servers, vendor list, admin account naming and the company printer list.
- VBS launcher (replaced by `PushPrint.cmd`).

## [0.1.0] - 2026-09-05
- Internal prototype: three loose scripts and a WPF launcher.
