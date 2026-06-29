<#
.SYNOPSIS
    server-login WPF entry point.
.DESCRIPTION
    Reads servers.yaml, presents a DataGrid with filter / search,
    and launches RDP / Tera Term / PuTTY / WinSCP from the detail pane.
    PowerShell 5.1 compatible.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml

Import-Module -Force (Join-Path $PSScriptRoot 'AppSettings.psm1')
Import-Module -Force (Join-Path $PSScriptRoot 'PasswordProtect.psm1')
Import-Module -Force (Join-Path $PSScriptRoot 'ServerList.psm1')
Import-Module -Force (Join-Path $PSScriptRoot 'ConnectionLauncher.psm1')
Import-Module -Force (Join-Path $PSScriptRoot 'ScreenshotCapture.psm1')

$xamlPath = Join-Path $PSScriptRoot 'MainWindow.xaml'
[xml]$xaml = Get-Content -LiteralPath $xamlPath -Raw -Encoding UTF8
$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

function Find-Control {
    [CmdletBinding()]
    [OutputType([object])]
    param([Parameter(Mandatory = $true)][string]$Name)
    return $window.FindName($Name)
}

# Controls
$refreshButton         = Find-Control 'RefreshButton'
$settingsButton        = Find-Control 'SettingsButton'
$openListButton        = Find-Control 'OpenListButton'
$openLogButton         = Find-Control 'OpenLogButton'
$encryptPasswordButton = Find-Control 'EncryptPasswordButton'
$captureScreenshotButton = Find-Control 'CaptureScreenshotButton'
$serverListPathText    = Find-Control 'ServerListPathText'
$searchBox             = Find-Control 'SearchBox'
$envFilterCombo        = Find-Control 'EnvFilterCombo'
$countText             = Find-Control 'CountText'
$serverGrid            = Find-Control 'ServerGrid'
$detailNameText        = Find-Control 'DetailNameText'
$detailInfoText        = Find-Control 'DetailInfoText'
$warningPanel          = Find-Control 'WarningPanel'
$warningText           = Find-Control 'WarningText'
$connectRdpButton      = Find-Control 'ConnectRdpButton'
$connectSshButton      = Find-Control 'ConnectSshButton'
$connectSftpButton     = Find-Control 'ConnectSftpButton'
$statusBarText         = Find-Control 'StatusBarText'
$serverPanel           = Find-Control 'ServerPanel'
$editServerListButton  = Find-Control 'EditServerListButton'
$closeServerPanelButton = Find-Control 'CloseServerPanelButton'

$state = [PSCustomObject]@{
    AllServers      = @()
    Filtered        = @()
    CaptureSessions = @{}
}

function Get-SelectedServer {
    if ($null -eq $serverGrid.SelectedItem) { return $null }
    return $serverGrid.SelectedItem
}

function Find-VisualParent {
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [AllowNull()]$Start,
        [Parameter(Mandatory = $true)][type]$Type
    )

    $current = $Start -as [System.Windows.DependencyObject]
    while ($null -ne $current) {
        if ($Type.IsInstanceOfType($current)) { return $current }
        try {
            $current = [System.Windows.Media.VisualTreeHelper]::GetParent($current)
        }
        catch {
            return $null
        }
    }
    return $null
}

function Register-CaptureSession {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Server,
        [Parameter(Mandatory = $true)][string]$Id,
        [int]$ProcessId
    )

    if ($ProcessId -le 0) { return }
    $hostName = $Server.EffectiveHost
    if ([string]::IsNullOrWhiteSpace($hostName)) { $hostName = $Server.Name }
    $state.CaptureSessions[[string]$ProcessId] = [PSCustomObject]@{
        HostName = $hostName
        Id       = $Id
    }
}

function Get-ConnectionLogContext {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]$Server,
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Tool
    )

    $settings = Get-AppSettings
    $root = $settings.ScreenshotRootPath
    if ([string]::IsNullOrWhiteSpace($root)) {
        $root = Get-DefaultScreenshotDirectory
    }

    $hostName = $Server.EffectiveHost
    if ([string]::IsNullOrWhiteSpace($hostName)) { $hostName = $Server.Name }
    $dir = Get-SessionLogTargetDirectory -ScreenshotRoot $root -HostName $hostName -Id $Id
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $safeTool = ConvertTo-SafePathSegment -Value $Tool -Fallback 'tool'
    return [PSCustomObject]@{
        HostName      = $hostName
        Id            = $Id
        Directory     = $dir
        ToolLogPath   = (Join-Path $dir "${timestamp}-${safeTool}.log")
        LaunchLogPath = (Join-Path $dir "${timestamp}-${safeTool}-launch.log")
    }
}

function ConvertTo-RedactedArguments {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [AllowNull()][string[]]$Arguments
    )

    if ($null -eq $Arguments) { return @() }
    $result = New-Object System.Collections.Generic.List[string]
    $redactNext = $false
    foreach ($arg in $Arguments) {
        if ($redactNext) {
            $result.Add('<redacted>')
            $redactNext = $false
            continue
        }
        if ($arg -match '^(?i:/passwd=)') {
            $result.Add('/passwd=<redacted>')
            continue
        }
        if ($arg -eq '-pw') {
            $result.Add($arg)
            $redactNext = $true
            continue
        }
        if ($arg -match '^(sftp://[^:/@]+:)[^@]+(@.+)$') {
            $result.Add(($Matches[1] + '<redacted>' + $Matches[2]))
            continue
        }
        $result.Add($arg)
    }
    return $result.ToArray()
}

function Write-ConnectionLaunchLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Result,
        [Parameter(Mandatory = $true)]$LogContext,
        [Parameter(Mandatory = $true)]$Tool
    )

    $argsText = (ConvertTo-RedactedArguments -Arguments $Result.Args) -join ' '
    $lines = @(
        "timestamp: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
        "tool: $Tool",
        "host: $($LogContext.HostName)",
        "id: $($LogContext.Id)",
        "success: $($Result.Success)",
        "process_id: $($Result.ProcessId)",
        "command: $($Result.Command)",
        "arguments: $argsText",
        "message: $($Result.Message)"
    )
    [System.IO.File]::WriteAllLines($LogContext.LaunchLogPath, $lines, (New-Object System.Text.UTF8Encoding $false))
}

function Get-PasswordForServer {
    param($Server)
    if (-not [string]::IsNullOrEmpty($Server.PasswordProtected)) {
        try { return Unprotect-Password -Protected $Server.PasswordProtected }
        catch { throw "暗号化パスワードの復号に失敗しました: $($_.Exception.Message)" }
    }
    if (-not [string]::IsNullOrEmpty($Server.Password)) {
        return $Server.Password
    }
    return $null
}

