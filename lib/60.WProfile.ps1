# ============================================================================
#  PowerShell-FSD - 60.WProfile.ps1
#  Weather profiles and METAR parsing
# ============================================================================

function New-WProfile {
    # wprofile(name, creation, origin)
    param([string]$Name, [long]$Creation, $Origin)

    $winds = @()
    for ($i = 0; $i -lt 4; $i++) {
        $winds += @{ Ceiling = 0; Floor = 0; Direction = 0; Speed = 0; Gusting = 0; Turbulence = 0 }
    }
    $winds[0].Floor = -1; $winds[0].Ceiling = -1
    $winds[1].Floor = 2500;  $winds[1].Ceiling = 10400
    $winds[2].Floor = 10400; $winds[2].Ceiling = 22600
    $winds[3].Floor = 22700; $winds[3].Ceiling = 90000

    $clouds = @()
    for ($i = 0; $i -lt 2; $i++) {
        $clouds += @{ Ceiling = -1; Floor = -1; Coverage = 0; Icing = 0; Turbulence = 0 }
    }
    $tstorm = @{ Ceiling = -1; Floor = -1; Coverage = 0; Icing = 0; Turbulence = 0 }

    $temps = @()
    $temps += @{ Ceiling = 100;   Temp = 0 }
    $temps += @{ Ceiling = 10000; Temp = 0 }
    $temps += @{ Ceiling = 18000; Temp = 0 }
    $temps += @{ Ceiling = 35000; Temp = 0 }

    $wp = @{
        Name       = $Name
        Origin     = $Origin
        Creation   = $Creation
        Version    = [long]0
        Active     = $false
        RawCode    = $null
        Winds      = $winds
        Clouds     = $clouds
        TStorm     = $tstorm
        Temps      = $temps
        Barometer  = 2950
        Visibility = 15.0
        DewPoint   = 0
    }
    $Script:RootProfile.Add($wp) | Out-Null
    return $wp
}

function Remove-WProfile {
    param($Wp)
    $Script:RootProfile.Remove($Wp) | Out-Null
}

function Get-WProfile {
    param([string]$Name)
    foreach ($p in $Script:RootProfile) {
        if (Test-StrIEqual $Name $p.Name) { return $p }
    }
    return $null
}

function Enable-WProfile {
    param($Wp)
    $Wp.Active = $true
}

# ---------------------------------------------------------------------------
# loadarray(): rebuild a profile from the network field array
# Field order: barometer, visibility, 2x cloud (ceiling floor coverage icing
# turbulence), tstorm (same 5), 4x wind (ceiling floor direction speed
# gusting turbulence), 4x temp (ceiling temperature)
# ---------------------------------------------------------------------------
function Import-WProfileArray {
    param($Wp, [string[]]$A)
    $i = 0
    $Wp.Barometer  = A2I $A[$i]; $i++
    $Wp.Visibility = A2F $A[$i]; $i++
    for ($x = 0; $x -lt 2; $x++) {
        $l = $Wp.Clouds[$x]
        $l.Ceiling    = A2I $A[$i]; $i++
        $l.Floor      = A2I $A[$i]; $i++
        $l.Coverage   = A2I $A[$i]; $i++
        $l.Icing      = A2I $A[$i]; $i++
        $l.Turbulence = A2I $A[$i]; $i++
    }
    $Wp.TStorm.Ceiling    = A2I $A[$i]; $i++
    $Wp.TStorm.Floor      = A2I $A[$i]; $i++
    $Wp.TStorm.Coverage   = A2I $A[$i]; $i++
    $Wp.TStorm.Icing      = A2I $A[$i]; $i++
    $Wp.TStorm.Turbulence = A2I $A[$i]; $i++
    for ($x = 0; $x -lt 4; $x++) {
        $l = $Wp.Winds[$x]
        $l.Ceiling    = A2I $A[$i]; $i++
        $l.Floor      = A2I $A[$i]; $i++
        $l.Direction  = A2I $A[$i]; $i++
        $l.Speed      = A2I $A[$i]; $i++
        $l.Gusting    = A2I $A[$i]; $i++
        $l.Turbulence = A2I $A[$i]; $i++
    }
    for ($x = 0; $x -lt 4; $x++) {
        $l = $Wp.Temps[$x]
        $l.Ceiling = A2I $A[$i]; $i++
        $l.Temp    = A2I $A[$i]; $i++
    }
}

