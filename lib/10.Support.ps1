# ============================================================================
#  PowerShell-FSD - 10.Support.ps1
#  Logging, string/packet handling, time formatting, distance maths, PRNG
# ============================================================================

function Add-LogHistory {
    param([int]$Level, [string]$Message)
    if ($Level -ge $Script:L_MAX) { $Level = $Script:L_MAX - 1 }
    $Script:LogHistory.Add(@{ Level = $Level; Msg = $Message }) | Out-Null
    while ($Script:LogHistory.Count -gt $Script:MAXLOG) { $Script:LogHistory.RemoveAt(0) }
}

$Script:FsdConsole = $true

function Write-Dolog {
    param([int]$Level, [string]$Message)
    $now = [DateTime]::Now
    $ident = if ($Script:MyServer) { $Script:MyServer.Ident } else { '' }
    $prefix = if ($Level -lt $Script:L_WARNING) { '** ' } else { '' }
    $line = ('{0:00}-{1:00}-{2:00} {3:00}:{4:00}:{5:00} {6}: {7}{8}' -f `
        $now.Day, $now.Month, ($now.Year % 100), $now.Hour, $now.Minute, $now.Second,
        $ident, $prefix, $Message)
    try {
        $sw = New-Object System.IO.StreamWriter((Join-Path $Script:FsdDir $Script:LOGFILE), $true, $Script:FsdEnc)
        $sw.WriteLine($line)
        $sw.Close()
    } catch { }
    if ($Script:FsdConsole) {
        $color = 'Gray'
        switch ($Level) {
            $Script:L_EMERG   { $color = 'Red' }
            $Script:L_ALERT   { $color = 'Red' }
            $Script:L_CRIT    { $color = 'Red' }
            $Script:L_ERR     { $color = 'Yellow' }
            $Script:L_WARNING { $color = 'Yellow' }
            $Script:L_INFO    { $color = 'Gray' }
            $Script:L_DEBUG   { $color = 'DarkGray' }
        }
        Write-Host $line -ForegroundColor $color
    }
    Add-LogHistory -Level $Level -Message $line
}

# --- Packet / argument splitting (breakpacket / breakargs) ------------------

# Split a colon separated packet. Replicates C breakpacket(): the remainder is
# merged back into the last field when more than $max fields are present.
function Break-Packet {
    param([string]$S, [int]$Max)
    $parts = $S -split ':'
    if ($parts.Count -le $Max) { return ,@($parts) }
    $out = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt ($Max - 1); $i++) { $out.Add([string]$parts[$i]) }
    $rest = @()
    for ($i = $Max - 1; $i -lt $parts.Count; $i++) { $rest += [string]$parts[$i] }
    $out.Add(($rest -join ':'))
    return ,@($out.ToArray())
}

# Join fields back together with ':' (catcommand)
function Join-Command {
    param($Fields)
    return ($Fields -join ':')
}

# Split on whitespace, at most $Max tokens (breakargs)
function Break-Args {
    param([string]$S, [int]$Max)
    $tokens = $S.Trim() -split '\s+'
    if ($tokens.Count -eq 1 -and $tokens[0] -eq '') { return ,@() }
    if ($tokens.Count -gt $Max) {
        $out = @()
        for ($i = 0; $i -lt $Max; $i++) { $out += $tokens[$i] }
        return ,@($out)
    }
    return ,@($tokens)
}

# Join tokens back with single spaces (catargs)
function Join-Args {
    param($Fields)
    return (($Fields | ForEach-Object { [string]$_ }) -join ' ')
}

# --- C style numeric parsing -------------------------------------------------

# atoi(): leading integer, 0 on failure
function A2I {
    param([string]$S)
    if ([string]::IsNullOrEmpty($S)) { return 0 }
    $m = [regex]::Match($S, '^\s*([+-]?[0-9]+)')
    if (-not $m.Success) { return 0 }
    $v = 0L
    if (-not [long]::TryParse($m.Groups[1].Value, [Globalization.NumberStyles]::Integer, $Script:Inv, [ref]$v)) { return 0 }
    if ($v -gt 2147483647) { return 2147483647 }
    if ($v -lt -2147483648) { return -2147483648 }
    return [int]$v
}

# strict sscanf("%d") style test: returns $null when the field does not START
# with a valid integer (used for packetcount/hops validation)
function Try-A2I {
    param([string]$S)
    $m = [regex]::Match($S, '^\s*([+-]?[0-9]+)')
    if (-not $m.Success) { return $null }
    $v = 0L
    if (-not [long]::TryParse($m.Groups[1].Value, [Globalization.NumberStyles]::Integer, $Script:Inv, [ref]$v)) { return $null }
    return [int]$v
}

# atof()/sscanf("%lf"): leading double, 0.0 on failure
function A2F {
    param([string]$S)
    if ([string]::IsNullOrEmpty($S)) { return 0.0 }
    $m = [regex]::Match($S, '^\s*([+-]?[0-9]*\.?[0-9]+([eE][+-]?[0-9]+)?)')
    if (-not $m.Success) { return 0.0 }
    $v = 0.0
    if (-not [double]::TryParse($m.Groups[1].Value, [Globalization.NumberStyles]::Float, $Script:Inv, [ref]$v)) { return 0.0 }
    return $v
}

# strtoul(): leading unsigned integer, saturating like the C runtime
function A2U {
    param([string]$S)
    if ([string]::IsNullOrEmpty($S)) { return [uint32]0 }
    $m = [regex]::Match($S, '^\s*([0-9]+)')
    if (-not $m.Success) { return [uint32]0 }
    $v = [uint64]0
    if (-not [uint64]::TryParse($m.Groups[1].Value, [Globalization.NumberStyles]::Integer, $Script:Inv, [ref]$v)) {
        return [uint32]4294967295
    }
    if ($v -gt 4294967295) { return [uint32]4294967295 }
    return [uint32]$v
}

# --- Formatted output helpers (printf equivalents, invariant culture) -------

function F2  { param([double]$V) $V.ToString('F2', $Script:Inv) }
function F5  { param([double]$V) $V.ToString('F5', $Script:Inv) }
function F6  { param([double]$V) $V.ToString('F6', $Script:Inv) }
function F1  { param([double]$V) $V.ToString('F1', $Script:Inv) }

# mround(): round half away from zero, like the C helper
function M-Round {
    param([double]$Val)
    if ($Val -gt 2147483647.0) { return 2147483647 }
    $frac = $Val - [Math]::Floor($Val)
    if ($frac -gt 0.5)  { return ([int][Math]::Floor($Val)) + 1 }
    if ($frac -lt -0.5) { return ([int][Math]::Floor($Val)) - 1 }
    return [int][Math]::Floor($Val)
}

# --- Time helpers ------------------------------------------------------------

function Get-MTime { [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }

# mgmtime(): UTC based epoch (identical to mtime in practice)
function Get-MGMTime { [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }

# sprinttime(): "HH:MM:SS" of an elapsed second count
function Format-Elapsed {
    param([long]$Now)
    $s = [int]($Now % 60); $m = [int](($Now % 3600) / 60); $h = [int]($Now / 3600)
    return ('{0:00}:{1:00}:{2:00}' -f $h, $m, $s)
}

# sprintdate(): "dd-mm-yyyy hh:mm:ss" local time
function Format-SprintDate {
    param([long]$Now)
    if ($Now -eq 0) { return '<none>' }
    $d = [DateTimeOffset]::FromUnixTimeSeconds($Now).LocalDateTime
    return ('{0:00}-{1:00}-{2:0000} {3:00}:{4:00}:{5:00}' -f `
        $d.Day, $d.Month, $d.Year, $d.Hour, $d.Minute, $d.Second)
}

