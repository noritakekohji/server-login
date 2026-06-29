<#
.SYNOPSIS
    Reads server list YAML and returns normalized server objects.
.DESCRIPTION
    Supports minimal YAML: top-level 'servers:' list with hyphen items
    and simple key: value pairs per item. PowerShell 5.1 compatible.

    Server schema (per item):
      name             [required]  hostname or display name
      os               Linux | Windows
      host             optional   connection host name or IP; falls back to name when omitted
      ip               optional   legacy alias for host
      user             optional   login user name
      password         optional   plaintext (warn -- use password_protected instead)
      password_protected optional DPAPI-encrypted ciphertext (Protect-Password output)
      key_file         optional   path to SSH/SFTP private key
      environment      optional   environment label (e.g. 本番 / 検証 / 開発)
      role             optional   role label (e.g. 管理者 / 一般)
      in_development   optional   bool; when true, suppresses production warning
      note             optional   free text
#>

Set-StrictMode -Version Latest

function Read-MinimalServerYaml {
    [CmdletBinding()]
    [OutputType([System.Collections.Hashtable[]])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Server list file not found: $Path"
    }

    $text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop
    $lines = $text -split "(`r`n|`r|`n)"
    $clean = @()
    foreach ($l in $lines) {
        if ($l -match '^(\r\n|\r|\n)$') { continue }
        $clean += $l
    }

    $items = New-Object System.Collections.Generic.List[Hashtable]
    $current = $null
    $insideServers = $false

    foreach ($raw in $clean) {
        # Strip trailing # comment (only when # is preceded by whitespace or at start)
        $line = $raw
        $idx = -1
        for ($i = 0; $i -lt $line.Length; $i++) {
            $ch = $line[$i]
            if ($ch -eq '#' -and ($i -eq 0 -or [char]::IsWhiteSpace($line[$i - 1]))) {
                $idx = $i; break
            }
        }
        if ($idx -ge 0) { $line = $line.Substring(0, $idx) }
        $trimmed = $line.TrimEnd()
        if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }

        if ($trimmed -match '^servers:\s*$') {
            $insideServers = $true
            continue
        }
        if (-not $insideServers) { continue }

        if ($trimmed -match '^\s*-\s*(.*)$') {
            if ($null -ne $current) { $items.Add($current) }
            $current = @{}
            $firstPair = $Matches[1]
            if (-not [string]::IsNullOrWhiteSpace($firstPair)) {
                $kv = _ParseKeyValue $firstPair
                if ($null -ne $kv) { $current[$kv.Key] = $kv.Value }
            }
            continue
        }

        if ($null -ne $current -and $trimmed -match '^\s{2,}(.+)$') {
            $body = $trimmed.TrimStart()
            $kv = _ParseKeyValue $body
            if ($null -ne $kv) { $current[$kv.Key] = $kv.Value }
        }
    }
    if ($null -ne $current) { $items.Add($current) }
    return , ($items.ToArray())
}

function _ParseKeyValue {
    param([string]$Text)
    $eq = $Text.IndexOf(':')
    if ($eq -lt 1) { return $null }
    $key = $Text.Substring(0, $eq).Trim()
    $val = $Text.Substring($eq + 1).Trim()
    # Strip matching surrounding quotes
    if (($val.StartsWith('"') -and $val.EndsWith('"') -and $val.Length -ge 2) -or
        ($val.StartsWith("'") -and $val.EndsWith("'") -and $val.Length -ge 2)) {
        $val = $val.Substring(1, $val.Length - 2)
    }
    return [PSCustomObject]@{ Key = $key; Value = $val }
}

function ConvertTo-Server {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Item
    )

    $name = if ($Item.ContainsKey('name')) { [string]$Item['name'] } else { '' }
    if ([string]::IsNullOrWhiteSpace($name)) { return $null }

    $os = if ($Item.ContainsKey('os')) { [string]$Item['os'] } else { 'Linux' }
    $os = $os.Trim()
    if ($os -ne 'Windows' -and $os -ne 'Linux') { $os = 'Linux' }

    $host = ''
    if ($Item.ContainsKey('host')) {
        $host = [string]$Item['host']
    }
    elseif ($Item.ContainsKey('ip')) {
        $host = [string]$Item['ip']
    }
    $effective = if ([string]::IsNullOrWhiteSpace($host)) { $name } else { $host }

    $inDev = $false
    if ($Item.ContainsKey('in_development')) {
        $v = [string]$Item['in_development']
        if ($v -match '^(?i:true|yes|1)$') { $inDev = $true }
    }

    $keyFile = ''
    foreach ($keyName in 'key_file','keyfile','key','private_key','identity_file') {
        if ($Item.ContainsKey($keyName)) {
            $keyFile = [string]$Item[$keyName]
            break
        }
    }

    return [PSCustomObject]@{
        Name              = $name
        OS                = $os
        Host              = $host
        IP                = $host
        EffectiveHost     = $effective
        User              = if ($Item.ContainsKey('user')) { [string]$Item['user'] } else { '' }
        Password          = if ($Item.ContainsKey('password')) { [string]$Item['password'] } else { '' }
        PasswordProtected = if ($Item.ContainsKey('password_protected')) { [string]$Item['password_protected'] } else { '' }
        KeyFile           = $keyFile
        Environment       = if ($Item.ContainsKey('environment')) { [string]$Item['environment'] } else { '' }
        Role              = if ($Item.ContainsKey('role')) { [string]$Item['role'] } else { '' }
        InDevelopment     = $inDev
        Note              = if ($Item.ContainsKey('note')) { [string]$Item['note'] } else { '' }
    }
}

function Import-ServerList {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Imports a list of servers by design.')]
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $items = Read-MinimalServerYaml -Path $Path
    $result = New-Object System.Collections.Generic.List[PSCustomObject]
    foreach ($it in $items) {
        $srv = ConvertTo-Server -Item $it
        if ($null -ne $srv) { $result.Add($srv) }
    }
    return , ($result.ToArray())
}

Export-ModuleMember -Function Import-ServerList, ConvertTo-Server, Read-MinimalServerYaml
