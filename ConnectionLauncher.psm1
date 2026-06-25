<#
.SYNOPSIS
    Launch external clients (RDP / Tera Term / PuTTY / WinSCP) for a server.
.DESCRIPTION
    Builds command-line arguments for each client and starts the process.
    Returns a structured result so callers can surface errors in the UI.
    PowerShell 5.1 compatible.
#>

Set-StrictMode -Version Latest

function _BuildResult {
    param(
        [Parameter(Mandatory = $true)][bool]$Success,
        [string]$Message,
        [string]$Command,
        [string[]]$Arguments
    )
    return [PSCustomObject]@{
        Success = $Success
        Message = $Message
        Command = $Command
        Args    = $Arguments
    }
}

function _StartProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$ArgumentList,
        [string]$ToolName
    )
    if (-not (Test-Path -LiteralPath $FilePath)) {
        return _BuildResult -Success $false -Message "${ToolName} の実行ファイルが見つかりません: $FilePath" -Command $FilePath -Arguments $ArgumentList
    }
    try {
        if ($null -eq $ArgumentList -or $ArgumentList.Count -eq 0) {
            Start-Process -FilePath $FilePath -ErrorAction Stop | Out-Null
        }
        else {
            Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -ErrorAction Stop | Out-Null
        }
        return _BuildResult -Success $true -Message "${ToolName} を起動しました" -Command $FilePath -Arguments $ArgumentList
    }
    catch {
        return _BuildResult -Success $false -Message "${ToolName} 起動失敗: $($_.Exception.Message)" -Command $FilePath -Arguments $ArgumentList
    }
}

function Start-RdpSession {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Launches an external client process. Not a system-state change in the auditable sense.')]
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)][string]$Host
    )
    if ([string]::IsNullOrWhiteSpace($Host)) {
        return _BuildResult -Success $false -Message 'ホスト未指定' -Command 'mstsc.exe' -Arguments @()
    }
    return _StartProcess -FilePath 'mstsc.exe' -ArgumentList @("/v:$Host") -ToolName 'リモートデスクトップ (mstsc)'
}

function Start-TeraTermSession {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Launches an external client process.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '', Justification = 'External tool requires plaintext on command line. Caller should source it from DPAPI-decrypted material.')]
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ExecutablePath,
        [Parameter(Mandatory = $true)][string]$Host,
        [string]$User,
        [string]$Password,
        [string]$KeyFile
    )
    if ([string]::IsNullOrWhiteSpace($ExecutablePath)) {
        return _BuildResult -Success $false -Message 'Tera Term のパスが未設定です（設定画面で指定してください）' -Command '' -Arguments @()
    }
    $argsList = New-Object System.Collections.Generic.List[string]
    $argsList.Add($Host)
    if (-not [string]::IsNullOrWhiteSpace($User)) { $argsList.Add("/user=$User") }
    if (-not [string]::IsNullOrWhiteSpace($KeyFile)) {
        $argsList.Add("/auth=publickey")
        $argsList.Add("/keyfile=$KeyFile")
        if (-not [string]::IsNullOrWhiteSpace($Password)) { $argsList.Add("/passwd=$Password") }
    }
    elseif (-not [string]::IsNullOrWhiteSpace($Password)) {
        $argsList.Add("/auth=password")
        $argsList.Add("/passwd=$Password")
    }
    return _StartProcess -FilePath $ExecutablePath -ArgumentList $argsList.ToArray() -ToolName 'Tera Term'
}

function Start-PuTTYSession {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Launches an external client process.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '', Justification = 'External tool requires plaintext on command line. Caller should source it from DPAPI-decrypted material.')]
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ExecutablePath,
        [Parameter(Mandatory = $true)][string]$Host,
        [string]$User,
        [string]$Password,
        [string]$KeyFile
    )
    if ([string]::IsNullOrWhiteSpace($ExecutablePath)) {
        return _BuildResult -Success $false -Message 'PuTTY のパスが未設定です（設定画面で指定してください）' -Command '' -Arguments @()
    }
    $argsList = New-Object System.Collections.Generic.List[string]
    $argsList.Add('-ssh')
    $argsList.Add($Host)
    if (-not [string]::IsNullOrWhiteSpace($User)) {
        $argsList.Add('-l')
        $argsList.Add($User)
    }
    if (-not [string]::IsNullOrWhiteSpace($KeyFile)) {
        $argsList.Add('-i')
        $argsList.Add($KeyFile)
    }
    elseif (-not [string]::IsNullOrWhiteSpace($Password)) {
        # NOTE: -pw exposes the password to the process list; documented caveat.
        $argsList.Add('-pw')
        $argsList.Add($Password)
    }
    return _StartProcess -FilePath $ExecutablePath -ArgumentList $argsList.ToArray() -ToolName 'PuTTY'
}

function Start-WinSCPSession {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Launches an external client process.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '', Justification = 'External tool requires plaintext on command line. Caller should source it from DPAPI-decrypted material.')]
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ExecutablePath,
        [Parameter(Mandatory = $true)][string]$Host,
        [string]$User,
        [string]$Password,
        [string]$KeyFile
    )
    if ([string]::IsNullOrWhiteSpace($ExecutablePath)) {
        return _BuildResult -Success $false -Message 'WinSCP のパスが未設定です（設定画面で指定してください）' -Command '' -Arguments @()
    }
    $argsList = New-Object System.Collections.Generic.List[string]

    # Build sftp:// URL. WinSCP URL-decodes user / password so we percent-encode unsafe chars.
    $userPart = ''
    if (-not [string]::IsNullOrWhiteSpace($User)) {
        $userPart = [uri]::EscapeDataString($User)
        if ([string]::IsNullOrWhiteSpace($KeyFile) -and -not [string]::IsNullOrWhiteSpace($Password)) {
            $userPart += ':' + [uri]::EscapeDataString($Password)
        }
        $userPart += '@'
    }
    $url = "sftp://${userPart}${Host}/"
    $argsList.Add($url)
    if (-not [string]::IsNullOrWhiteSpace($KeyFile)) {
        $argsList.Add("/privatekey=$KeyFile")
    }
    return _StartProcess -FilePath $ExecutablePath -ArgumentList $argsList.ToArray() -ToolName 'WinSCP'
}

Export-ModuleMember -Function Start-RdpSession, Start-TeraTermSession, Start-PuTTYSession, Start-WinSCPSession