function Read-PasswordInteractively {
    param([string]$Prompt)
    $cred = $Host.UI.PromptForCredential('server-login', $Prompt, 'user', '')
    if ($null -eq $cred) { return $null }
    return $cred.GetNetworkCredential().Password
}

function Resolve-Password {
    param($Server)
    $pw = Get-PasswordForServer -Server $Server
    if ($null -ne $pw -and $pw -ne '') { return $pw }
    if (-not [string]::IsNullOrEmpty($Server.KeyFile)) { return '' }   # key auth, no password needed
    # No password and no key -> prompt
    return (Read-PasswordInteractively -Prompt "ホスト '$($Server.Name)' のパスワード")
}

function Show-ProtectedPasswordDialog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Server,
        [Parameter(Mandatory = $true)][string]$Password
    )

    [System.Windows.Clipboard]::SetText($Password)
    $dialogXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="暗号化パスワード" Width="420" SizeToContent="Height"
        WindowStartupLocation="CenterOwner" ResizeMode="NoResize">
    <Grid Margin="14">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <TextBlock x:Name="MessageText" Grid.Row="0" TextWrapping="Wrap" Margin="0,0,0,8"/>
        <TextBox x:Name="PasswordBox"
                 Grid.Row="1"
                 IsReadOnly="True"
                 Padding="6,4"
                 Margin="0,0,0,8"
                 FontFamily="Consolas"/>
        <TextBlock Grid.Row="2"
                   Text="クリップボードにもコピーしました。"
                   Foreground="#64748B"
                   FontSize="12"
                   Margin="0,0,0,12"/>
        <StackPanel Grid.Row="3" Orientation="Horizontal" HorizontalAlignment="Right">
            <Button x:Name="CopyButton" Content="再コピー" Width="84" Padding="0,5" Margin="0,0,8,0"/>
            <Button x:Name="CloseButton" Content="閉じる" Width="84" Padding="0,5" IsDefault="True"/>
        </StackPanel>
    </Grid>
</Window>
'@

    [xml]$xamlDoc = $dialogXaml
    $reader = New-Object System.Xml.XmlNodeReader $xamlDoc
    $dialog = [Windows.Markup.XamlReader]::Load($reader)
    $dialog.Owner = $window
    $dialog.FindName('MessageText').Text = "サーバ '$($Server.Name)' の暗号化パスワードを復号しました。"
    $dialog.FindName('PasswordBox').Text = $Password
    $dialog.FindName('CopyButton').Add_Click({
        [System.Windows.Clipboard]::SetText($Password)
    })
    $dialog.FindName('CloseButton').Add_Click({ $dialog.Close() })
    $dialog.ShowDialog() | Out-Null
}

function Convert-KeyEventToHotkeyText {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]$KeyEventArgs
    )

    $modifiers = [System.Windows.Input.Keyboard]::Modifiers
    $key = $KeyEventArgs.Key
    if ($key -eq [System.Windows.Input.Key]::System) {
        $key = $KeyEventArgs.SystemKey
    }
    elseif ($key -eq [System.Windows.Input.Key]::ImeProcessed) {
        $key = $KeyEventArgs.ImeProcessedKey
    }

    $modifierKeys = @(
        [System.Windows.Input.Key]::LeftCtrl,
        [System.Windows.Input.Key]::RightCtrl,
        [System.Windows.Input.Key]::LeftAlt,
        [System.Windows.Input.Key]::RightAlt,
        [System.Windows.Input.Key]::LeftShift,
        [System.Windows.Input.Key]::RightShift,
        [System.Windows.Input.Key]::LWin,
        [System.Windows.Input.Key]::RWin
    )
    if ($modifierKeys -contains $key) {
        return $null
    }

    if ($modifiers -eq [System.Windows.Input.ModifierKeys]::None) {
        throw 'Ctrl / Alt / Shift / Win のいずれかを押しながら指定してください。例: Ctrl+Alt+S'
    }

    $keyText = [string]$key
    if ($keyText -match '^D([0-9])$') {
        $keyText = $Matches[1]
    }
    elseif ($keyText -match '^NumPad([0-9])$') {
        $keyText = $Matches[1]
    }
    elseif ($keyText -match '^(F([1-9]|1[0-2])|[A-Z])$') {
        $keyText = $keyText.ToUpperInvariant()
    }
    else {
        throw "対応していないキーです: $keyText（A-Z / 0-9 / F1-F12 を指定してください）"
    }

    $parts = New-Object System.Collections.Generic.List[string]
    if (($modifiers -band [System.Windows.Input.ModifierKeys]::Control) -ne 0) { $parts.Add('Ctrl') }
    if (($modifiers -band [System.Windows.Input.ModifierKeys]::Alt) -ne 0) { $parts.Add('Alt') }
    if (($modifiers -band [System.Windows.Input.ModifierKeys]::Shift) -ne 0) { $parts.Add('Shift') }
    if (($modifiers -band [System.Windows.Input.ModifierKeys]::Windows) -ne 0) { $parts.Add('Win') }
    $parts.Add($keyText)
    return ($parts -join '+')
}

function Show-WarningIfNeeded {
    param($Server)
    return $true
}

function Resolve-ServerOSFamily {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()][AllowEmptyString()][string]$OS
    )

    $value = ''
    if ($null -ne $OS) { $value = $OS.Trim() }
    if ($value -match '^(?i:win|windows|rdp)$') { return 'Windows' }
    if ($value -match '^(?i:linux|ubuntu|debian|centos|rhel|rocky|alma|amazon\s*linux)$') { return 'Linux' }
    return $value
}

function Get-YamlScalarValue {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) { return '' }
    $text = $Value.Trim()
    if (($text.StartsWith('"') -and $text.EndsWith('"') -and $text.Length -ge 2) -or
        ($text.StartsWith("'") -and $text.EndsWith("'") -and $text.Length -ge 2)) {
        return $text.Substring(1, $text.Length - 2)
    }
    return $text
}