# ---------------------------------------------------------------------------
# print(): serialize to the colon separated wire format (trailing colon!)
# ---------------------------------------------------------------------------
function Export-WProfileString {
    param($Wp)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append((F2 $Wp.Barometer))
    [void]$sb.Append(':')
    [void]$sb.Append((F2 $Wp.Visibility))
    [void]$sb.Append(':')
    foreach ($c in $Wp.Clouds) {
        [void]$sb.Append(':' + $c.Ceiling + ':' + $c.Floor + ':' + $c.Coverage + ':' + $c.Icing + ':' + $c.Turbulence + ':')
    }
    $c = $Wp.TStorm
    [void]$sb.Append(':' + $c.Ceiling + ':' + $c.Floor + ':' + $c.Coverage + ':' + $c.Icing + ':' + $c.Turbulence + ':')
    foreach ($l in $Wp.Winds) {
        [void]$sb.Append(':' + $l.Ceiling + ':' + $l.Floor + ':' + $l.Direction + ':' + $l.Speed + ':' + $l.Gusting + ':' + $l.Turbulence + ':')
    }
    foreach ($l in $Wp.Temps) {
        [void]$sb.Append(':' + $l.Ceiling + ':' + $l.Temp + ':')
    }
    return $sb.ToString()
}

# ---------------------------------------------------------------------------
# METAR parsing
# ---------------------------------------------------------------------------

function Import-WProfileMetar {
    # parsemetar(): feed the whitespace split METAR tokens
    param($Wp, [string[]]$Array)
    $count = $Array.Count
    $index = 0

    if ($count -eq 0) { return }
    if (Test-StrIEqual $Array[$index] 'metar') { $index++ }
    if ($index -ge $count) { return }

    # station field
    $index++
    if ($index -ge $count) { return }

    # date/time field ending with Z
    if ($Array[$index].EndsWith('Z')) { $index++ }
    if ($index -ge $count) { return }

    if (Test-StrIEqual $Array[$index] 'auto') { $index++ }
    elseif (Test-StrIEqual $Array[$index] 'cor') { $index++ }
    if ($index -ge $count) { return }

    $rest = $Array[$index..($count - 1)]
    $n = $rest.Count
    $used = Invoke-WpParseWind  -Wp $Wp -Array $rest; $index += $used; if ($index -ge $count) { return }
    $rest = $Array[$index..($count - 1)]; $n = $rest.Count
    $used = Invoke-WpParseVis   -Wp $Wp -Array $rest; $index += $used; if ($index -ge $count) { return }
    $rest = $Array[$index..($count - 1)]; $n = $rest.Count
    $used = Invoke-WpParseRvr   -Array $rest; $index += $used; if ($index -ge $count) { return }
    $rest = $Array[$index..($count - 1)]; $n = $rest.Count
    $used = Invoke-WpParseWx    -Array $rest; $index += $used; if ($index -ge $count) { return }
    $rest = $Array[$index..($count - 1)]; $n = $rest.Count
    $used = Invoke-WpParseSky   -Wp $Wp -Array $rest; $index += $used; if ($index -ge $count) { return }
    $rest = $Array[$index..($count - 1)]; $n = $rest.Count
    $used = Invoke-WpParseTemp  -Wp $Wp -Array $rest; $index += $used; if ($index -ge $count) { return }
    $rest = $Array[$index..($count - 1)]; $n = $rest.Count
    $used = Invoke-WpParseAlt   -Wp $Wp -Array $rest; $index += $used
}

function Invoke-WpParseWind {
    param($Wp, [string[]]$Array)
    $count = $Array.Count
    if ($count -eq 0) { return 0 }
    $len = $Array[0].Length
    if ($len -lt 3) { return 0 }
    $tail = $Array[0].Substring($len - 3)
    if (-not (Test-StrIEqual $tail.Substring(1) 'kt') -and -not (Test-StrIEqual $tail 'mps')) { return 0 }
    $head = $Array[0].Substring(0, $len - 1)   # strip 'T' of 'KT' / 'S' of 'MPS'
    $gustPos = $head.IndexOf('G')
    if ($gustPos -ge 0) {
        $head = $head.Substring(0, $gustPos)
        $Wp.Winds[0].Gusting = 1
    }
    $Wp.Winds[0].Speed    = A2I $head.Substring(3)
    $Wp.Winds[0].Ceiling  = 2500
    $Wp.Winds[0].Floor    = 0
    $Wp.Winds[0].Direction = A2I $head.Substring(0, 3)

    if ($count -eq 1) { return 1 }
    $m = [regex]::Match($Array[1], '^\s*([0-9]+)V([0-9]+)')
    if ($m.Success) { return 2 }
    return 1
}

