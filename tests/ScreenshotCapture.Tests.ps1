#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

Describe 'ScreenshotCapture' {
    BeforeAll {
        $script:ModulePath = (Resolve-Path (Join-Path $PSScriptRoot '..\ScreenshotCapture.psm1')).Path
        Import-Module $script:ModulePath -Force
    }

    AfterAll {
        Remove-Module ScreenshotCapture -ErrorAction SilentlyContinue
    }

    Context 'Path helpers' {
        It 'uses the Desktop as the default screenshot root' {
            $path = Get-DefaultScreenshotDirectory
            $path | Should -Be ([Environment]::GetFolderPath('Desktop'))
        }

        It 'sanitizes window titles for file names' {
            $safe = ConvertTo-SafePathSegment -Value 'Tera Term: web/prod*01?'
            $safe | Should -Be 'Tera_Term__web_prod_01_'
        }

        It 'uses fallback for blank path segment' {
            ConvertTo-SafePathSegment -Value '   ' -Fallback 'foreground' | Should -Be 'foreground'
        }

        It 'builds date and Windows user session folder name' {
            $name = Get-ScreenshotSessionFolderName -Date ([datetime]'2026-06-27') -WindowsUserId 'DOMAIN\kohji'
            $name | Should -Be '2026-06-27-DOMAIN_kohji'
        }

        It 'places the session folder below the configured root' {
            $dir = Get-ScreenshotSessionDirectory -ScreenshotRoot 'C:\capture-root' -Date ([datetime]'2026-06-27') -WindowsUserId 'kohji'
            $dir | Should -Be 'C:\capture-root\2026-06-27-kohji'
        }

        It 'places captures below the session capture folder' {
            $dir = Get-ScreenshotCaptureDirectory -ScreenshotRoot 'C:\capture-root' -Date ([datetime]'2026-06-27') -WindowsUserId 'kohji'
            $dir | Should -Be 'C:\capture-root\2026-06-27-kohji\capture'
        }

        It 'places logs below the session log folder' {
            $dir = Get-ScreenshotLogDirectory -ScreenshotRoot 'C:\capture-root' -Date ([datetime]'2026-06-27') -WindowsUserId 'kohji'
            $dir | Should -Be 'C:\capture-root\2026-06-27-kohji\log'
        }

        It 'builds process folder names from registered connection metadata' {
            $info = [PSCustomObject]@{ ProcessId = 17024; ProcessName = 'putty' }
            $metadata = @{
                '17024' = [PSCustomObject]@{ HostName = 'iam.f5.si'; Id = 'putty' }
            }

            Get-CaptureProcessFolderName -WindowInfo $info -ProcessMetadata $metadata | Should -Be 'iam.f5.si-putty'
        }

        It 'falls back to local for unregistered windows' {
            $info = [PSCustomObject]@{ ProcessId = 17968; ProcessName = 'WindowsTerminal' }

            Get-CaptureProcessFolderName -WindowInfo $info | Should -Be 'local'
        }

        It 'builds session log target folders below log by host and id' {
            $dir = Get-SessionLogTargetDirectory -ScreenshotRoot 'C:\capture-root' -HostName 'iam.f5.si' -Id 'putty' -Date ([datetime]'2026-06-27') -WindowsUserId 'kohji'
            $dir | Should -Be 'C:\capture-root\2026-06-27-kohji\log\iam.f5.si-putty'
        }
    }
}
