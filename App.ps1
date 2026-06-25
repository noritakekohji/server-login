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
$encryptPasswordButton = Find-Control 'EncryptPasswordButton'
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

$state = [PSCustomObject]@{
    AllServers = @()
    Filtered   = @()
}

function Get-SelectedServer {
    if ($null -eq $serverGrid.SelectedItem) { return $null }
    return $serverGrid.SelectedItem
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

function Show-WarningIfNeeded {
    param($Server)
    $msgs = New-Object System.Collections.Generic.List[string]
    if (-not $Server.InDevelopment) {
        if ($Server.Environment -eq '本番') {
            $msgs.Add("本番環境です。")
        }
        if ($Server.Role -eq '管理者') {
            $msgs.Add("管理者権限で接続します。")
        }
    }
    if ($msgs.Count -eq 0) { return $true }
    $body = ($msgs -join "`n") + "`n`nホスト: $($Server.Name) ($($Server.EffectiveHost))`nユーザ: $($Server.User)`n`n続行しますか？"
    $r = [System.Windows.MessageBox]::Show($window, $body, '接続前の確認', 'YesNo', 'Warning')
    return ($r -eq 'Yes')
}

function Get-DisplayServer {
    param($Server)
    return [PSCustomObject]@{
        Name              = $Server.Name
        OS                = $Server.OS
        IP                = $Server.IP
        EffectiveHost     = $Server.EffectiveHost
        User              = $Server.User
        Password          = $Server.Password
        PasswordProtected = $Server.PasswordProtected
        KeyFile           = $Server.KeyFile
        Environment       = $Server.Environment
        Role              = $Server.Role
        InDevelopment     = $Server.InDevelopment
        Note              = $Server.Note
        DevelopmentLabel  = if ($Server.InDevelopment) { '開発中' } else { '' }
    }
}

function Update-EnvFilterChoices {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'UI helper.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Populates multiple choice items by design.')]
    [CmdletBinding()]
    param()
    $envs = New-Object System.Collections.Generic.List[string]
    $envs.Add('(すべて)')
    $seen = @{}
    foreach ($s in $state.AllServers) {
        $e = $s.Environment
        if (-not [string]::IsNullOrWhiteSpace($e) -and -not $seen.ContainsKey($e)) {
            $seen[$e] = $true
            $envs.Add($e)
        }
    }
    $envFilterCombo.ItemsSource = $envs.ToArray()
    $envFilterCombo.SelectedIndex = 0
}

