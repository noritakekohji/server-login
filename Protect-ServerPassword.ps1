<#
.SYNOPSIS
    対話的にパスワードを DPAPI で暗号化し、servers.yaml に貼り付け可能な文字列を出力する。
.DESCRIPTION
    GUI を立ち上げずにコマンドラインで暗号化したいときに使う。
    出力は同一 Windows ユーザー・同一マシンでのみ復号可能。
    PowerShell 5.1 互換。
.EXAMPLE
    .\Protect-ServerPassword.ps1
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interactive console UX for an end-user helper script.')]
param()

Set-StrictMode -Version Latest

Import-Module -Force (Join-Path $PSScriptRoot 'PasswordProtect.psm1')

$secure = Read-Host -AsSecureString -Prompt 'パスワード'
$bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
try {
    $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
}
finally {
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) | Out-Null
}

if ([string]::IsNullOrEmpty($plain)) {
    Write-Host '空のパスワードは暗号化しません。' -ForegroundColor Yellow
    exit 1
}

$cipher = Protect-Password -Plain $plain
Write-Host ''
Write-Host '暗号文（servers.yaml の password_protected: にそのまま貼り付け）:' -ForegroundColor Cyan
Write-Host ''
Write-Output $cipher
Write-Host ''
Write-Host '※ 同一 Windows ユーザー・同一マシンでのみ復号可能。' -ForegroundColor Gray
