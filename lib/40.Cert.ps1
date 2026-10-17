# ============================================================================
#  PowerShell-FSD - 40.Cert.ps1
#  Certificate store and credential checks
# ============================================================================

function New-Certificate {
    param([string]$Cid, [string]$Password, [int]$Level, [long]$Creation, [string]$Origin)
    if ($Level -gt $Script:LEV_MAX) { $Level = $Script:LEV_MAX }
    $cert = @{
        Cid       = $Cid
        Password  = $Password
        Level     = $Level
        Origin    = $Origin
        Creation  = $Creation
        PrevVisit = [long]0
        LiveCheck = $true
    }
    $Script:RootCert.Add($cert) | Out-Null
    return $cert
}

function Remove-Certificate {
    param($Cert)
    $Script:RootCert.Remove($Cert) | Out-Null
}

function Get-Cert {
    param([string]$Cid)
    foreach ($c in $Script:RootCert) {
        if (Test-StrIEqual $Cid $c.Cid) { return $c }
    }
    return $null
}

function Set-CertificateConfig {
    # configure(): $Password of $null keeps the current password
    param($Cert, $Password, [int]$Level, [long]$Creation, $Origin)
    $Cert.Level = $Level
    if ($null -ne $Password) { $Cert.Password = $Password }
    if ($null -ne $Origin)   { $Cert.Origin = $Origin }
    $Cert.Creation = $Creation
}

# maxlevel(): returns @{ Ok=bool; Max=int }; updates PrevVisit on success
function Test-MaxLevel {
    param([string]$Id, [string]$Pwd)
    $cert = Get-Cert -Cid $Id
    if (-not $cert) {
        return @{ Ok = $false; Max = $Script:LEV_OBSPILOT }
    }
    if (Test-StrIEqual $cert.Password $Pwd) {
        $cert.PrevVisit = [DateTimeOffset]::Now.ToUnixTimeSeconds()
        return @{ Ok = $true; Max = $cert.Level }
    }
    return @{ Ok = $false; Max = $Script:LEV_OBSPILOT }
}