function Invoke-WpParseVis {
    param($Wp, [string[]]$Array)
    $count = $Array.Count
    if ($count -eq 0) { return 0 }
    $Wp.Visibility = 10.0
    switch -Regex ($Array[0]) {
        '^(?i)M1/4SM$' { $Wp.Visibility = 0.15; return 1 }
        '^(?i)1/4SM$'  { $Wp.Visibility = 0.25; return 1 }
        '^(?i)1/2SM$'  { $Wp.Visibility = 0.50; return 1 }
    }
    $f = $Array[0]
    if (Test-StrIEqual $f 'CAVOK' -or $f -eq '////' -or $f -eq 'CLR') {
        $Wp.Visibility = 15.0
        $Wp.Clouds[1].Ceiling = 26000; $Wp.Clouds[1].Floor = 24000
        $Wp.Clouds[1].Icing = 0; $Wp.Clouds[1].Turbulence = 0
        $Wp.Clouds[1].Coverage = 1
        return 1
    }
    $Wp.Visibility = A2F $f
    if ($f.IndexOf('SM') -ge 0) { return 1 }
    if ($count -gt 1 -and $Array[1].IndexOf('SM') -ge 0) { return 2 }
    if ($f.IndexOf('KM') -ge 0) {
        $Wp.Visibility = $Wp.Visibility / 1.609
        return 1
    }
    if ($count -gt 1 -and $Array[1].IndexOf('KM') -ge 0) {
        $Wp.Visibility = $Wp.Visibility / 1.609
        return 2
    }
    if ($Wp.Visibility -eq 9999) { $Wp.Visibility = 15.0 }
    else { $Wp.Visibility = $Wp.Visibility / 1609.0 }
    return 1
}

function Invoke-WpParseRvr {
    param([string[]]$Array)
    $amount = 0
    while ($amount -lt $Array.Count -and $Array[$amount].IndexOf('/') -ge 0) { $amount++ }
    return $amount
}

function Invoke-WpParseWx {
    param([string[]]$Array)
    $patterns = @('+','-','VC','MI','BL','PR','SH','BC','TS','DR','FZ','DZ','OC','UP','RA','PE',
                  'SN','GR','SG','GS','BR','DU','FG','SA','FU','HZ','VA','PY','PO','DS','SQ','FC','SS','PLUS')
    $amount = 0
    while ($true) {
        if ($amount -eq $Array.Count) { break }
        $matched = $false
        foreach ($p in $patterns) {
            if ($Array[$amount].StartsWith($p)) { $matched = $true; break }
        }
        if ($matched) { $amount++ } else { break }
    }
    return $amount
}

