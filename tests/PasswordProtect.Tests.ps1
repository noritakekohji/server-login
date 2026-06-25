#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

Describe 'PasswordProtect' {
    BeforeAll {
        $script:ModulePath = (Resolve-Path (Join-Path $PSScriptRoot '..\PasswordProtect.psm1')).Path
        Import-Module $script:ModulePath -Force
    }
    AfterAll {
        Remove-Module PasswordProtect -ErrorAction SilentlyContinue
    }

    Context 'Protect/Unprotect round-trip' {
        It 'roundtrips ASCII passwords' {
            $plain = 'Hello-World-123!'
            $enc = Protect-Password -Plain $plain
            $enc | Should -Not -Be $plain
            (Unprotect-Password -Protected $enc) | Should -Be $plain
        }

        It 'roundtrips Japanese passwords' {
            $plain = 'パスワード-日本語-1!'
            $enc = Protect-Password -Plain $plain
            (Unprotect-Password -Protected $enc) | Should -Be $plain
        }

        It 'returns empty string for empty input' {
            (Protect-Password -Plain '') | Should -Be ''
            (Unprotect-Password -Protected '') | Should -Be ''
        }

        It 'produces different ciphertexts for the same input (random IV)' {
            $a = Protect-Password -Plain 'same'
            $b = Protect-Password -Plain 'same'
            $a | Should -Not -Be $b
        }
    }

    Context 'Test-IsProtectedPassword' {
        It 'returns true for actual ciphertext' {
            $enc = Protect-Password -Plain 'x'
            Test-IsProtectedPassword -Value $enc | Should -BeTrue
        }
        It 'returns false for plaintext-looking values' {
            Test-IsProtectedPassword -Value 'plaintext' | Should -BeFalse
            Test-IsProtectedPassword -Value '' | Should -BeFalse
            Test-IsProtectedPassword -Value '0123' | Should -BeFalse
        }
    }
}
