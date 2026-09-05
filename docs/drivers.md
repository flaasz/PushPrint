# Driver packages

Direct-IP installs need the vendor's universal driver on the target. The module pushes it only when the target does not already have it.

## Layout

```text
<driverRoot>\
  KM\        <- extracted Konica Minolta Universal PCL package (INF, CAT, DLLs...)
  HP\        <- extracted HP Universal Print Driver PCL 6
  XEROX\
  KM.zip     <- generated automatically from KM\ (rebuilt when the folder is newer)
```

`driverRoot` defaults to `%ProgramData%\PushPrint\drivers` and is set in `settings.json`. Folder names are the vendor keys from the `drivers` table.

## The driver name must match the INF

`driverName` in `settings.json` has to be the exact model name from the INF, otherwise `Add-PrinterDriver` fails. Find it with:

```powershell
Select-String -Path "$env:ProgramData\PushPrint\drivers\KM\*.inf" -Pattern 'Universal' | Select-Object -First 5
```

Defaults shipped with the module:

| Key | Driver name | Notes |
| --- | --- | --- |
| KM | KONICA MINOLTA Universal PCL | v3 UPD. The V4 package uses `KONICA MINOLTA Universal V4 PCL` |
| HP | HP Universal Printing PCL 6 | LaserJet / OfficeJet / PageWide, not DesignJet |
| HPDJ | HP DesignJet Universal Print Driver | T-series. DesignJet 500/1050 need their own HP-GL/2 driver |
| XEROX | Xerox Global Print Driver PCL6 | |
| RICOH | PCL6 Driver for Universal Print | |
| CANON | Canon Generic Plus PCL6 | |
| KYOCERA | Kyocera Universal Printing Driver | verify against your package |
| BROTHER | Brother Universal Printer (PCL) | verify |
| LEXMARK | Lexmark Universal v2 PCL 6 | verify |
| EPSON | EPSON Universal Print Driver | verify |

## What happens on the target

1. `pnputil /add-driver <inf>` stages the package in the driver store. The catalog's signer is added to *Trusted Publishers* first so the unattended install does not stall on the "trust this publisher" prompt.
2. `Add-PrinterDriver -Name <driverName>` registers it with the spooler.
3. A Standard TCP/IP port `IP_<address>` (RAW 9100 by default, `-Protocol LPR` available) and the printer are created machine-wide.

## Type 3 vs Type 4, and the end of third-party drivers

Universal drivers above are Type 3 (v3). Microsoft stopped publishing new third-party drivers through Windows Update in January 2026 and Windows Protected Print mode blocks them entirely. Vendor packages still install fine from files, which is what this module does. A driverless mode (Microsoft IPP Class Driver) is on the roadmap.