function Find-ServerYamlItem {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [AllowEmptyCollection()][string[]]$Lines,
        [Parameter(Mandatory = $true)]$Server
    )

    if ($null -eq $Lines -or $Lines.Length -eq 0) {
        throw 'サーバ一覧 YAML が空です。'
    }

    $items = New-Object System.Collections.Generic.List[PSCustomObject]
    $insideServers = $false
    $current = $null

    for ($i = 0; $i -lt $Lines.Length; $i++) {
        $line = $Lines[$i]
        if ($line -match '^servers:\s*(#.*)?$') {
            $insideServers = $true
            continue
        }
        if (-not $insideServers) { continue }

        if ($line -match '^\s*-\s*(.*)$') {
            if ($null -ne $current) {
                $current.End = $i - 1
                $items.Add($current)
            }
            $current = [PSCustomObject]@{
                Start                 = $i
                End                   = $i
                Name                  = ''
                Host                  = ''
                User                  = ''
                PasswordLine          = -1
                PasswordProtectedLine = -1
                PasswordIndent        = '    '
            }
            $first = $Matches[1]
            if ($first -match '^([^:#]+):\s*(.*)$') {
                $key = $Matches[1].Trim()
                $value = Get-YamlScalarValue -Value $Matches[2]
                if ($key -eq 'name') { $current.Name = $value }
                elseif ($key -eq 'host' -or $key -eq 'ip') { $current.Host = $value }
                elseif ($key -eq 'user') { $current.User = $value }
                elseif ($key -eq 'password') { $current.PasswordLine = $i; $current.PasswordIndent = '  ' }
                elseif ($key -eq 'password_protected') { $current.PasswordProtectedLine = $i; $current.PasswordIndent = '  ' }
            }
            continue
        }

        if ($null -eq $current) { continue }
        if ($line -match '^(\s+)([^:#]+):\s*(.*)$') {
            $indent = $Matches[1]
            $key = $Matches[2].Trim()
            $value = Get-YamlScalarValue -Value $Matches[3]
            if ($key -eq 'name') { $current.Name = $value }
            elseif ($key -eq 'host' -or $key -eq 'ip') { $current.Host = $value }
            elseif ($key -eq 'user') { $current.User = $value }
            elseif ($key -eq 'password') { $current.PasswordLine = $i; $current.PasswordIndent = $indent }
            elseif ($key -eq 'password_protected') { $current.PasswordProtectedLine = $i; $current.PasswordIndent = $indent }
        }
    }

    if ($null -ne $current) {
        $current.End = $Lines.Length - 1
        $items.Add($current)
    }

    $candidateItems = @()
    foreach ($item in $items) {
        if ($item.Name -ne $Server.Name) { continue }
        $score = 1
        if (-not [string]::IsNullOrWhiteSpace($item.User) -and $item.User -eq $Server.User) { $score += 2 }
        if (-not [string]::IsNullOrWhiteSpace($item.Host) -and ($item.Host -eq $Server.Host -or $item.Host -eq $Server.EffectiveHost)) { $score += 2 }
        $candidateItems += [PSCustomObject]@{ Item = $item; Score = $score }
    }

    if ($candidateItems.Count -eq 0) { return $null }
    return ($candidateItems | Sort-Object -Property Score -Descending | Select-Object -First 1).Item
}

function Protect-PlainPasswordInServerList {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Server
    )

    if ([string]::IsNullOrEmpty($Server.Password)) {
        throw '平文パスワードはありません。'
    }

    $path = Get-EffectiveServerListPath
    if (-not (Test-Path -LiteralPath $path)) {
        throw "サーバ一覧ファイルが見つかりません: $path"
    }

    [string[]]$lines = @([System.IO.File]::ReadAllLines($path, [System.Text.Encoding]::UTF8))
    $item = Find-ServerYamlItem -Lines $lines -Server $Server
    if ($null -eq $item -or $item.PasswordLine -lt 0) {
        throw "YAML 内の対象サーバまたは password 行が見つかりません: $($Server.Name)"
    }

    $cipher = Protect-Password -Plain $Server.Password
    $updated = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $lines.Length; $i++) {
        if ($i -eq $item.PasswordLine) {
            if ($item.PasswordProtectedLine -lt 0) {
                $updated.Add("$($item.PasswordIndent)password_protected: $cipher")
            }
            continue
        }
        if ($i -eq $item.PasswordProtectedLine) {
            $updated.Add("$($item.PasswordIndent)password_protected: $cipher")
            continue
        }
        $updated.Add($lines[$i])
    }

    [System.IO.File]::WriteAllLines($path, $updated.ToArray(), (New-Object System.Text.UTF8Encoding $false))
    return $path
}

function Get-DisplayServer {
    param(
        $Server,
        $Settings
    )
    if ($null -eq $Settings) { $Settings = Get-AppSettings }
    $hasSshTool = (-not [string]::IsNullOrWhiteSpace($Settings.TeraTermPath)) -or (-not [string]::IsNullOrWhiteSpace($Settings.PuTTYPath))
    $osFamily = Resolve-ServerOSFamily -OS $Server.OS
    $hasPlainPassword = -not [string]::IsNullOrEmpty($Server.Password)
    $hasProtectedPassword = -not [string]::IsNullOrEmpty($Server.PasswordProtected)
    $hasKeyFile = -not [string]::IsNullOrWhiteSpace($Server.KeyFile)
    return [PSCustomObject]@{
        Name              = $Server.Name
        OS                = $Server.OS
        OSFamily          = $osFamily
        Host              = $Server.Host
        IP                = $Server.Host
        EffectiveHost     = $Server.EffectiveHost
        User              = $Server.User
        Password          = $Server.Password
        PasswordProtected = $Server.PasswordProtected
        HasPlainPassword  = $hasPlainPassword
        HasProtectedPassword = $hasProtectedPassword
        KeyFile           = $Server.KeyFile
        HasKeyFile        = $hasKeyFile
        Environment       = $Server.Environment
        Role              = $Server.Role
        InDevelopment     = $Server.InDevelopment
        Note              = $Server.Note
        DevelopmentLabel  = if ($Server.InDevelopment) { '開発中' } else { '' }
        CanRdp            = ($osFamily -eq 'Windows')
        CanSsh            = ($osFamily -eq 'Linux' -and $hasSshTool)
        CanSftp           = ($osFamily -eq 'Linux' -and -not [string]::IsNullOrWhiteSpace($Settings.WinSCPPath))
    }
}

function Update-EnvFilterChoices {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'UI helper.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Populates multiple choice items by design.')]
    [CmdletBinding()]
    param()
    if ($null -eq $envFilterCombo) { return }
    $envFilterCombo.ItemsSource = @('(すべて)')
    $envFilterCombo.SelectedIndex = 0
}

function Update-FilteredView {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'UI helper.')]
    [CmdletBinding()]
    param()
    $list = New-Object System.Collections.Generic.List[PSCustomObject]
    foreach ($s in $state.AllServers) {
        $list.Add($s)
    }
    $state.Filtered = $list.ToArray()
    $serverGrid.ItemsSource = $state.Filtered
    $countText.Text = "$($state.Filtered.Length) / $($state.AllServers.Length) 件"
}

