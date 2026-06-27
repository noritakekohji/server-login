<#
.SYNOPSIS
    Capture the current foreground window to a PNG file.
.DESCRIPTION
    Saves screenshots under the current user's Desktop by default,
    grouped by date, Windows user ID, capture/log type, and foreground process
    instance.
    PowerShell 5.1 compatible.
#>

Set-StrictMode -Version Latest

function Initialize-ScreenshotNativeMethods {
    [CmdletBinding()]
    param()

    if ('ServerLogin.WindowInterop' -as [type]) { return }
    Add-Type -Path (Join-Path $PSScriptRoot 'NativeMethods.cs')
}

function Get-DefaultLogDirectory {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $base = [Environment]::GetFolderPath('Desktop')
    if ([string]::IsNullOrWhiteSpace($base)) {
        $base = $env:USERPROFILE
    }
    if ([string]::IsNullOrWhiteSpace($base)) {
        $base = [System.IO.Path]::GetTempPath()
    }
    return $base
}

function Get-DefaultScreenshotDirectory {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    return (Get-DefaultLogDirectory)
}

function ConvertTo-SafePathSegment {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()][AllowEmptyString()][string]$Value,
        [string]$Fallback = 'untitled'
    )

    $text = if ([string]::IsNullOrWhiteSpace($Value)) { $Fallback } else { $Value.Trim() }
    foreach ($c in [System.IO.Path]::GetInvalidFileNameChars()) {
        $text = $text.Replace([string]$c, '_')
    }
    $text = ($text -replace '\s+', '_')
    $text = $text.Trim(' ', '.')
    if ([string]::IsNullOrWhiteSpace($text)) { return $Fallback }
    if ($text.Length -gt 80) { return $text.Substring(0, 80).Trim(' ', '.') }
    return $text
}

function Get-WindowsUserId {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if (-not [string]::IsNullOrWhiteSpace($env:USERNAME)) {
        return $env:USERNAME
    }
    return 'unknown-user'
}

function Get-ScreenshotSessionFolderName {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [datetime]$Date = (Get-Date),
        [string]$WindowsUserId = (Get-WindowsUserId)
    )

    $safeUser = ConvertTo-SafePathSegment -Value $WindowsUserId -Fallback 'unknown-user'
    return ('{0}-{1}' -f $Date.ToString('yyyy-MM-dd'), $safeUser)
}

function Get-ScreenshotSessionDirectory {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()][AllowEmptyString()][string]$ScreenshotRoot,
        [datetime]$Date = (Get-Date),
        [string]$WindowsUserId = (Get-WindowsUserId)
    )

    if ([string]::IsNullOrWhiteSpace($ScreenshotRoot)) {
        $ScreenshotRoot = Get-DefaultScreenshotDirectory
    }

    return (Join-Path $ScreenshotRoot (Get-ScreenshotSessionFolderName -Date $Date -WindowsUserId $WindowsUserId))
}

function Get-ScreenshotCaptureDirectory {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()][AllowEmptyString()][string]$ScreenshotRoot,
        [datetime]$Date = (Get-Date),
        [string]$WindowsUserId = (Get-WindowsUserId)
    )

    return (Join-Path (Get-ScreenshotSessionDirectory -ScreenshotRoot $ScreenshotRoot -Date $Date -WindowsUserId $WindowsUserId) 'capture')
}

function Get-ScreenshotLogDirectory {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()][AllowEmptyString()][string]$ScreenshotRoot,
        [datetime]$Date = (Get-Date),
        [string]$WindowsUserId = (Get-WindowsUserId)
    )

    return (Join-Path (Get-ScreenshotSessionDirectory -ScreenshotRoot $ScreenshotRoot -Date $Date -WindowsUserId $WindowsUserId) 'log')
}

function Get-SessionTargetFolderName {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()][AllowEmptyString()][string]$HostName,
        [AllowNull()][AllowEmptyString()][string]$Id,
        [string]$Fallback = 'local'
    )

    if ([string]::IsNullOrWhiteSpace($HostName) -and [string]::IsNullOrWhiteSpace($Id)) {
        return (ConvertTo-SafePathSegment -Value $Fallback -Fallback 'local')
    }

    $safeHost = ConvertTo-SafePathSegment -Value $HostName -Fallback 'unknown-host'
    $safeId = ConvertTo-SafePathSegment -Value $Id -Fallback 'session'
    return ('{0}-{1}' -f $safeHost, $safeId)
}