function Invoke-WpParseSky {
    param($Wp, [string[]]$Array)
    $patterns = @('SKC','CLR','VV','FEW','SCT','BKN','OVC')
    $coverage = @(0, 0, 8, 1, 3, 5, 8)
    $amount = 0
    while ($true) {
        if ($amount -eq $Array.Count) { break }
        $xi = -1
        for ($x = 0; $x -lt $patterns.Count; $x++) {
            if ($Array[$amount].StartsWith($patterns[$x])) { $xi = $x; break }
        }
        if ($xi -ge 0) {
            if ($amount -lt 2) {
                $basestring = $Array[$amount].Substring($patterns[$xi].Length)
                $base = A2I $basestring
                if ($basestring -notmatch '[0-9]') { $base = 10 }
                $base *= 100
                $Wp.Clouds[$amount].Coverage = $coverage[$xi]
                $Wp.Clouds[$amount].Floor = $base
            }
            $amount++
        } else { break }
    }
    if ($amount -eq 1) {
        $Wp.Clouds[0].Ceiling = $Wp.Clouds[0].Floor + 3000
        $Wp.Clouds[0].Turbulence = 17
    } elseif ($amount -gt 1) {
        if ($Wp.Clouds[1].Floor -gt $Wp.Clouds[0].Floor) {
            $Wp.Clouds[0].Ceiling = $Wp.Clouds[0].Floor + [int](($Wp.Clouds[1].Floor - $Wp.Clouds[0].Floor) / 2)
            $Wp.Clouds[1].Ceiling = $Wp.Clouds[1].Floor + 3000
        } else {
            $Wp.Clouds[1].Ceiling = $Wp.Clouds[1].Floor + [int](($Wp.Clouds[0].Floor - $Wp.Clouds[1].Floor) / 2)
            $Wp.Clouds[0].Ceiling = $Wp.Clouds[0].Floor + 3000
        }
        $Wp.Clouds[0].Turbulence = [int](($Wp.Clouds[0].Ceiling - $Wp.Clouds[0].Floor) / 175)
        $Wp.Clouds[1].Turbulence = [int](($Wp.Clouds[1].Ceiling - $Wp.Clouds[1].Floor) / 175)
    }
    return $amount
}

function Invoke-WpParseTemp {
    param($Wp, [string[]]$Array)
    if ($Array.Count -eq 0) { return 0 }
    $slash = $Array[0].IndexOf('/')
    if ($slash -lt 0) { return 0 }
    $s = $Array[0].Substring(0, $slash)
    $p = $Array[0].Substring($slash + 1)
    if ($s.StartsWith('M')) { $Wp.Temps[0].Temp = -(A2I $s.Substring(1)) }
    else { $Wp.Temps[0].Temp = A2I $s }
    $Wp.Temps[0].Ceiling = 100
    if ($p.StartsWith('M')) { $Wp.DewPoint = -(A2I $p.Substring(1)) }
    else { $Wp.DewPoint = A2I $p }
    if ($Wp.Temps[0].Temp -gt -10 -and $Wp.Temps[0].Temp -lt 10) {
        if ($Wp.Clouds[0].Ceiling -lt 12000) { $Wp.Clouds[0].Icing = 1 }
        if ($Wp.Clouds[1].Ceiling -lt 12000) { $Wp.Clouds[1].Icing = 1 }
    }
    return 1
}

function Invoke-WpParseAlt {
    param($Wp, [string[]]$Array)
    if ($Array.Count -eq 0) { return 0 }
    $Wp.Barometer = 2992
    switch ($Array[0][0]) {
        'A' { $Wp.Barometer = A2I $Array[0].Substring(1) }
        'Q' {
            $Wp.Barometer = A2I $Array[0].Substring(1)
            $Wp.Barometer = M-Round (($Wp.Barometer * 100.0 * 100.0) / (1333.0 * 2.54))
        }
        default { return 0 }
    }
    return 1
}

# ---------------------------------------------------------------------------
# fix(): synthesise upper wind and temperature data from the position
# ---------------------------------------------------------------------------

function Get-WpSeason {
    param([double]$Lat)
    $now = [DateTime]::UtcNow
    $season = 1
    switch ($now.Month) {
        11 { $season = 0 } 1 { $season = 0 } 2 { $season = 0 }
        3  { $season = 1 } 4 { $season = 1 } 5 { $season = 1 }
        6  { $season = 2 } 7 { $season = 2 } 8 { $season = 2 }
        9  { $season = 1 } 10 { $season = 1 } 12 { $season = 0 }
    }
    if ($Lat -lt 0) {
        if ($season -eq 0) { $season = 2 } elseif ($season -eq 2) { $season = 0 }
    }
    return $season
}