function Update-DetailPane {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'UI helper.')]
    [CmdletBinding()]
    param()
    return
}

function Sync-ServerList {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'UI helper.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Loads a list of servers by design.')]
    [CmdletBinding()]
    param()
    try {
        $path = Get-EffectiveServerListPath
        $serverListPathText.Text = "一覧: $path"
        if (-not (Test-Path -LiteralPath $path)) {
            $state.AllServers = @()
            Update-EnvFilterChoices
            Update-FilteredView
            $statusBarText.Text = "サーバ一覧ファイルが見つかりません: $path （[設定] でパスを指定するか、[サーバ一覧を開く] でディレクトリを作成）"
            return
        }
        [object[]]$srvs = Import-ServerList -Path $path
        if ($null -eq $srvs) { $srvs = @() }
        $settings = Get-AppSettings
        $display = New-Object System.Collections.Generic.List[PSCustomObject]
        foreach ($s in $srvs) { $display.Add((Get-DisplayServer -Server $s -Settings $settings)) }
        $state.AllServers = $display.ToArray()
        Update-EnvFilterChoices
        Update-FilteredView
        $statusBarText.Text = "$($state.AllServers.Length) 件のサーバを読み込みました"
    }
    catch {
        $statusBarText.Text = "読込エラー: $($_.Exception.Message)"
    }
}

function Show-SettingsDialog {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'UI helper.')]
    [CmdletBinding()]
    param()

    $settingsXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="server-login 設定" Width="760" MinWidth="720" MinHeight="620"
        SizeToContent="Height" MaxHeight="760"
        WindowStartupLocation="CenterOwner" ResizeMode="CanResize">
    <Grid Margin="14">
        <Grid.RowDefinitions>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <ScrollViewer Grid.Row="0" VerticalScrollBarVisibility="Auto">
            <StackPanel>
                <GroupBox Header="サーバ一覧" Padding="10" Margin="0,0,0,10">
                <Grid>
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                    </Grid.RowDefinitions>
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <TextBlock Grid.Row="0" Grid.ColumnSpan="2" Text="YAML パス" FontWeight="Bold" Margin="0,0,0,4"/>
                    <TextBox x:Name="ServerListPathBox" Grid.Row="1" Grid.Column="0" Padding="4,4"/>
                    <Button x:Name="BrowseListButton" Grid.Row="1" Grid.Column="1" Content="参照..." Padding="10,4" Margin="6,0,0,0"/>
                </Grid>
                </GroupBox>

                <GroupBox Header="接続ツール" Padding="10" Margin="0,0,0,10">
                <Grid>
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                    </Grid.RowDefinitions>
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>

                    <TextBlock Grid.Row="0" Grid.ColumnSpan="2" Text="Tera Term (ttermpro.exe)" FontWeight="Bold" Margin="0,0,0,4"/>
                    <TextBox x:Name="TeraTermPathBox" Grid.Row="1" Grid.Column="0" Padding="4,4" Margin="0,0,0,8"/>
                    <Button x:Name="BrowseTeraTermButton" Grid.Row="1" Grid.Column="1" Content="参照..." Padding="10,4" Margin="6,0,0,8"/>

                    <TextBlock Grid.Row="2" Grid.ColumnSpan="2" Text="PuTTY (putty.exe)" FontWeight="Bold" Margin="0,0,0,4"/>
                    <TextBox x:Name="PuTTYPathBox" Grid.Row="3" Grid.Column="0" Padding="4,4" Margin="0,0,0,8"/>
                    <Button x:Name="BrowsePuTTYButton" Grid.Row="3" Grid.Column="1" Content="参照..." Padding="10,4" Margin="6,0,0,8"/>

                    <StackPanel Grid.Row="4" Grid.ColumnSpan="2" Orientation="Horizontal" Margin="0,0,0,10">
                        <TextBlock Text="既定の SSH クライアント:" VerticalAlignment="Center" Margin="0,0,8,0"/>
                        <RadioButton x:Name="SshTeraTermRadio" Content="Tera Term" GroupName="SshClient" Margin="0,0,12,0"/>
                        <RadioButton x:Name="SshPuTTYRadio" Content="PuTTY" GroupName="SshClient"/>
                    </StackPanel>

                    <TextBlock Grid.Row="5" Grid.ColumnSpan="2" Text="WinSCP (WinSCP.exe)" FontWeight="Bold" Margin="0,0,0,4"/>
                    <TextBox x:Name="WinSCPPathBox" Grid.Row="6" Grid.Column="0" Padding="4,4"/>
                    <Button x:Name="BrowseWinSCPButton" Grid.Row="6" Grid.Column="1" Content="参照..." Padding="10,4" Margin="6,0,0,0"/>
                </Grid>
                </GroupBox>

                <GroupBox Header="記録" Padding="10">
                <Grid>
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                    </Grid.RowDefinitions>
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <TextBlock Grid.Row="0" Grid.ColumnSpan="2" Text="保存先" FontWeight="Bold" Margin="0,0,0,4"/>
                    <TextBox x:Name="ScreenshotRootPathBox" Grid.Row="1" Grid.Column="0" Padding="4,4" Margin="0,0,0,8"/>
                    <Button x:Name="BrowseScreenshotRootButton" Grid.Row="1" Grid.Column="1" Content="参照..." Padding="10,4" Margin="6,0,0,8"/>
                    <TextBlock Grid.Row="2" Grid.ColumnSpan="2" Text="ショートカット" FontWeight="Bold" Margin="0,0,0,4"/>
                    <Border Grid.Row="3" Grid.Column="0" BorderBrush="#CBD5E1" BorderThickness="1" Background="#F8FAFC" Padding="6,5">
                        <TextBlock x:Name="ScreenshotHotkeyBox" Text="Ctrl+Alt+S"/>
                    </Border>
                    <Button x:Name="RecordHotkeyButton" Grid.Row="3" Grid.Column="1" Content="記録" Padding="12,4" Margin="6,0,0,0"/>
                </Grid>
                </GroupBox>
            </StackPanel>
        </ScrollViewer>

        <StackPanel Grid.Row="1" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,12,0,0">
            <Button x:Name="OkButton" Content="OK" Width="90" Padding="0,4" Margin="0,0,8,0" IsDefault="True"/>
            <Button x:Name="CancelButton" Content="キャンセル" Width="90" Padding="0,4" IsCancel="True"/>
        </StackPanel>
    </Grid>
