# ============================================================================
#  PowerShell-FSD - 30.Config.ps1
#  fsd.conf reader with hot reload
#
#  File format:
#     [group]
#     key=value
#  '#' lines and empty lines are skipped.  Keys are case-insensitive.
# ============================================================================

function New-ConfigEntry {
    param([string]$Var, [string]$Data)
    return @{
        Var     = $Var
        Data    = $Data
        Changed = $true
    }
}

# inlist(): the value interpreted as comma separated list membership test
function Test-ConfigInList {
    param($Entry, [string]$Needle)
    $parts = $Entry.Data -split ','
    foreach ($p in $parts) {
        $t = $p.Trim()
        if ($t -and (Test-StrIEqual $t $Needle)) { return $true }
    }
    return $false
}

# getnparts()/getpart(): comma separated parts with whitespace trimmed
function Get-ConfigParts {
    param($Entry)
    $out = @()
    foreach ($p in ($Entry.Data -split ',')) {
        $t = $p.Trim()
        if ($p -ne '' -or $out.Count -gt 0) { $out += $t }
    }
    return ,@($out)
}

function New-ConfigGroup {
    param([string]$Name)
    return @{
        Name    = $Name
        Entries = New-Object System.Collections.ArrayList
        Changed = $true
    }
}

function Get-ConfigEntry {
    param($Group, [string]$Name)
    foreach ($e in $Group.Entries) {
        if (Test-StrIEqual $Name $e.Var) { return $e }
    }
    return $null
}

function Set-ConfigEntryData {
    param($Group, $Entry, [string]$Data)
    if ($Entry.Data -ceq $Data) { return }
    $Entry.Data = $Data
    $Entry.Changed = $true
    $Group.Changed = $true
}

function Add-ConfigEntry {
    param($Group, [string]$Var, [string]$Data)
    $e = New-ConfigEntry -Var $Var -Data $Data
    $Group.Entries.Add($e) | Out-Null
    $Group.Changed = $true
    return $e
}

# handleentry(): create or update, marking the group changed when needed
function Update-ConfigEntry {
    param($Group, [string]$Var, [string]$Data)
    $e = Get-ConfigEntry -Group $Group -Name $Var
    if (-not $e) {
        Add-ConfigEntry -Group $Group -Var $Var -Data $Data | Out-Null
        return
    }
    Set-ConfigEntryData -Group $Group -Entry $e -Data $Data
}

function New-ConfigManager {
    param([string]$FileName)
    $cm = @{
        FileName   = $FileName
        Groups     = New-Object System.Collections.ArrayList
        Changed    = $true
        PrevCheck  = 0
        LastModify = 0
    }
    $Script:ConfigMan = $cm
    $idx = Add-MgrVar -Name 'config.filename' -Type 'varchar'
    Set-MgrVar -Num $idx -Value $FileName
    $Script:ConfigLastReadVar = Add-MgrVar -Name 'config.lastread' -Type 'date'
    Invoke-ConfigParse
    return $cm
}

function Get-ConfigGroup {
    param([string]$Name)
    foreach ($g in $Script:ConfigMan.Groups) {
        if (Test-StrIEqual $Name $g.Name) { return $g }
    }
    return $null
}

function New-ConfigGroupInternal {
    param([string]$Name)
    $g = New-ConfigGroup -Name $Name
    $Script:ConfigMan.Groups.Add($g) | Out-Null
    return $g
}

function Invoke-ConfigParse {
    $path = Join-Path $Script:FsdDir $Script:ConfigMan.FileName
    if (-not (Test-Path -LiteralPath $path)) { return }
    Set-MgrVar -Num $Script:ConfigLastReadVar -Value ([DateTimeOffset]::Now.ToUnixTimeSeconds())
    $current = $null
    foreach ($raw in [System.IO.File]::ReadAllLines($path, $Script:FsdEnc)) {
        if ($raw.Length -eq 0) { continue }
        if ($raw[0] -eq '#') { continue }
        if ($raw[0] -eq '[') {
            $end = $raw.IndexOf(']')
            $name = if ($end -gt 0) { $raw.Substring(1, $end - 1) } else { $raw.Substring(1) }
            $current = Get-ConfigGroup -Name $name
            if (-not $current) { $current = New-ConfigGroupInternal -Name $name }
            continue
        }
        if (-not $current) { continue }
        $sep = $raw.IndexOf('=')
        if ($sep -lt 0) { continue }
        $var  = $raw.Substring(0, $sep).TrimEnd()
        $data = $raw.Substring($sep + 1).TrimStart()
        Update-ConfigEntry -Group $current -Var $var -Data $data
        if ($current.Changed) { $Script:ConfigMan.Changed = $true }
    }
    $Script:ConfigMan.PrevCheck = Get-MTime
}

# run(): poll the file mtime every CONFIGINTERVAL seconds (hot reload)
function Invoke-ConfigRun {
    $now = Get-MTime
    if (($now - $Script:ConfigMan.PrevCheck) -lt $Script:CONFIGINTERVAL) { return }
    $Script:ConfigMan.PrevCheck = $now
    $path = Join-Path $Script:FsdDir $Script:ConfigMan.FileName
    if (-not (Test-Path -LiteralPath $path)) { return }
    $item = Get-Item -LiteralPath $path
    $mtime = ([DateTimeOffset]$item.LastWriteTimeUtc).ToUnixTimeSeconds()
    if ($mtime -eq $Script:ConfigMan.LastModify) { return }
    $Script:ConfigMan.LastModify = $mtime
    Invoke-ConfigParse
}
