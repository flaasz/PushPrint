<#
.SYNOPSIS
    Local + CI build: lint (PSScriptAnalyzer), test (Pester 5), package (zip of the module + GUI).
.EXAMPLE
    .\build\build.ps1                # lint + test
    .\build\build.ps1 -Task Package  # also produce out\PushPrint-<version>.zip
#>
[CmdletBinding()]
param(
    # Accepts an array (-Task Lint,Test from a PowerShell prompt) or a comma-separated string ("Lint,Test" when launched via -File).
    [string[]] $Task = @('Lint', 'Test'),
    [switch] $CI
)
$ErrorActionPreference = 'Stop'
$Task = @($Task -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$known = 'Lint', 'Test', 'Package', 'All'
foreach ($t in $Task) { if ($t -notin $known) { throw "Unknown task '$t'. Valid: $($known -join ', ')" } }
$Root = Split-Path -Parent $PSScriptRoot
$Out  = Join-Path $Root 'out'
$failed = $false

function Install-RequiredModule($Name, $MinVersion) {
    if (-not (Get-Module -ListAvailable $Name | Where-Object { -not $MinVersion -or $_.Version -ge [version]$MinVersion })) {
        Write-Host "Installing $Name..." -ForegroundColor Yellow
        Install-Module $Name -MinimumVersion $MinVersion -Scope CurrentUser -Force -SkipPublisherCheck
    }
}

if ($Task -contains 'All') { $Task = @('Lint', 'Test', 'Package') }

if ($Task -contains 'Lint') {
    Install-RequiredModule PSScriptAnalyzer
    Write-Host '== PSScriptAnalyzer' -ForegroundColor Cyan
    $settings = Join-Path $PSScriptRoot 'PSScriptAnalyzerSettings.psd1'
    $findings = Invoke-ScriptAnalyzer -Path (Join-Path $Root 'src') -Recurse -Settings $settings
    $findings | Format-Table Severity, RuleName, @{n = 'File'; e = { Split-Path $_.ScriptPath -Leaf } }, Line, Message -AutoSize -Wrap
    $bad = @($findings | Where-Object Severity -in 'Error', 'Warning')
    if ($bad.Count) { Write-Host "$($bad.Count) warning(s)/error(s)" -ForegroundColor Red; $failed = $true } else { Write-Host 'clean' -ForegroundColor Green }
}

if ($Task -contains 'Test') {
    Install-RequiredModule Pester 5.5.0
    Import-Module Pester -MinimumVersion 5.5.0
    Write-Host '== Pester' -ForegroundColor Cyan
    $cfg = New-PesterConfiguration
    $cfg.Run.Path = Join-Path $Root 'tests'
    $cfg.Run.PassThru = $true
    $cfg.Output.Verbosity = if ($CI) { 'Detailed' } else { 'Normal' }
    $cfg.TestResult.Enabled = $true
    $cfg.TestResult.OutputPath = Join-Path $Root 'testResults.xml'
    $cfg.TestResult.OutputFormat = 'NUnitXml'
    $res = Invoke-Pester -Configuration $cfg
    if ($res.FailedCount -gt 0) { $failed = $true }
}

if ($Task -contains 'Package') {
    Write-Host '== Package' -ForegroundColor Cyan
    $manifest = Import-PowerShellDataFile (Join-Path $Root 'src\PushPrint\PushPrint.psd1')
    $version = $manifest.ModuleVersion
    New-Item -ItemType Directory -Path $Out -Force | Out-Null
    $stage = Join-Path $Out "PushPrint-$version"
    if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
    New-Item -ItemType Directory -Path $stage | Out-Null
    Copy-Item (Join-Path $Root 'src\PushPrint') -Destination (Join-Path $stage 'PushPrint') -Recurse
    Copy-Item (Join-Path $Root 'src\Gui') -Destination (Join-Path $stage 'Gui') -Recurse
    Copy-Item (Join-Path $Root 'config\settings.example.json') -Destination $stage
    Copy-Item (Join-Path $Root 'README.md'), (Join-Path $Root 'LICENSE'), (Join-Path $Root 'CHANGELOG.md') -Destination $stage
    $zip = "$stage.zip"
    if (Test-Path $zip) { Remove-Item $zip -Force }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    # Retry: AV / indexers sometimes still hold freshly copied files for a moment.
    $attempt = 0
    while ($true) {
        try { [IO.Compression.ZipFile]::CreateFromDirectory($stage, $zip, [IO.Compression.CompressionLevel]::Optimal, $false); break }
        catch {
            if (++$attempt -ge 5) { throw "Packaging failed: $($_.Exception.Message)" }
            if (Test-Path $zip) { Remove-Item $zip -Force }
            Start-Sleep -Seconds 2
        }
    }
    $entries = ([IO.Compression.ZipFile]::OpenRead($zip)).Entries.Count
    Write-Host "-> $zip ($entries files)" -ForegroundColor Green
}

if ($failed) { Write-Host 'BUILD FAILED' -ForegroundColor Red; exit 1 }
Write-Host 'BUILD OK' -ForegroundColor Green