</Window>
'@

    [xml]$xamlDoc = $settingsXaml
    $reader2 = New-Object System.Xml.XmlNodeReader $xamlDoc
    $dialog = [Windows.Markup.XamlReader]::Load($reader2)
    $dialog.Owner = $window

    $serverListPathBox = $dialog.FindName('ServerListPathBox')
    $teraTermPathBox   = $dialog.FindName('TeraTermPathBox')
    $puttyPathBox      = $dialog.FindName('PuTTYPathBox')
    $winscpPathBox     = $dialog.FindName('WinSCPPathBox')
    $screenshotRootPathBox = $dialog.FindName('ScreenshotRootPathBox')
    $screenshotHotkeyBox = $dialog.FindName('ScreenshotHotkeyBox')
    $recordHotkeyButton = $dialog.FindName('RecordHotkeyButton')
    $sshTeraTermRadio  = $dialog.FindName('SshTeraTermRadio')
    $sshPuTTYRadio     = $dialog.FindName('SshPuTTYRadio')

    $current = Get-AppSettings
    if (-not [string]::IsNullOrWhiteSpace($current.ServerListPath)) { $serverListPathBox.Text = $current.ServerListPath }
    else { $serverListPathBox.Text = Get-DefaultServerListPath }
    if (-not [string]::IsNullOrWhiteSpace($current.TeraTermPath))   { $teraTermPathBox.Text   = $current.TeraTermPath }
    if (-not [string]::IsNullOrWhiteSpace($current.PuTTYPath))      { $puttyPathBox.Text      = $current.PuTTYPath }
    if (-not [string]::IsNullOrWhiteSpace($current.WinSCPPath))     { $winscpPathBox.Text     = $current.WinSCPPath }
    if (-not [string]::IsNullOrWhiteSpace($current.ScreenshotRootPath)) { $screenshotRootPathBox.Text = $current.ScreenshotRootPath }
    else { $screenshotRootPathBox.Text = Get-DefaultScreenshotDirectory }
    if (-not [string]::IsNullOrWhiteSpace($current.ScreenshotHotkey)) { $screenshotHotkeyBox.Text = $current.ScreenshotHotkey }
    if ($current.DefaultSshClient -eq 'PuTTY') { $sshPuTTYRadio.IsChecked = $true } else { $sshTeraTermRadio.IsChecked = $true }

    $browseExe = {
        param($targetBox, $title, $filter)
        $ofd = New-Object Microsoft.Win32.OpenFileDialog
        $ofd.Title = $title
        $ofd.Filter = $filter
        if (-not [string]::IsNullOrWhiteSpace($targetBox.Text)) {
            $initDir = Split-Path -Parent $targetBox.Text
            if ((-not [string]::IsNullOrWhiteSpace($initDir)) -and (Test-Path -LiteralPath $initDir)) {
                $ofd.InitialDirectory = $initDir
            }
        }
        if ($ofd.ShowDialog($dialog)) { $targetBox.Text = $ofd.FileName }
    }

    $browseFolder = {
        param($targetBox, $description)
        Add-Type -AssemblyName System.Windows.Forms
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = $description
        $dlg.ShowNewFolderButton = $true
        if (-not [string]::IsNullOrWhiteSpace($targetBox.Text) -and (Test-Path -LiteralPath $targetBox.Text)) {
            $dlg.SelectedPath = $targetBox.Text
        }
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $targetBox.Text = $dlg.SelectedPath
        }
        $dlg.Dispose()
    }

    $dialog.FindName('BrowseListButton').Add_Click({ & $browseExe $serverListPathBox 'サーバ一覧 YAML' 'YAML (*.yaml;*.yml)|*.yaml;*.yml|All files (*.*)|*.*' })
    $dialog.FindName('BrowseTeraTermButton').Add_Click({ & $browseExe $teraTermPathBox 'Tera Term 実行ファイル' 'Executables (*.exe)|*.exe' })
    $dialog.FindName('BrowsePuTTYButton').Add_Click({ & $browseExe $puttyPathBox 'PuTTY 実行ファイル' 'Executables (*.exe)|*.exe' })
    $dialog.FindName('BrowseWinSCPButton').Add_Click({ & $browseExe $winscpPathBox 'WinSCP 実行ファイル' 'Executables (*.exe)|*.exe' })
    $dialog.FindName('BrowseScreenshotRootButton').Add_Click({ & $browseFolder $screenshotRootPathBox '保存先フォルダを選択してください' })

    $hotkeyRecorder = [PSCustomObject]@{
        IsRecording = $false
    }
    $recordHotkeyButton.Add_Click({
        $recordHotkeyButton.Content = 'キーを押してください'
        $recordHotkeyButton.IsDefault = $false
        $hotkeyRecorder.IsRecording = $true
        $dialog.Focus() | Out-Null
    })
    $dialog.Add_PreviewKeyDown({
        param($sender, $e)
        if (-not $hotkeyRecorder.IsRecording) { return }
        if ($e.Key -eq [System.Windows.Input.Key]::Escape) {
            $recordHotkeyButton.Content = '記録'
            $hotkeyRecorder.IsRecording = $false
            $e.Handled = $true
            return
        }
        try {
            $hotkeyText = Convert-KeyEventToHotkeyText -KeyEventArgs $e
            if ([string]::IsNullOrWhiteSpace($hotkeyText)) {
                $e.Handled = $true
                return
            }
            Resolve-ScreenshotHotkey -Hotkey $hotkeyText | Out-Null
            $screenshotHotkeyBox.Text = $hotkeyText
            $recordHotkeyButton.Content = '記録'
            $hotkeyRecorder.IsRecording = $false
            $e.Handled = $true
        }
        catch {
            $recordHotkeyButton.Content = '記録'
            $hotkeyRecorder.IsRecording = $false
            $e.Handled = $true
            [System.Windows.MessageBox]::Show($dialog, $_.Exception.Message, 'ショートカット設定エラー', 'OK', 'Warning') | Out-Null
        }
    })

    $dialog.FindName('OkButton').Add_Click({
        try {
            Resolve-ScreenshotHotkey -Hotkey $screenshotHotkeyBox.Text | Out-Null
            $dialog.DialogResult = $true
            $dialog.Close()
        }
        catch {
            [System.Windows.MessageBox]::Show($dialog, $_.Exception.Message, 'ショートカット設定エラー', 'OK', 'Warning') | Out-Null
        }
    })
    $dialog.FindName('CancelButton').Add_Click({
        $dialog.DialogResult = $false; $dialog.Close()
    })

    if ($dialog.ShowDialog() -eq $true) {
        $sshClient = if ($sshPuTTYRadio.IsChecked -eq $true) { 'PuTTY' } else { 'TeraTerm' }
        Save-AppSettings -ServerListPath $serverListPathBox.Text `
                         -TeraTermPath $teraTermPathBox.Text `
                         -PuTTYPath $puttyPathBox.Text `
                         -WinSCPPath $winscpPathBox.Text `
                         -ScreenshotRootPath $screenshotRootPathBox.Text `
                         -ScreenshotHotkey $screenshotHotkeyBox.Text `
                         -DefaultSshClient $sshClient
        $statusBarText.Text = '設定を保存しました'
        Sync-ServerList
        Register-ScreenshotHotkey
    }
}

