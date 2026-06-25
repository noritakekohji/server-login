<#
.SYNOPSIS
    DPAPI-based password protection helpers.
.DESCRIPTION
    Wraps PowerShell's built-in ConvertFrom-SecureString / ConvertTo-SecureString
    so server-list YAML can carry passwords as DPAPI-encrypted strings.
    Encrypted text can only be decrypted by the same Windows user on the same
    machine -- it is NOT stored in the OS credential manager.
    PowerShell 5.1 compatible.
#>

Set-StrictMode -Version Latest

function Protect-Password {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Plain
    )
    if ([string]::IsNullOrEmpty($Plain)) { return '' }
    $secure = ConvertTo-SecureString -String $Plain -AsPlainText -Force
    return (ConvertFrom-SecureString -SecureString $secure)
}

function Unprotect-Password {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Protected
    )
    if ([string]::IsNullOrEmpty($Protected)) { return '' }
    $secure = ConvertTo-SecureString -String $Protected -ErrorAction Stop
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
        return [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) | Out-Null
    }
}

function Test-IsProtectedPassword {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Value
    )
    if ([string]::IsNullOrEmpty($Value)) { return $false }
    # DPAPI ciphertext is a long hex-like string; treat reasonably-long hex blob as protected
    return ($Value.Length -ge 64 -and $Value -match '^[0-9a-fA-F]+$')
}

Export-ModuleMember -Function Protect-Password, Unprotect-Password, Test-IsProtectedPassword