function Repair-WProfile {
    # fix(lat, lon)
    param($Wp, [double]$Lat, [double]$Lon)
    $a1 = $Lat
    $a2 = [Math]::Abs($Lon / 18.0)
    $season = Get-WpSeason -Lat $a1
    $latvar = Get-MetarVariation -Num $Script:VAR_UPDIRECTION -Min -25 -Max 25
    if ($a1 -gt 0) { $dir = M-Round (6 * $a1 + $latvar + $a2) }
    else           { $dir = M-Round (-6 * $a1 + $latvar + $a2) }
    $Wp.Winds[3].Direction = (($dir % 360) + 360) % 360

    $maxvelocity = 80
    switch (Get-WpSeason -Lat $a1) {
        0 { $maxvelocity = 120 }
        1 { $maxvelocity = 80 }
        2 { $maxvelocity = 50 }
    }
    $Wp.Winds[3].Speed = M-Round ([Math]::Abs([Math]::Sin($a1 * [Math]::PI / 180.0)) * $maxvelocity)

    $latvar = Get-MetarVariation -Num $Script:VAR_MIDDIRECTION -Min 10 -Max 45
    $coriolisvar = Get-MetarVariation -Num $Script:VAR_MIDCOR -Min 10 -Max 30
    if ($a1 -gt 0) { $dir = M-Round (6 * $a1 + $latvar + $a2 - $coriolisvar) }
    else           { $dir = M-Round (-6 * $a1 + $latvar + $a2 - $coriolisvar) }
    $Wp.Winds[2].Direction = (($dir % 360) + 360) % 360
    $Wp.Winds[2].Speed = [int]($Wp.Winds[3].Speed * ((Get-MetarVariation -Num $Script:VAR_MIDSPEED -Min 500 -Max 800) / 1000.0))

    $coriolisvarlow = $coriolisvar + (Get-MetarVariation -Num $Script:VAR_LOWCOR -Min 10 -Max 30)
    $latvar = Get-MetarVariation -Num $Script:VAR_LOWDIRECTION -Min 10 -Max 45
    if ($a1 -gt 0) { $dir = M-Round (6 * $a1 + $latvar + $a2 - $coriolisvarlow) }
    else           { $dir = M-Round (-6 * $a1 + $latvar + $a2 - $coriolisvarlow) }
    $Wp.Winds[1].Direction = (($dir % 360) + 360) % 360
    $Wp.Winds[1].Speed = [int](($Wp.Winds[0].Speed + $Wp.Winds[1].Speed) / 2)

    $Wp.Temps[3].Temp = -57 + (Get-MetarVariation -Num $Script:VAR_UPTEMP -Min -4 -Max 4)
    $Wp.Temps[2].Temp = -21 + (Get-MetarVariation -Num $Script:VAR_MIDTEMP -Min -7 -Max 7)
    $Wp.Temps[1].Temp = -5  + (Get-MetarVariation -Num $Script:VAR_LOWTEMP -Min -12 -Max 12)
}

# ---------------------------------------------------------------------------
# genrawcode(): synthesise a METAR-like raw report
# ---------------------------------------------------------------------------

function Update-WProfileRawCode {
    param($Wp)
    $gm = [DateTime]::UtcNow
    $data = $Wp.Name + ' '
    $data += ('{0:00}{1:00}{2:00}Z ' -f $gm.Day, $gm.Hour, $gm.Minute)
    $data += ('{0:000}{1:00}KT ' -f $Wp.Winds[0].Direction, $Wp.Winds[0].Speed)
    $data += ('{0:00}SM ' -f [int]$Wp.Visibility)
    for ($x = 0; $x -lt 2; $x++) {
        if ($Wp.Clouds[$x].Ceiling -ne -1) {
            $c = $Wp.Clouds[0].Coverage
            $cov = if ($c -eq 0) { 'CLR' }
                   elseif ($c -eq 1 -or $c -eq 2) { 'FEW' }
                   elseif ($c -eq 3 -or $c -eq 4) { 'SCT' }
                   elseif ($c -eq 5 -or $c -eq 6) { 'BKN' }
                   else { 'OVC' }
            $data += ($cov + ('{0:000} ' -f [int]($Wp.Clouds[0].Floor / 100)))
        }
    }
    $temperature = $Wp.Temps[0].Temp
    $dew = if ($Wp.Visibility -lt 5) { $temperature - 1 } else { $temperature + 1 }
    $tsign = if ($temperature -lt 0) { 'M' } else { '' }
    $dsign = if ($dew -lt 0) { 'M' } else { '' }
    $data += ('{0}{1:00}/{2}{3:00} ' -f $tsign, [Math]::Abs($temperature), $dsign, [Math]::Abs($dew))
    $data += ('A{0:0000}' -f $Wp.Barometer)
    $Wp.RawCode = $data
}