function Show-EncryptPasswordDialog {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'UI helper.')]
    [CmdletBinding()]
    param()

    $dlgXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="パスワード暗号化 (DPAPI)" Width="640" Height="320"
        WindowStartupLocation="CenterOwner" ResizeMode="NoResize">
    <Grid Margin="14">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <TextBlock Grid.Row="0" Text="平文パスワード" FontWeight="Bold" Margin="0,0,0,4"/>
        <PasswordBox x:Name="PlainBox" Grid.Row="1" Padding="4,4" Margin="0,0,0,10"/>
        <Button x:Name="EncryptButton" Grid.Row="2" Content="暗号化" Width="120" Padding="0,4" HorizontalAlignment="Left" Margin="0,0,0,10"/>
        <TextBlock Grid.Row="3" Text="暗号文 (servers.yaml の password_protected: に貼り付け)" FontWeight="Bold" Margin="0,0,0,4"/>
        <TextBox x:Name="CipherBox" Grid.Row="4" IsReadOnly="True" AcceptsReturn="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" FontFamily="Consolas" Padding="4,4"/>
        <TextBlock Grid.Row="5" Foreground="Gray" Margin="0,6,0,8" TextWrapping="Wrap" Text="※ 同一 Windows ユーザー・同一マシンでのみ復号可能。別端末では再生成が必要です。"/>
        <StackPanel Grid.Row="6" Orientation="Horizontal" HorizontalAlignment="Right">
            <Button x:Name="CopyButton" Content="クリップボードにコピー" Padding="10,4" Margin="0,0,8,0"/>
            <Button x:Name="CloseButton" Content="閉じる" Width="90" Padding="0,4" IsCancel="True"/>
        </StackPanel>
    </Grid>
</Window>
'@
    [xml]$xd = $dlgXaml
    $r = New-Object System.Xml.XmlNodeReader $xd
    $d = [Windows.Markup.XamlReader]::Load($r)
    $d.Owner = $window
    $plainBox = $d.FindName('PlainBox')
    $cipherBox = $d.FindName('CipherBox')
    $d.FindName('EncryptButton').Add_Click({
        try {
            $p = $plainBox.Password
            if ([string]::IsNullOrEmpty($p)) { $cipherBox.Text = ''; return }
            $cipherBox.Text = Protect-Password -Plain $p
        }
        catch { $cipherBox.Text = "エラー: $($_.Exception.Message)" }
    })
    $d.FindName('CopyButton').Add_Click({
        if (-not [string]::IsNullOrEmpty($cipherBox.Text)) {
            [System.Windows.Clipboard]::SetText($cipherBox.Text)
        }
    })
    $d.FindName('CloseButton').Add_Click({ $d.Close() })
    $d.ShowDialog() | Out-Null
}

function Invoke-ForegroundScreenshot {
    [CmdletBinding()]
    param(
        [switch]$MinimizeFirst
    )

    try {
        if ($MinimizeFirst) {
            $window.WindowState = 'Minimized'
            Start-Sleep -Milliseconds 400
        }
        $settings = Get-AppSettings
        $r = Save-ForegroundWindowScreenshot -ScreenshotRoot $settings.ScreenshotRootPath -ProcessMetadata $state.CaptureSessions
        $statusBarText.Text = "スクリーンショットを保存しました: $($r.Path)"
    }
    catch {
        $statusBarText.Text = "スクリーンショット失敗: $($_.Exception.Message)"
    }
}

function Show-ServerPanel {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'UI helper.')]
    [CmdletBinding()]
    param()

    if ($serverPanel.Visibility -ne 'Visible') {
        $serverPanel.Visibility = 'Visible'
        $window.Width = [Math]::Max($window.Width, 920)
        $window.Height = [Math]::Max($window.Height, 480)
        $window.MinHeight = 360
        Sync-ServerList
        $statusBarText.Text = 'サーバ接続を開きました'
    }
}

function Hide-ServerPanel {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'UI helper.')]
    [CmdletBinding()]
    param()

    $window.WindowState = 'Normal'
    $serverPanel.Visibility = 'Collapsed'
    $window.MinHeight = 112
    $window.MinWidth = 520
    $window.Width = 620
    $window.Height = 118
    $statusBarText.Text = 'Launcher ready'
}

function Toggle-ServerPanel {
    [CmdletBinding()]
    param()

    if ($serverPanel.Visibility -eq 'Visible') { Hide-ServerPanel } else { Show-ServerPanel }
}

function Open-ServerListFile {
    [CmdletBinding()]
    param()

    $path = Get-EffectiveServerListPath
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    if (Test-Path -LiteralPath $path) {
        Start-Process -FilePath 'notepad.exe' -ArgumentList @($path) | Out-Null
        $statusBarText.Text = "サーバ一覧を notepad で開きました: $path"
    }
    else {
        Start-Process -FilePath 'explorer.exe' -ArgumentList @($dir) | Out-Null
        $statusBarText.Text = "ディレクトリを開きました（一覧ファイルなし）: $dir"
    }
}

function Open-LogDirectory {
    [CmdletBinding()]
    param()

    $settings = Get-AppSettings
    $root = $settings.ScreenshotRootPath
    if ([string]::IsNullOrWhiteSpace($root)) {
        $root = Get-DefaultScreenshotDirectory
    }
    $dir = Get-ScreenshotSessionDirectory -ScreenshotRoot $root
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    Start-Process -FilePath 'explorer.exe' -ArgumentList @($dir) | Out-Null
    $statusBarText.Text = "ログ保存先を開きました: $dir"
}

