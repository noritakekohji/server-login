#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

Describe 'ServerList' {
    BeforeAll {
        $script:ModulePath = (Resolve-Path (Join-Path $PSScriptRoot '..\ServerList.psm1')).Path
        Import-Module $script:ModulePath -Force

        $script:Tmp = [System.IO.Path]::GetTempFileName()
        $yaml = @'
# comment line
servers:
  - name: web-prod-01
    os: Linux
    ip: 10.0.1.10
    user: ec2-user
    environment: 本番
    role: 一般
    note: "comment with: colon"
  - name: app-prod-01
    os: Windows
    user: Administrator
    environment: 本番
    role: 管理者
    in_development: true
  - name: only-name
    # most fields omitted
'@
        # Write the file as UTF-8 with no BOM via .NET (PS 5.1's Set-Content -Encoding UTF8 writes BOM)
        [System.IO.File]::WriteAllText($script:Tmp, $yaml, (New-Object System.Text.UTF8Encoding $false))
    }

    AfterAll {
        if (Test-Path -LiteralPath $script:Tmp) { Remove-Item -LiteralPath $script:Tmp -Force }
        Remove-Module ServerList -ErrorAction SilentlyContinue
    }

    Context 'Import-ServerList' {
        It 'reads all server entries' {
            $srvs = Import-ServerList -Path $script:Tmp
            $srvs.Count | Should -Be 3
        }
        It 'parses fields including Japanese' {
            $srvs = Import-ServerList -Path $script:Tmp
            $a = $srvs | Where-Object Name -EQ 'web-prod-01'
            $a.OS | Should -Be 'Linux'
            $a.EffectiveHost | Should -Be '10.0.1.10'
            $a.User | Should -Be 'ec2-user'
            $a.Environment | Should -Be '本番'
            $a.Role | Should -Be '一般'
            $a.Note | Should -Be 'comment with: colon'
            $a.InDevelopment | Should -BeFalse
        }
        It 'recognizes in_development true' {
            $srvs = Import-ServerList -Path $script:Tmp
            $b = $srvs | Where-Object Name -EQ 'app-prod-01'
            $b.InDevelopment | Should -BeTrue
        }
        It 'falls back EffectiveHost to name when IP omitted' {
            $srvs = Import-ServerList -Path $script:Tmp
            $b = $srvs | Where-Object Name -EQ 'app-prod-01'
            $b.EffectiveHost | Should -Be 'app-prod-01'
            $c = $srvs | Where-Object Name -EQ 'only-name'
            $c.EffectiveHost | Should -Be 'only-name'
        }
        It 'defaults OS to Linux when not specified' {
            $srvs = Import-ServerList -Path $script:Tmp
            $c = $srvs | Where-Object Name -EQ 'only-name'
            $c.OS | Should -Be 'Linux'
        }
    }

    Context 'Import-ServerList missing file' {
        It 'throws on missing file' {
            { Import-ServerList -Path 'X:\does\not\exist.yaml' } | Should -Throw
        }
    }
}