# sprintgmtdate(): "dd/mm/yyyy hh:mm" UTC (whazzup header)
function Format-GmtDate {
    param([long]$Now)
    $d = [DateTimeOffset]::FromUnixTimeSeconds($Now).UtcDateTime
    return ('{0:00}/{1:00}/{2:0000} {3:00}:{4:00}' -f `
        $d.Day, $d.Month, $d.Year, $d.Hour, $d.Minute)
}

# sprintgmt(): "yyyyMMddHHmmss" UTC (whazzup client time stamp)
function Format-Gmt {
    param([long]$Now)
    $d = [DateTimeOffset]::FromUnixTimeSeconds($Now).UtcDateTime
    return ('{0:0000}{1:00}{2:00}{3:00}{4:00}{5:00}' -f `
        $d.Year, $d.Month, $d.Day, $d.Hour, $d.Minute, $d.Second)
}

# --- Geography ----------------------------------------------------------------

# Great circle distance in nautical miles (dist())
function Get-DistanceNM {
    param([double]$Lat1, [double]$Lon1, [double]$Lat2, [double]$Lon2)
    $dlon = ($Lon2 - $Lon1) * [Math]::PI / 180.0
    $r1 = $Lat1 * [Math]::PI / 180.0
    $r2 = $Lat2 * [Math]::PI / 180.0
    $d = ([Math]::Sin($r1) * [Math]::Sin($r2)) + ([Math]::Cos($r1) * [Math]::Cos($r2) * [Math]::Cos($dlon))
    if ($d -gt 1.0) { $d = 1.0 }
    if ($d -lt -1.0) { $d = -1.0 }
    return ([Math]::Acos($d) * 60.0 * 180.0 / [Math]::PI)
}