function Invoke-ServerConnection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Server,
        [Parameter(Mandatory = $true)][ValidateSet('RDP','SSH','SFTP')][string]$Kind
    )

    if ($null -eq $Server) {
        $statusBarText.Text = 'サーバ未選択'
        return
    }

    if ($Kind -eq 'RDP') {
        if ($Server.OSFamily -ne 'Windows') { $statusBarText.Text = 'RDP は Windows サーバ用です'; return }
        $logContext = Get-ConnectionLogContext -Server $Server -Id 'rdp' -Tool 'rdp'
        $passwordCopied = $false
        $rdpPassword = Get-PasswordForServer -Server $Server
        if (-not [string]::IsNullOrEmpty($rdpPassword)) {
            [System.Windows.Clipboard]::SetText($rdpPassword)
            $passwordCopied = $true
        }
        $r = Start-RdpSession -Host $Server.EffectiveHost -User $Server.User -LogPath $logContext.ToolLogPath
        Write-ConnectionLaunchLog -Result $r -LogContext $logContext -Tool 'rdp'
        if ($r.Success) { Register-CaptureSession -Server $Server -Id 'rdp' -ProcessId $r.ProcessId }
        if ($r.Success -and $passwordCopied) {
            $statusBarText.Text = "$($r.Message) / パスワードをクリップボードにコピーしました"
        }
        else {
            $statusBarText.Text = $r.Message
        }
        return
    }

    if ($Server.OSFamily -ne 'Linux') {
        $statusBarText.Text = "$Kind は Linux サーバ用です"
        return
    }

    $settings = Get-AppSettings
    $pw = Resolve-Password -Server $Server
    if ($null -eq $pw -and [string]::IsNullOrEmpty($Server.KeyFile)) {
        $statusBarText.Text = 'キャンセル'
        return
    }

    if ($Kind -eq 'SFTP') {
        $logContext = Get-ConnectionLogContext -Server $Server -Id 'winscp' -Tool 'winscp'
        $r = Start-WinSCPSession -ExecutablePath $settings.WinSCPPath -Host $Server.EffectiveHost -User $Server.User -Password $pw -KeyFile $Server.KeyFile -LogPath $logContext.ToolLogPath
        Write-ConnectionLaunchLog -Result $r -LogContext $logContext -Tool 'winscp'
        if ($r.Success) { Register-CaptureSession -Server $Server -Id 'winscp' -ProcessId $r.ProcessId }
        $statusBarText.Text = $r.Message
        return
    }

    $usePuTTY = $false
    if ($settings.DefaultSshClient -eq 'PuTTY' -and -not [string]::IsNullOrWhiteSpace($settings.PuTTYPath)) {
        $usePuTTY = $true
    }
    elseif ([string]::IsNullOrWhiteSpace($settings.TeraTermPath) -and -not [string]::IsNullOrWhiteSpace($settings.PuTTYPath)) {
        $usePuTTY = $true
    }

    if ($usePuTTY) {
        $logContext = Get-ConnectionLogContext -Server $Server -Id 'putty' -Tool 'putty'
        $r = Start-PuTTYSession -ExecutablePath $settings.PuTTYPath -Host $Server.EffectiveHost -User $Server.User -Password $pw -KeyFile $Server.KeyFile -LogPath $logContext.ToolLogPath
        Write-ConnectionLaunchLog -Result $r -LogContext $logContext -Tool 'putty'
        if ($r.Success) { Register-CaptureSession -Server $Server -Id 'putty' -ProcessId $r.ProcessId }
    }
    else {
        $logContext = Get-ConnectionLogContext -Server $Server -Id 'teraterm' -Tool 'teraterm'
        $r = Start-TeraTermSession -ExecutablePath $settings.TeraTermPath -Host $Server.EffectiveHost -User $Server.User -Password $pw -KeyFile $Server.KeyFile -LogPath $logContext.ToolLogPath
        Write-ConnectionLaunchLog -Result $r -LogContext $logContext -Tool 'teraterm'
        if ($r.Success) { Register-CaptureSession -Server $Server -Id 'teraterm' -ProcessId $r.ProcessId }
    }
    $statusBarText.Text = $r.Message
}

$script:ScreenshotHotkeyId = 7211
$script:ScreenshotHotkeyRegistered = $false
$script:ScreenshotHotkeyHandle = [IntPtr]::Zero