function Get-CaptureProcessFolderName {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]$WindowInfo,
        [hashtable]$ProcessMetadata
    )

    $pidText = [string]$WindowInfo.ProcessId
    if ($null -eq $ProcessMetadata -or -not $ProcessMetadata.ContainsKey($pidText)) {
        return (Get-SessionTargetFolderName -Fallback 'local')
    }

    $metadata = $ProcessMetadata[$pidText]
    return (Get-SessionTargetFolderName -HostName $metadata.HostName -Id $metadata.Id)
}

function Get-SessionLogTargetDirectory {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()][AllowEmptyString()][string]$ScreenshotRoot,
        [AllowNull()][AllowEmptyString()][string]$HostName,
        [AllowNull()][AllowEmptyString()][string]$Id,
        [datetime]$Date = (Get-Date),
        [string]$WindowsUserId = (Get-WindowsUserId)
    )

    $base = Get-ScreenshotLogDirectory -ScreenshotRoot $ScreenshotRoot -Date $Date -WindowsUserId $WindowsUserId
    return (Join-Path $base (Get-SessionTargetFolderName -HostName $HostName -Id $Id))
}

function Get-ForegroundWindowInfo {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param()

    Initialize-ScreenshotNativeMethods

    $nativeInfo = [ServerLogin.WindowInterop]::GetActiveWindowInfo()
    $pidValue = $nativeInfo.ProcessId
    $processName = 'unknown'
    try {
        $processName = (Get-Process -Id ([int]$pidValue) -ErrorAction Stop).ProcessName
    }
    catch {
        $processName = "pid-$pidValue"
    }

    return [PSCustomObject]@{
        Handle      = $nativeInfo.Handle
        ProcessId   = [int]$pidValue
        ProcessName = $processName
        Title       = $nativeInfo.Title
        Left        = $nativeInfo.Left
        Top         = $nativeInfo.Top
        Width       = $nativeInfo.Width
        Height      = $nativeInfo.Height
    }
}

function Save-ForegroundWindowScreenshot {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [string]$ScreenshotRoot,
        [hashtable]$ProcessMetadata
    )

    Add-Type -AssemblyName System.Windows.Forms, System.Drawing

    if ([string]::IsNullOrWhiteSpace($ScreenshotRoot)) {
        $ScreenshotRoot = Get-DefaultScreenshotDirectory
    }

    $info = Get-ForegroundWindowInfo
    if ($info.Width -le 0 -or $info.Height -le 0) {
        throw "Invalid foreground window size: $($info.Width)x$($info.Height)"
    }

    $captureDir = Get-ScreenshotCaptureDirectory -ScreenshotRoot $ScreenshotRoot
    $processFolder = Get-CaptureProcessFolderName -WindowInfo $info -ProcessMetadata $ProcessMetadata
    $targetDir = Join-Path $captureDir $processFolder
    $logDir = Join-Path (Get-ScreenshotLogDirectory -ScreenshotRoot $ScreenshotRoot) $processFolder
    if (-not (Test-Path -LiteralPath $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }

    if (-not (Test-Path -LiteralPath $targetDir)) {
        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
    }

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $safeTitle = ConvertTo-SafePathSegment -Value $info.Title -Fallback 'foreground'
    $fileName = "${timestamp}_${safeTitle}.png"
    $path = Join-Path $targetDir $fileName

    [System.Windows.Forms.SendKeys]::SendWait('%{PRTSC}')
    Start-Sleep -Milliseconds 200

    $image = [System.Windows.Forms.Clipboard]::GetImage()
    if ($null -eq $image) {
        throw 'Failed to read an active-window screenshot from the clipboard.'
    }

    try {
        $image.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        $image.Dispose()
    }

    return [PSCustomObject]@{
        Success     = $true
        Path        = $path
        LogDirectory = $logDir
        ProcessId   = $info.ProcessId
        ProcessName = $info.ProcessName
        WindowTitle = $info.Title
        Width       = $info.Width
        Height      = $info.Height
    }
}

Export-ModuleMember -Function Initialize-ScreenshotNativeMethods, Get-DefaultLogDirectory, Get-DefaultScreenshotDirectory, ConvertTo-SafePathSegment, Get-WindowsUserId, Get-ScreenshotSessionFolderName, Get-ScreenshotSessionDirectory, Get-ScreenshotCaptureDirectory, Get-ScreenshotLogDirectory, Get-SessionTargetFolderName, Get-CaptureProcessFolderName, Get-SessionLogTargetDirectory, Get-ForegroundWindowInfo, Save-ForegroundWindowScreenshot