function Update-FilteredView {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'UI helper.')]
    [CmdletBinding()]
    param()
    $q = if ($null -ne $searchBox.Text) { $searchBox.Text.Trim() } else { '' }
    $envChoice = if ($null -ne $envFilterCombo.SelectedItem) { [string]$envFilterCombo.SelectedItem } else { '(すべて)' }
    $list = New-Object System.Collections.Generic.List[PSCustomObject]
    foreach ($s in $state.AllServers) {
        if ($envChoice -ne '(すべて)' -and $s.Environment -ne $envChoice) { continue }
        if (-not [string]::IsNullOrEmpty($q)) {
            $hay = "$($s.Name) $($s.EffectiveHost) $($s.User) $($s.Note) $($s.Environment) $($s.Role)"
            if ($hay.IndexOf($q, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
        }
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
    $sel = Get-SelectedServer
    if ($null -eq $sel) {
        $detailNameText.Text = ''
        $detailInfoText.Text = ''
        $warningPanel.Visibility = 'Collapsed'
        $connectRdpButton.IsEnabled = $false
        $connectSshButton.IsEnabled = $false
        $connectSftpButton.IsEnabled = $false
        return
    }
    $detailNameText.Text = $sel.Name
    $auth = if (-not [string]::IsNullOrEmpty($sel.KeyFile)) { "鍵: $($sel.KeyFile)" }
            elseif (-not [string]::IsNullOrEmpty($sel.PasswordProtected)) { 'パスワード: (暗号化済)' }
            elseif (-not [string]::IsNullOrEmpty($sel.Password)) { 'パスワード: (平文設定)' }
            else { 'パスワード: 接続時に入力' }
    $envLabel = if ([string]::IsNullOrWhiteSpace($sel.Environment)) { '(未設定)' } else { $sel.Environment }
    if ($sel.InDevelopment) { $envLabel = "$envLabel (開発中)" }
    $roleLabel = if ([string]::IsNullOrWhiteSpace($sel.Role)) { '(未設定)' } else { $sel.Role }
    $detailInfoText.Text = "OS: $($sel.OS)`n接続先: $($sel.EffectiveHost)`nユーザ: $($sel.User)`n$auth`n環境: $envLabel`n権限: $roleLabel"

    # Warning preview
    $warns = New-Object System.Collections.Generic.List[string]
    if (-not $sel.InDevelopment) {
        if ($sel.Environment -eq '本番') { $warns.Add('本番環境') }
        if ($sel.Role -eq '管理者') { $warns.Add('管理者権限') }
    }
    if ($warns.Count -gt 0) {
        $warningText.Text = '⚠ ' + ($warns -join ' / ') + ' — 接続時に確認ダイアログが出ます'
        $warningPanel.Visibility = 'Visible'
    }
    else {
        $warningPanel.Visibility = 'Collapsed'
    }

    $connectRdpButton.IsEnabled  = ($sel.OS -eq 'Windows')
    $connectSshButton.IsEnabled  = ($sel.OS -eq 'Linux')
    $connectSftpButton.IsEnabled = ($sel.OS -eq 'Linux')
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
        $display = New-Object System.Collections.Generic.List[PSCustomObject]
        foreach ($s in $srvs) { $display.Add((Get-DisplayServer -Server $s)) }
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
        Title="server-login 設定" Width="720" Height="380"
        WindowStartupLocation="CenterOwner" ResizeMode="NoResize">
    <Grid Margin="14">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <TextBlock Grid.Row="0" Text="サーバ一覧 YAML パス" FontWeight="Bold" Margin="0,0,0,4"/>
        <Grid Grid.Row="1" Margin="0,0,0,12">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBox x:Name="ServerListPathBox" Grid.Column="0" Padding="4,4"/>
            <Button x:Name="BrowseListButton" Grid.Column="1" Content="参照..." Padding="10,4" Margin="6,0,0,0"/>
        </Grid>

        <TextBlock Grid.Row="2" Text="Tera Term (ttermpro.exe)" FontWeight="Bold" Margin="0,0,0,4"/>
        <Grid Grid.Row="3" Margin="0,0,0,12">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBox x:Name="TeraTermPathBox" Grid.Column="0" Padding="4,4"/>
            <Button x:Name="BrowseTeraTermButton" Grid.Column="1" Content="参照..." Padding="10,4" Margin="6,0,0,0"/>
        </Grid>

        <TextBlock Grid.Row="4" Text="PuTTY (putty.exe)" FontWeight="Bold" Margin="0,0,0,4"/>
        <Grid Grid.Row="5" Margin="0,0,0,12">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBox x:Name="PuTTYPathBox" Grid.Column="0" Padding="4,4"/>
            <Button x:Name="BrowsePuTTYButton" Grid.Column="1" Content="参照..." Padding="10,4" Margin="6,0,0,0"/>
        </Grid>

        <TextBlock Grid.Row="6" Text="WinSCP (WinSCP.exe)" FontWeight="Bold" Margin="0,0,0,4"/>
        <Grid Grid.Row="7" Margin="0,0,0,12">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBox x:Name="WinSCPPathBox" Grid.Column="0" Padding="4,4"/>
            <Button x:Name="BrowseWinSCPButton" Grid.Column="1" Content="参照..." Padding="10,4" Margin="6,0,0,0"/>
        </Grid>

        <StackPanel Grid.Row="8" Orientation="Horizontal" Margin="0,0,0,8">
            <TextBlock Text="既定の SSH クライアント:" VerticalAlignment="Center" Margin="0,0,8,0"/>
            <RadioButton x:Name="SshTeraTermRadio" Content="Tera Term" GroupName="SshClient" Margin="0,0,12,0"/>
            <RadioButton x:Name="SshPuTTYRadio" Content="PuTTY" GroupName="SshClient"/>
        </StackPanel>

        <StackPanel Grid.Row="9" Orientation="Horizontal" HorizontalAlignment="Right">
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
    $sshTeraTermRadio  = $dialog.FindName('SshTeraTermRadio')
    $sshPuTTYRadio     = $dialog.FindName('SshPuTTYRadio')

    $current = Get-AppSettings
    if (-not [string]::IsNullOrWhiteSpace($current.ServerListPath)) { $serverListPathBox.Text = $current.ServerListPath }
    if (-not [string]::IsNullOrWhiteSpace($current.TeraTermPath))   { $teraTermPathBox.Text   = $current.TeraTermPath }
    if (-not [string]::IsNullOrWhiteSpace($current.PuTTYPath))      { $puttyPathBox.Text      = $current.PuTTYPath }
    if (-not [string]::IsNullOrWhiteSpace($current.WinSCPPath))     { $winscpPathBox.Text     = $current.WinSCPPath }
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

    $dialog.FindName('BrowseListButton').Add_Click({ & $browseExe $serverListPathBox 'サーバ一覧 YAML' 'YAML (*.yaml;*.yml)|*.yaml;*.yml|All files (*.*)|*.*' })
    $dialog.FindName('BrowseTeraTermButton').Add_Click({ & $browseExe $teraTermPathBox 'Tera Term 実行ファイル' 'Executables (*.exe)|*.exe' })
    $dialog.FindName('BrowsePuTTYButton').Add_Click({ & $browseExe $puttyPathBox 'PuTTY 実行ファイル' 'Executables (*.exe)|*.exe' })
    $dialog.FindName('BrowseWinSCPButton').Add_Click({ & $browseExe $winscpPathBox 'WinSCP 実行ファイル' 'Executables (*.exe)|*.exe' })

    $dialog.FindName('OkButton').Add_Click({
        $dialog.DialogResult = $true; $dialog.Close()
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
                         -DefaultSshClient $sshClient
        $statusBarText.Text = '設定を保存しました'
        Sync-ServerList
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

# Event wiring
$refreshButton.Add_Click({ Sync-ServerList })
$settingsButton.Add_Click({
    try { Show-SettingsDialog } catch { $statusBarText.Text = "設定エラー: $($_.Exception.Message)" }
})
$openListButton.Add_Click({
    try {
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
    catch { $statusBarText.Text = "エラー: $($_.Exception.Message)" }
})
$encryptPasswordButton.Add_Click({
    try { Show-EncryptPasswordDialog } catch { $statusBarText.Text = "エラー: $($_.Exception.Message)" }
})

$searchBox.Add_TextChanged({ Update-FilteredView })
$envFilterCombo.Add_SelectionChanged({ Update-FilteredView })
$serverGrid.Add_SelectionChanged({ Update-DetailPane })

$connectRdpButton.Add_Click({
    try {
        $sel = Get-SelectedServer
        if ($null -eq $sel) { $statusBarText.Text = 'サーバ未選択'; return }
        if (-not (Show-WarningIfNeeded -Server $sel)) { $statusBarText.Text = 'キャンセル'; return }
        $r = Start-RdpSession -Host $sel.EffectiveHost
        $statusBarText.Text = $r.Message
    }
    catch { $statusBarText.Text = "エラー: $($_.Exception.Message)" }
})

$connectSshButton.Add_Click({
    try {
        $sel = Get-SelectedServer
        if ($null -eq $sel) { $statusBarText.Text = 'サーバ未選択'; return }
        if (-not (Show-WarningIfNeeded -Server $sel)) { $statusBarText.Text = 'キャンセル'; return }
        $settings = Get-AppSettings
        $pw = Resolve-Password -Server $sel
        if ($null -eq $pw -and [string]::IsNullOrEmpty($sel.KeyFile)) { $statusBarText.Text = 'キャンセル'; return }
        if ($settings.DefaultSshClient -eq 'PuTTY') {
            $r = Start-PuTTYSession -ExecutablePath $settings.PuTTYPath -Host $sel.EffectiveHost -User $sel.User -Password $pw -KeyFile $sel.KeyFile
        }
        else {
            $r = Start-TeraTermSession -ExecutablePath $settings.TeraTermPath -Host $sel.EffectiveHost -User $sel.User -Password $pw -KeyFile $sel.KeyFile
        }
        $statusBarText.Text = $r.Message
    }
    catch { $statusBarText.Text = "エラー: $($_.Exception.Message)" }
})

$connectSftpButton.Add_Click({
    try {
        $sel = Get-SelectedServer
        if ($null -eq $sel) { $statusBarText.Text = 'サーバ未選択'; return }
        if (-not (Show-WarningIfNeeded -Server $sel)) { $statusBarText.Text = 'キャンセル'; return }
        $settings = Get-AppSettings
        $pw = Resolve-Password -Server $sel
        if ($null -eq $pw -and [string]::IsNullOrEmpty($sel.KeyFile)) { $statusBarText.Text = 'キャンセル'; return }
        $r = Start-WinSCPSession -ExecutablePath $settings.WinSCPPath -Host $sel.EffectiveHost -User $sel.User -Password $pw -KeyFile $sel.KeyFile
        $statusBarText.Text = $r.Message
    }
    catch { $statusBarText.Text = "エラー: $($_.Exception.Message)" }
})

# Initial load
Sync-ServerList
Update-DetailPane

$window.ShowDialog() | Out-Null