function Resolve-ScreenshotHotkey {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [AllowNull()][AllowEmptyString()][string]$Hotkey
    )

    if ([string]::IsNullOrWhiteSpace($Hotkey)) { $Hotkey = 'Ctrl+Alt+S' }

    $parts = $Hotkey -split '\+' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
    if ($parts.Count -lt 1) { throw 'ショートカットが未指定です。例: Ctrl+Alt+S' }

    $modifiers = [uint32]0
    $keyName = $null
    foreach ($part in $parts) {
        switch -Regex ($part) {
            '^(?i:ctrl|control)$' { $modifiers = $modifiers -bor 0x0002; continue }
            '^(?i:alt)$'          { $modifiers = $modifiers -bor 0x0001; continue }
            '^(?i:shift)$'        { $modifiers = $modifiers -bor 0x0004; continue }
            '^(?i:win|windows)$'  { $modifiers = $modifiers -bor 0x0008; continue }
            default {
                if ($null -ne $keyName) { throw "キー指定が複数あります: $Hotkey" }
                $keyName = $part
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($keyName)) {
        throw 'キー本体が未指定です。例: Ctrl+Alt+S'
    }

    $vk = $null
    if ($keyName -match '^(?i:F([1-9]|1[0-2]))$') {
        $vk = [uint32](0x70 + [int]$Matches[1] - 1)
    }
    elseif ($keyName.Length -eq 1) {
        $ch = [char]$keyName.ToUpperInvariant()[0]
        if (($ch -ge [char]'A' -and $ch -le [char]'Z') -or ($ch -ge [char]'0' -and $ch -le [char]'9')) {
            $vk = [uint32][int]$ch
        }
    }

    if ($null -eq $vk) {
        throw "対応していないキーです: $keyName（A-Z / 0-9 / F1-F12 を指定してください）"
    }

    return [PSCustomObject]@{
        Modifiers = $modifiers
        Key       = $vk
        Display   = $Hotkey
    }
}

function Unregister-ScreenshotHotkey {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Unregisters an application hotkey.')]
    [CmdletBinding()]
    param()

    if ($script:ScreenshotHotkeyRegistered -and $script:ScreenshotHotkeyHandle -ne [IntPtr]::Zero) {
        [ServerLogin.WindowInterop]::UnregisterAppHotKey($script:ScreenshotHotkeyHandle, $script:ScreenshotHotkeyId) | Out-Null
    }
    $script:ScreenshotHotkeyRegistered = $false
    $script:ScreenshotHotkeyHandle = [IntPtr]::Zero
}

function Register-ScreenshotHotkey {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Registers an application hotkey for user-triggered screenshot capture.')]
    [CmdletBinding()]
    param()

    try {
        Initialize-ScreenshotNativeMethods
        Unregister-ScreenshotHotkey

        $helper = New-Object System.Windows.Interop.WindowInteropHelper($window)
        $handle = $helper.Handle
        if ($handle -eq [IntPtr]::Zero) { return }

        $settings = Get-AppSettings
        $hotkey = Resolve-ScreenshotHotkey -Hotkey $settings.ScreenshotHotkey
        $registered = [ServerLogin.WindowInterop]::RegisterAppHotKey($handle, $script:ScreenshotHotkeyId, $hotkey.Modifiers, $hotkey.Key)
        if (-not $registered) {
            $statusBarText.Text = "$($hotkey.Display) の登録に失敗しました（他アプリと競合している可能性があります）"
            return
        }

        $source = [System.Windows.Interop.HwndSource]::FromHwnd($handle)
        $source.AddHook({
            param($hwnd, $msg, $wParam, $lParam, [ref]$handled)
            if ($msg -eq 0x0312 -and $wParam.ToInt32() -eq $script:ScreenshotHotkeyId) {
                Invoke-ForegroundScreenshot
                $handled = $true
            }
        })

        $script:ScreenshotHotkeyHandle = $handle
        $script:ScreenshotHotkeyRegistered = $true
        $captureScreenshotButton.ToolTip = "記録 ($($hotkey.Display))"
        $statusBarText.Text = "Launcher ready / Record: $($hotkey.Display)"
    }
    catch {
        $statusBarText.Text = "ホットキー登録エラー: $($_.Exception.Message)"
    }
}

# Event wiring
$refreshButton.Add_Click({ Sync-ServerList })
$settingsButton.Add_Click({
    try { Show-SettingsDialog } catch { $statusBarText.Text = "設定エラー: $($_.Exception.Message)" }
})
$openListButton.Add_Click({ Toggle-ServerPanel })
$openLogButton.Add_Click({
    try { Open-LogDirectory }
    catch { $statusBarText.Text = "ログ保存先を開けませんでした: $($_.Exception.Message)" }
})
$editServerListButton.Add_Click({
    try { Open-ServerListFile }
    catch { $statusBarText.Text = "エラー: $($_.Exception.Message)" }
})
$closeServerPanelButton.Add_Click({ Hide-ServerPanel })
$encryptPasswordButton.Add_Click({
    try { Show-EncryptPasswordDialog } catch { $statusBarText.Text = "エラー: $($_.Exception.Message)" }
})
$captureScreenshotButton.Add_Click({ Invoke-ForegroundScreenshot })

if ($null -ne $searchBox) { $searchBox.Add_TextChanged({ Update-FilteredView }) }
if ($null -ne $envFilterCombo) { $envFilterCombo.Add_SelectionChanged({ Update-FilteredView }) }
$serverGrid.Add_SelectionChanged({ Update-DetailPane })
$serverGrid.Add_MouseDoubleClick({
    param($sender, $e)

    $cell = Find-VisualParent -Start $e.OriginalSource -Type ([System.Windows.Controls.DataGridCell])
    if ($null -eq $cell) { return }

    $server = $cell.DataContext
    if ($null -eq $server) { return }

    if ($null -ne $cell.Column -and ([string]$cell.Column.Header) -eq 'ユーザー' -and $server.HasPlainPassword) {
        $message = "サーバ '$($server.Name)' の平文 password を暗号化し、YAML を password_protected に書き換えます。`n`n元の password 行は削除されます。続行しますか？"
        $answer = [System.Windows.MessageBox]::Show($window, $message, '平文パスワードの暗号化', [System.Windows.MessageBoxButton]::OKCancel, [System.Windows.MessageBoxImage]::Warning)
        if ($answer -ne [System.Windows.MessageBoxResult]::OK) { return }

        try {
            $path = Protect-PlainPasswordInServerList -Server $server
            Sync-ServerList
            $statusBarText.Text = "平文パスワードを暗号化しました: $path"
        }
        catch {
            $statusBarText.Text = "暗号化エラー: $($_.Exception.Message)"
            [System.Windows.MessageBox]::Show($window, $_.Exception.Message, '暗号化エラー', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error) | Out-Null
        }
        $e.Handled = $true
        return
    }

    if (-not [string]::IsNullOrEmpty($server.PasswordProtected)) {
        try {
            $password = Unprotect-Password -Protected $server.PasswordProtected
            if ([string]::IsNullOrEmpty($password)) { return }
            Show-ProtectedPasswordDialog -Server $server -Password $password
            $statusBarText.Text = "暗号化パスワードを表示し、クリップボードにコピーしました: $($server.Name)"
        }
        catch {
            $statusBarText.Text = "復号エラー: $($_.Exception.Message)"
            [System.Windows.MessageBox]::Show($window, $_.Exception.Message, '復号エラー', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error) | Out-Null
        }
        $e.Handled = $true
    }
})
$serverGrid.AddHandler(
    [System.Windows.Controls.Button]::ClickEvent,
    [System.Windows.RoutedEventHandler]{
        param($sender, $e)
        $button = $e.OriginalSource -as [System.Windows.Controls.Button]
        $current = $e.OriginalSource -as [System.Windows.DependencyObject]
        while ($null -eq $button -and $null -ne $current) {
            $current = [System.Windows.Media.VisualTreeHelper]::GetParent($current)
            $button = $current -as [System.Windows.Controls.Button]
        }
        if ($null -eq $button -or [string]::IsNullOrWhiteSpace([string]$button.Tag)) { return }
        $server = $button.DataContext
        if ($null -eq $server) { return }
        try {
            Invoke-ServerConnection -Server $server -Kind ([string]$button.Tag)
        }
        catch {
            $statusBarText.Text = "エラー: $($_.Exception.Message)"
        }
        $e.Handled = $true
    }
)

$connectRdpButton.Add_Click({
    try {
        $sel = Get-SelectedServer
        Invoke-ServerConnection -Server $sel -Kind 'RDP'
    }
    catch { $statusBarText.Text = "エラー: $($_.Exception.Message)" }
})

$connectSshButton.Add_Click({
    try {
        $sel = Get-SelectedServer
        Invoke-ServerConnection -Server $sel -Kind 'SSH'
    }
    catch { $statusBarText.Text = "エラー: $($_.Exception.Message)" }
})

$connectSftpButton.Add_Click({
    try {
        $sel = Get-SelectedServer
        Invoke-ServerConnection -Server $sel -Kind 'SFTP'
    }
    catch { $statusBarText.Text = "エラー: $($_.Exception.Message)" }
})

$window.Add_SourceInitialized({ Register-ScreenshotHotkey })
$window.Add_Closed({
    Unregister-ScreenshotHotkey
})

# Initial load
Sync-ServerList
Update-DetailPane

$window.ShowDialog() | Out-Null