function Format-Part {
    param([double]$Part, [char]$PosChar, [char]$NegChar)
    $c = if ($Part -lt 0.0) { $NegChar } else { $PosChar }
    $Part = [Math]::Abs($Part)
    $degrees = [Math]::Floor($Part)
    $Part -= $degrees; $Part *= 60
    $min = [Math]::Floor($Part); $Part -= $min; $Part *= 60
    $sec = $Part
    return ('{0} {1:00} {2:00}'' {3:00}"' -f $c, [int]$degrees, [int]$min, [int]$sec)
}

function Format-Loc {
    param([double]$Lat, [double]$Lon)
    $north = Format-Part -Part $Lat -PosChar 'N' -NegChar 'S'
    $east  = Format-Part -Part $Lon -PosChar 'E' -NegChar 'W'
    return "$north $east"
}

# --- Pseudo random generator (msrand/mrand, LCG bit twiddling) ---------------

function Reset-MRand {
    param([int]$Seed)
    $Script:MRandSeed = $Seed
}

function Get-MRand {
    # Faithful re-implementation of the C bit twiddling, done in Int64 space
    # to avoid PowerShell overflow exceptions.  NOTE: the 32 bit mask must be
    # an explicit Int64 - the literal 0xFFFFFFFF parses as Int32 -1.
    $mask32 = [int64]4294967295
    $m = ([int64]$Script:MRandSeed -bxor 0x22591d8c) -band $mask32
    if ($m -gt 2147483647) { $m -= 4294967296 }
    $part1 = ([int64]$m -shl 1) -band $mask32
    if ($part1 -gt 2147483647) { $part1 -= 4294967296 }
    $part1 = [int32]$part1
    $part2 = if ($m -lt 0) { -1 } else { 0 }   # arithmetic >> 31
    $r = ([int64]$m -bxor [int64]($part1 -bor $part2)) -band $mask32
    if ($r -gt 2147483647) { $r -= 4294967296 }
    $Script:MRandSeed = [int32]$r
    return $Script:MRandSeed
}

# C style % (truncation towards zero, keeps the sign of the dividend)
function Mod-C {
    param([long]$A, [long]$B)
    $r = [Math]::Abs($A) % [Math]::Abs($B)
    if ($A -lt 0) { return -$r }
    return $r
}

# --- Misc ---------------------------------------------------------------------

function ConvertTo-Upper {
    param([string]$S)
    if ($null -eq $S) { return $S }
    return $S.ToUpper($Script:Inv)
}

function Test-StrIEqual {
    param([string]$A, [string]$B)
    return ([string]::Compare($A, $B, $true) -eq 0)
}

# strpbrk style test: does $S contain any of the characters?
function Test-ContainsAny {
    param([string]$S, [string]$Chars)
    foreach ($ch in $Chars.ToCharArray()) {
        if ($S.IndexOf($ch) -ge 0) { return $true }
    }
    return $false
}

# gethostname style local machine name
function Get-LocalHostName {
    try { return [System.Net.Dns]::GetHostName() } catch { return 'localhost' }
}

function Find-HostName {
    param([string]$Ip)
    try {
        $entry = [System.Net.Dns]::GetHostEntry($Ip)
        if ($entry.HostName) { return $entry.HostName }
    } catch { }
    return $Ip
}
