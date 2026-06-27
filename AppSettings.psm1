<#
.SYNOPSIS
    server-login application settings persistence.
.DESCRIPTION
    Stores user settings under %LOCALAPPDATA%\server-login\settings.json.
    Tracks: TeraTermPath / PuTTYPath / WinSCPPath / DefaultSshClient / ServerListPath / ScreenshotRootPath / ScreenshotHotkey.
    PowerShell 5.1 compatible.
#>

Set-StrictMode -Version Latest

function Get-SettingsDirectory {
    return (Join-Path $env:LOCALAPPDATA 'server-login')
}

function Get-SettingsPath {
    return (Join-Path (Get-SettingsDirectory) 'settings.json')
}

function Get-DefaultServerListPath {
    return (Join-Path $env:USERPROFILE '.server-login\servers.yaml')
}

function Get-AppSettings {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Settings is a domain-standard plural noun.')]
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param()

    $defaults = [PSCustomObject]@{
        TeraTermPath     = $null
        PuTTYPath        = $null
        WinSCPPath       = $null
        DefaultSshClient = 'TeraTerm'  # TeraTerm or PuTTY
        ServerListPath   = $null
        ScreenshotRootPath = $null
        ScreenshotHotkey = 'Ctrl+Alt+S'
    }

    $path = Get-SettingsPath
    if (-not (Test-Path -LiteralPath $path)) { return $defaults }

    try {
        $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return $defaults }
        $obj = $raw | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        Write-Warning "Failed to read settings: $($_.Exception.Message). Using defaults."
        return $defaults
    }

    $result = [PSCustomObject]@{
        TeraTermPath     = $defaults.TeraTermPath
        PuTTYPath        = $defaults.PuTTYPath
        WinSCPPath       = $defaults.WinSCPPath
        DefaultSshClient = $defaults.DefaultSshClient
        ServerListPath   = $defaults.ServerListPath
        ScreenshotRootPath = $defaults.ScreenshotRootPath
        ScreenshotHotkey = $defaults.ScreenshotHotkey
    }

    foreach ($k in 'TeraTermPath','PuTTYPath','WinSCPPath','DefaultSshClient','ServerListPath','ScreenshotRootPath','ScreenshotHotkey') {
        if ($obj.PSObject.Properties.Name -contains $k) {
            $v = $obj.$k
            if ($null -ne $v -and -not [string]::IsNullOrWhiteSpace([string]$v)) {
                $result.$k = [string]$v
            }
        }
    }

    if ($result.DefaultSshClient -ne 'TeraTerm' -and $result.DefaultSshClient -ne 'PuTTY') {
        $result.DefaultSshClient = 'TeraTerm'
    }

    return $result
}

function Save-AppSettings {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'User-driven setting persistence.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Settings is a domain-standard plural noun.')]
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()][string]$TeraTermPath,
        [AllowNull()][AllowEmptyString()][string]$PuTTYPath,
        [AllowNull()][AllowEmptyString()][string]$WinSCPPath,
        [ValidateSet('TeraTerm', 'PuTTY')][string]$DefaultSshClient = 'TeraTerm',
        [AllowNull()][AllowEmptyString()][string]$ServerListPath,
        [AllowNull()][AllowEmptyString()][string]$ScreenshotRootPath,
        [AllowNull()][AllowEmptyString()][string]$ScreenshotHotkey
    )

    $dir = Get-SettingsDirectory
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $norm = {
        param($v)
        if ([string]::IsNullOrWhiteSpace($v)) { return $null }
        return $v.Trim()
    }

    $obj = [PSCustomObject]@{
        TeraTermPath     = & $norm $TeraTermPath
        PuTTYPath        = & $norm $PuTTYPath
        WinSCPPath       = & $norm $WinSCPPath
        DefaultSshClient = $DefaultSshClient
        ServerListPath   = & $norm $ServerListPath
        ScreenshotRootPath = & $norm $ScreenshotRootPath
        ScreenshotHotkey = if ([string]::IsNullOrWhiteSpace($ScreenshotHotkey)) { 'Ctrl+Alt+S' } else { $ScreenshotHotkey.Trim() }
    }
    $json = $obj | ConvertTo-Json -Depth 3
    Set-Content -LiteralPath (Get-SettingsPath) -Value $json -Encoding UTF8 -ErrorAction Stop
}

function Get-EffectiveServerListPath {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $settings = Get-AppSettings
    if (-not [string]::IsNullOrWhiteSpace($settings.ServerListPath)) {
        return $settings.ServerListPath
    }
    return (Get-DefaultServerListPath)
}

Export-ModuleMember -Function Get-AppSettings, Save-AppSettings, Get-SettingsPath, Get-DefaultServerListPath, Get-EffectiveServerListPath
