#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

Describe 'AppSettings' {
    BeforeAll {
        $script:ModulePath = (Resolve-Path (Join-Path $PSScriptRoot '..\AppSettings.psm1')).Path
        Import-Module $script:ModulePath -Force
    }

    BeforeEach {
        $script:OldLocalAppData = $env:LOCALAPPDATA
        $script:TmpLocalAppData = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:TmpLocalAppData -Force | Out-Null
        $env:LOCALAPPDATA = $script:TmpLocalAppData
    }

    AfterEach {
        $env:LOCALAPPDATA = $script:OldLocalAppData
        if (Test-Path -LiteralPath $script:TmpLocalAppData) {
            Remove-Item -LiteralPath $script:TmpLocalAppData -Recurse -Force
        }
    }

    AfterAll {
        Remove-Module AppSettings -ErrorAction SilentlyContinue
    }

    It 'persists ScreenshotRootPath with other settings' {
        Save-AppSettings -ServerListPath 'C:\servers.yaml' `
                         -TeraTermPath 'C:\tools\ttermpro.exe' `
                         -PuTTYPath 'C:\tools\putty.exe' `
                         -WinSCPPath 'C:\tools\WinSCP.exe' `
                         -DefaultSshClient 'PuTTY' `
                         -ScreenshotRootPath 'D:\worklogs' `
                         -ScreenshotHotkey 'Ctrl+Shift+9'

        $settings = Get-AppSettings
        $settings.ServerListPath | Should -Be 'C:\servers.yaml'
        $settings.DefaultSshClient | Should -Be 'PuTTY'
        $settings.ScreenshotRootPath | Should -Be 'D:\worklogs'
        $settings.ScreenshotHotkey | Should -Be 'Ctrl+Shift+9'
    }

    It 'defaults screenshot settings' {
        $settings = Get-AppSettings
        $settings.ScreenshotRootPath | Should -BeNullOrEmpty
        $settings.ScreenshotHotkey | Should -Be 'Ctrl+Alt+S'
    }
}
