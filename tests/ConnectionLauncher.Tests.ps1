#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

Describe 'ConnectionLauncher' {
    BeforeAll {
        $script:ModulePath = (Resolve-Path (Join-Path $PSScriptRoot '..\ConnectionLauncher.psm1')).Path
        Import-Module $script:ModulePath -Force

        # Create a dummy "executable" that exists on disk (Start-Process won't actually be invoked here)
        $script:DummyExe = [System.IO.Path]::GetTempFileName()
    }

    AfterAll {
        if (Test-Path -LiteralPath $script:DummyExe) { Remove-Item -LiteralPath $script:DummyExe -Force }
        Remove-Module ConnectionLauncher -ErrorAction SilentlyContinue
    }

    Context 'Argument shapes (Start-Process mocked)' {
        BeforeEach {
            Mock -ModuleName ConnectionLauncher Start-Process { }
        }

        It 'Tera Term with password builds /auth=password and /passwd=' {
            $r = Start-TeraTermSession -ExecutablePath $script:DummyExe -Host '10.0.0.1' -User 'u1' -Password 'p1'
            $r.Success | Should -BeTrue
            $r.Args | Should -Contain '/auth=password'
            $r.Args | Should -Contain '/passwd=p1'
            $r.Args | Should -Contain '/user=u1'
        }

        It 'Tera Term with key file builds /auth=publickey and /keyfile=' {
            $r = Start-TeraTermSession -ExecutablePath $script:DummyExe -Host '10.0.0.1' -User 'u1' -KeyFile 'C:\k.pem'
            $r.Success | Should -BeTrue
            $r.Args | Should -Contain '/auth=publickey'
            $r.Args | Should -Contain '/keyfile=C:\k.pem'
        }

        It 'PuTTY with password uses -pw' {
            $r = Start-PuTTYSession -ExecutablePath $script:DummyExe -Host 'h' -User 'u' -Password 'pw'
            $r.Args | Should -Contain '-pw'
            $r.Args | Should -Contain 'pw'
            $r.Args | Should -Contain '-ssh'
        }

        It 'PuTTY with key uses -i and skips -pw' {
            $r = Start-PuTTYSession -ExecutablePath $script:DummyExe -Host 'h' -User 'u' -KeyFile 'C:\k.ppk' -Password 'pw'
            $r.Args | Should -Contain '-i'
            $r.Args | Should -Contain 'C:\k.ppk'
            ($r.Args -contains '-pw') | Should -BeFalse
        }

        It 'WinSCP encodes user:password into sftp URL' {
            $r = Start-WinSCPSession -ExecutablePath $script:DummyExe -Host 'h' -User 'u' -Password 'p@ss'
            ($r.Args[0]) | Should -BeLike 'sftp://u:p%40ss@h/*'
        }

        It 'WinSCP with key omits password from URL and adds /privatekey' {
            $r = Start-WinSCPSession -ExecutablePath $script:DummyExe -Host 'h' -User 'u' -Password 'unused' -KeyFile 'C:\k.ppk'
            ($r.Args[0]) | Should -BeLike 'sftp://u@h/*'
            $r.Args | Should -Contain '/privatekey=C:\k.ppk'
        }
    }

    Context 'Missing executable path' {
        It 'returns failure when ExecutablePath is empty' {
            $r = Start-TeraTermSession -ExecutablePath '' -Host 'h'
            $r.Success | Should -BeFalse
            $r.Message | Should -Match 'Tera Term'
        }
        It 'returns failure when file does not exist' {
            $r = Start-PuTTYSession -ExecutablePath 'X:\nope.exe' -Host 'h'
            $r.Success | Should -BeFalse
        }
    }
}
