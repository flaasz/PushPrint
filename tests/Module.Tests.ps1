BeforeAll {
    $script:Root = Join-Path $PSScriptRoot '..'
    $script:Manifest = Join-Path $script:Root 'src\PushPrint\PushPrint.psd1'
    Import-Module $script:Manifest -Force
}

Describe 'Module manifest' {
    It 'is valid' {
        { Test-ModuleManifest -Path $script:Manifest -ErrorAction Stop } | Should -Not -Throw
    }
    It 'exports exactly the public functions' {
        $public = (Get-ChildItem (Join-Path $script:Root 'src\PushPrint\Public') -Filter *.ps1).BaseName | Sort-Object
        $exported = (Get-Command -Module PushPrint -CommandType Function).Name | Sort-Object
        $exported | Should -Be $public
        $manifest = Import-PowerShellDataFile $script:Manifest
        ($manifest.FunctionsToExport | Sort-Object) | Should -Be $public
    }
    It 'every public function has comment-based help with a synopsis and an example' {
        foreach ($cmd in Get-Command -Module PushPrint -CommandType Function) {
            $h = Get-Help $cmd.Name
            $h.Synopsis | Should -Not -BeNullOrEmpty -Because "$($cmd.Name) needs .SYNOPSIS"
            $h.Examples | Should -Not -BeNullOrEmpty -Because "$($cmd.Name) needs .EXAMPLE"
        }
    }
    It 'ships the worker scripts' {
        foreach ($w in 'Install-Printer.worker.ps1', 'Connect-Queue.worker.ps1', 'Remove-Connection.worker.ps1') {
            Join-Path $script:Root "src\PushPrint\Workers\$w" | Should -Exist
        }
    }
    It 'worker scripts parse' {
        foreach ($f in Get-ChildItem (Join-Path $script:Root 'src\PushPrint\Workers') -Filter *.ps1) {
            $errors = $null
            [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errors) | Out-Null
            $errors | Should -BeNullOrEmpty -Because "$($f.Name) must parse"
        }
    }
}

Describe 'Repository hygiene' {
    It 'contains no committed site-specific settings or catalog' {
        Join-Path $script:Root 'config\settings.json' | Should -Not -Exist
        Join-Path $script:Root 'printers.json' | Should -Not -Exist
    }
    It 'has an example config that is valid JSON' {
        { Get-Content (Join-Path $script:Root 'config\settings.example.json') -Raw | ConvertFrom-Json } | Should -Not -Throw
    }
    It 'GUI XAML parses' {
        Add-Type -AssemblyName PresentationFramework
        $xamlFile = Join-Path $script:Root 'src\Gui\MainWindow.xaml'
        $xamlFile | Should -Exist
        [xml]$xml = Get-Content $xamlFile -Raw
        { [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xml)) } | Should -Not -Throw
    }
}
