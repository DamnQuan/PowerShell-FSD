# ============================================================================
#  PowerShell-FSD - 83.SysIF.ps1
#  System management interface (admin commands over the system port)
# ============================================================================

$Script:SysCmds = @(
    'servers','info','ping','connect','time','route','weather','disconnect',
    'help','quit','stat','say','clients','cert','pwd','distance','range',
    'log','wall','delguard','metar','wp','kill','pos','dump','servers2',
    'refreshmetar'
)

# 1 = requires the 'pwd' authorisation
$Script:SysNeedAuth = @(
    0, 1, 1, 1, 0, 0, 0, 1, 0, 0, 1, 1, 1, 1, 0, 1, 1, 1, 1, 1, 0, 1, 1, 0, 1, 0, 1
)

# ---------------------------------------------------------------------------
# Connection setup
# ---------------------------------------------------------------------------

function Initialize-SysConn {
    param($U)
    Send-UData -U $U -S ("# {0} system interface ready.`r`n" -f $Script:PRODUCT)
    $logs = @(0) * $Script:L_MAX
    foreach ($l in $Script:LogHistory) { $logs[$l.Level]++ }
    Send-UData -U $U -S ("# Logs: Emerg: {0}, Alert: {1}, Crit: {2}, Err: {3}, Warn: {4}, Info: {5}, Debug: {6}`r`n" -f `
        $logs[0], $logs[1], $logs[2], $logs[3], $logs[4], $logs[5], $logs[6])
    Send-UData -U $U -S "# Type 'help' for help.`r`n"

    $sgroup = Get-ConfigGroup -Name 'system'
    $sentry = if ($sgroup) { Get-ConfigEntry -Group $sgroup -Name 'password' } else { $null }
    $buf = if ($sentry) { $sentry.Data } else { $null }
    $U.Authorized = ($null -eq $buf -or $buf -eq '')
}

# ---------------------------------------------------------------------------
# Callbacks from the server interface (weather / pong delivery by fd)
# ---------------------------------------------------------------------------

function Invoke-SysReceivePong {
    param([string]$From, [string]$Data, [string]$Pc, [string]$Hops)
    $parts = $Data -split ' '
    if ($parts.Count -lt 2) { return }
    $fd = A2I $parts[0]
    $now = A2I $parts[1]
    if ($fd -eq -1) { return }
    foreach ($u in $Script:SysIF.Users) {
        if ($u.Fd -eq $fd) {
            Send-UData -U $u -S ("`r`nPONG received from {0}: {1} seconds ({2},{3})`r`n" -f `
                $From, ((Get-MTime) - $now), $Pc, $Hops)
            Write-Prompt -U $u
            return
        }
    }
}

function Invoke-SysReceiveWeather {
    param([int]$Fd, $Wp)
    if ($Fd -eq -2) {
        # 'wp create' bootstrap: turn the incoming profile into a stored one
        $weather = Export-WProfileString -Wp $Wp
        $array = Break-Packet -S $weather -Max 100
        New-WProfile -Name $Wp.Name -Creation (Get-MGMTime) -Origin $Script:MyServer.Ident | Out-Null
        $wp2 = Get-WProfile -Name $Wp.Name
        if ($wp2) { Import-WProfileArray -Wp $wp2 -A $array }
        return
    }
    foreach ($u in $Script:SysIF.Users) {
        if ($u.Fd -eq $Fd) {
            Repair-WProfile -Wp $Wp -Lat $u.Lat -Lon $u.Lon
            Write-SysWeather -U $u -Wp $Wp
            break
        }
    }
}

function Invoke-SysReceiveMetar {
    param([int]$Fd, [string]$Wp, [string]$Data)
    foreach ($u in $Script:SysIF.Users) {
        if ($u.Fd -eq $Fd) {
            Send-UData -U $u -S ("`r`nWeather profile {0}:`r`n`r`n" -f $Wp)
            Send-UData -U $u -S ($Data + "`r`n")
            Write-Prompt -U $u
            break
        }
    }
}

function Invoke-SysReceiveNowx {
    param([int]$Fd, [string]$St)
    if ($Fd -eq -2) {
        New-WProfile -Name $St -Creation (Get-MGMTime) -Origin $Script:MyServer.Ident | Out-Null
    }
    foreach ($u in $Script:SysIF.Users) {
        if ($u.Fd -eq $Fd) {
            Send-UData -U $u -S ("`r`nNo weather available for {0}.`r`n" -f $St)
            Write-Prompt -U $u
            break
        }
    }
}

# ---------------------------------------------------------------------------
# Parsing
# ---------------------------------------------------------------------------

function Invoke-SysParse {
    param($U, [string]$Line)
    $U.LastActive = Get-MTime
    $U.LastPing = Get-MTime
    Invoke-SysDoParse -U $U -Line $Line
}

function Invoke-SysDoParse {
    param($U, [string]$Line)
    $array = Break-Args -S $Line -Max 100
    $count = $array.Count
    if ($count -eq 0) { return }
    for ($i = 0; $i -lt $Script:SysCmds.Count; $i++) {
        if (Test-StrIEqual $array[0] $Script:SysCmds[$i]) {
            if ($Script:SysNeedAuth[$i] -and -not $U.Authorized) {
                Send-UData -U $U -S "Not authorized, use 'pwd'.`r`n"
            } else {
                $rest = @()
                for ($j = 1; $j -lt $count; $j++) { $rest += $array[$j] }
                Invoke-SysRuncmd -Num $i -Data $rest -Count $rest.Count -U $U
            }
            return
        }
    }
    Send-UData -U $U -S "Syntax error.`r`n"
}

function Write-SysUsage {
    param($U, [int]$Cmd, [string]$S)
    Send-UData -U $U -S ("Usage: {0} {1}`r`n" -f $Script:SysCmds[$Cmd], $S)
}

function Invoke-SysRuncmd {
    param([int]$Num, [string[]]$Data, [int]$Count, $U)
    switch ($Num) {
        0  { Invoke-SysServers  -U $U -Data $Data -Count $Count -Type 1 }
        1  { Invoke-SysInfo     -U $U }
        2  { Invoke-SysPing     -U $U -Data $Data -Count $Count }
        3  { Invoke-SysConnect  -U $U -Data $Data -Count $Count }
        4  { Invoke-SysTime     -U $U }
        5  { Invoke-SysRoute    -U $U -Data $Data -Count $Count }
        6  { Invoke-SysWeather  -U $U -Data $Data -Count $Count }
        7  { Invoke-SysDisconnect -U $U -Data $Data -Count $Count }
        8  { Invoke-SysHelp     -U $U -Data $Data -Count $Count }
        9  { Kill-Conn -U $U -Reason $Script:KILL_COMMAND }
        10 { Invoke-SysStat     -U $U -Data $Data -Count $Count }
        11 { Invoke-SysSay      -U $U -Data $Data -Count $Count }
        12 { Invoke-SysClients  -U $U -Data $Data -Count $Count }
        13 { Invoke-SysCert     -U $U -Data $Data -Count $Count }
        14 { Invoke-SysPwd      -U $U -Data $Data -Count $Count }
        15 { Invoke-SysDistance -U $U -Data $Data -Count $Count }
        16 { Invoke-SysRange    -U $U -Data $Data -Count $Count }
        17 { Invoke-SysLog      -U $U -Data $Data -Count $Count }
        18 { Invoke-SysWall     -U $U -Data $Data -Count $Count }
        19 { Clear-IFGuards -Iface $Script:ServerIF; Send-UData -U $U -S "Guard connections deleted.`r`n" }
        20 { Invoke-SysMetar    -U $U -Data $Data -Count $Count }
        21 { Invoke-SysWp       -U $U -Data $Data -Count $Count }
        22 { Invoke-SysKill     -U $U -Data $Data -Count $Count }
        23 { Invoke-SysPos      -U $U -Data $Data -Count $Count }
        24 { Invoke-SysDump     -U $U -Data $Data -Count $Count }
        25 { Invoke-SysServers  -U $U -Data $Data -Count $Count -Type 2 }
        26 { Invoke-SysRefMetar -U $U }
    }
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

function Invoke-SysInfo {
    param($U)
    Send-UData -U $U -S ("Number of servers in the network: {0}`r`n" -f $Script:RootServer.Count)
    Send-UData -U $U -S ("Number of clients in the network: {0}`r`n" -f $Script:RootClient.Count)
    Send-UData -U $U -S ("Number of certificates in the network: {0}`r`n" -f $Script:RootCert.Count)
}

function Invoke-SysHelp {
    param($U, [string[]]$Data, [int]$Count)
    $topic = if ($Count -gt 0) { $Data[0] } else { 'global' }
    $globalmode = ($Count -eq 0)
    $topicmode = (Test-StrIEqual $topic 'topics')
    $path = Join-Path $Script:FsdDir $Script:PATH_FSD_HELP
    if (-not (Test-Path -LiteralPath $path)) {
        Send-UData -U $U -S "Could not open help file 'help.txt'`r`n"
        return
    }
    $copymode = $false
    foreach ($line in [System.IO.File]::ReadAllLines($path, $Script:FsdEnc)) {
        if ($line.StartsWith('%topic')) {
            if ($copymode) { break }
            $rest = $line.Substring(6).TrimStart()
            $colon = $rest.IndexOf(':')
            if ($colon -lt 0) { continue }
            $top = $rest.Substring(0, $colon)
            $desc = $rest.Substring($colon + 1)
            if ($topicmode) {
                Send-UData -U $U -S ("{0}: {1}" -f $top, $desc)
                continue
            }
            if (Test-StrIEqual $top $topic) {
                Send-UData -U $U -S ("{0} {1}" -f 'FSD ONLINE DOCUMENTATION', $desc)
                Send-UData -U $U -S ('=' * 79 + "`r`n")
                $copymode = $true
            }
        } elseif ($copymode) {
            Send-UData -U $U -S ($line + "`r`n")
        }
    }
    if ($globalmode) {
        $line = ''
        foreach ($c in $Script:SysCmds) {
            if ($line) { $line += ' ' }
            $line += $c
            if ($line.Length -gt 65) {
                Send-UData -U $U -S ($line.ToUpper($Script:Inv) + "`r`n")
                $line = ''
            }
        }
        if ($line) { Send-UData -U $U -S ($line.ToUpper($Script:Inv) + "`r`n") }
    }
}

function Invoke-SysStat {
    param($U, [string[]]$Data, [int]$Count)
    $filter = if ($Count -gt 0) { $Data[0] } else { '' }
    foreach ($l in (Get-MgrListing -Filter $filter)) {
        Send-UData -U $U -S ($l + "`r`n")
    }
}

function Invoke-SysServers {
    param($U, [string[]]$Data, [int]$Count, [int]$Type)
    $match = $null
    if ($Count -eq 1) {
        $found = $false
        foreach ($s in $Script:RootServer) {
            if (($s.Name.IndexOf($Data[0], [StringComparison]::OrdinalIgnoreCase) -ge 0) -or
                ($s.Ident.IndexOf($Data[0], [StringComparison]::OrdinalIgnoreCase) -ge 0)) {
                if ($match) { $found = $true; break }
                $match = $s
            }
        }
        if (-not $found -and $match) {
            $flags = ''
            Send-UData -U $U -S ("ID      : {0}`r`n" -f $match.Ident)
            Send-UData -U $U -S ("Name    : {0}`r`n" -f $match.Name)
            Send-UData -U $U -S ("Version : {0}`r`n" -f $match.Version)
            Send-UData -U $U -S ("Mail    : {0}`r`n" -f $match.Email)
            Send-UData -U $U -S ("Host    : {0}`r`n" -f $match.Hostname)
            Send-UData -U $U -S ("Location: {0}`r`n" -f $match.Location)
            Send-UData -U $U -S ("Hops    : {0}`r`n" -f $match.Hops)
            Send-UData -U $U -S ("Lag     : {0} seconds`r`n" -f $match.Lag)
            if ($match.Flags -band $Script:SERVER_SILENT) { $flags = 'SILENT' }
            if ($match.Flags -band $Script:SERVER_METAR) {
                if ($flags) { $flags += ', ' }
                $flags += 'METAR'
            }
            Send-UData -U $U -S ("Flags  : {0}`r`n" -f $flags)
            return
        }
    }
    if ($Type -eq 1) {
        Send-UData -U $U -S "ID         Host                      Fl Hops Lag  Name`r`n"
        Send-UData -U $U -S ("-" * 61 + "`r`n")
        foreach ($s in $Script:RootServer) {
            if ($Count -gt 0 -and
                ($s.Name.IndexOf($Data[0], [StringComparison]::OrdinalIgnoreCase) -lt 0) -and
                ($s.Ident.IndexOf($Data[0], [StringComparison]::OrdinalIgnoreCase) -lt 0)) { continue }
            $fl = '{0}{1}' -f $(if ($s.Flags -band $Script:SERVER_METAR) { 'M' } else { '-' }),
                              $(if ($s.Flags -band $Script:SERVER_SILENT) { 'S' } else { '-' })
            Send-UData -U $U -S ('{0} {1} {2} {3} {4}  {5}' -f `
                $s.Ident.PadRight(10), $s.Hostname.PadRight(25), $fl,
                $s.Hops.ToString('00', $Script:Inv), $s.Lag.ToString('00', $Script:Inv), $s.Name + "`r`n")
        }
        Send-UData -U $U -S "`r`n"
    } else {
        Send-UData -U $U -S "ID         Version     Mail                 Location`r`n"
        Send-UData -U $U -S ("-" * 61 + "`r`n")
        foreach ($s in $Script:RootServer) {
            if ($Count -gt 0 -and
                ($s.Name.IndexOf($Data[0], [StringComparison]::OrdinalIgnoreCase) -lt 0) -and
                ($s.Ident.IndexOf($Data[0], [StringComparison]::OrdinalIgnoreCase) -lt 0)) { continue }
            Send-UData -U $U -S ('{0} {1} {2} {3}' -f `
                $s.Ident.PadRight(10), $s.Version.PadRight(11), $s.Email.PadRight(20), $s.Location + "`r`n")
        }
        Send-UData -U $U -S "`r`n"
    }
}

function Invoke-SysRoute {
    param($U, [string[]]$Data, [int]$Count)
    Send-UData -U $U -S "ID         Next hop`r`n"
    Send-UData -U $U -S ("-" * 19 + "`r`n")
    foreach ($s in $Script:RootServer) {
        if ($Count -gt 0 -and
            ($s.Name.IndexOf($Data[0], [StringComparison]::OrdinalIgnoreCase) -lt 0) -and
            ($s.Ident.IndexOf($Data[0], [StringComparison]::OrdinalIgnoreCase) -lt 0)) { continue }
        $dest = ''
        if ([object]::ReferenceEquals($s, $Script:MyServer)) { $dest = '*local*' }
        elseif (-not $s.Path) { $dest = '*broadcast*' }
        else { $dest = '{0}:{1}' -f $s.Path.Peer, $s.Path.Port }
        Send-UData -U $U -S ('{0} {1}' -f $s.Ident.PadRight(10), $dest + "`r`n")
    }
    Send-UData -U $U -S "`r`n"
}

function Invoke-SysPing {
    param($U, [string[]]$Data, [int]$Count)
    if ($Count -eq 0) { Write-SysUsage -U $U -Cmd 2 -S '<ident>'; return }
    $now = Get-MTime
    $data = '{0} {1}' -f $U.Fd, $now
    Invoke-SendPing -Dest $Data[0] -Data $data
}

function Invoke-SysConnect {
    param($U, [string[]]$Data, [int]$Count)
    if ($Count -lt 1) {
        if ($Script:ServerIF.Users.Count -eq 0) {
            Send-UData -U $U -S "No active server connections.`r`n"
        } else {
            Send-UData -U $U -S "fd  Limit  Out-Q  In-Q  Feed Peer`r`n"
            Send-UData -U $U -S ("-" * 33 + "`r`n")
            foreach ($u in $Script:ServerIF.Users) {
                $ident = if ($u.ThisServer) { $u.ThisServer.Ident } else { '<Unknown>' }
                Send-UData -U $U -S ('{0} {1}   {2} {3} {4} {5}:{6} ({7})' -f `
                    $u.Fd.ToString('00', $Script:Inv),
                    $u.OutBufSoftLimit.ToString().PadLeft(5),
                    $u.OutBuf.Length.ToString().PadLeft(5),
                    $u.InBuf.Length.ToString().PadLeft(5),
                    $u.Feed.ToString().PadLeft(5),
                    $u.Peer, $u.Port, $ident) + "`r`n"
            }
        }
        if ($Script:ServerIF.Guards.Count -eq 0) {
            Send-UData -U $U -S "No pending connections.`r`n"
        } else {
            Send-UData -U $U -S "Pending connections:`r`n"
            foreach ($g in $Script:ServerIF.Guards) {
                Send-UData -U $U -S ("  {0}:{1}`r`n" -f $g.Host, $g.Port)
            }
        }
        return
    }
    $port = 3011
    if ($Count -gt 1) { $port = A2I $Data[1] }
    if ((Add-IFOutgoing -Iface $Script:ServerIF -Name $Data[0] -Port $port -Terminal $U) -eq 1) {
        Invoke-SendServerNotify -Dest '*' -Subject $Script:MyServer -ToWho $null
    }
}

function Invoke-SysDisconnect {
    param($U, [string[]]$Data, [int]$Count)
    if ($Count -eq 0) { Write-SysUsage -U $U -Cmd 7 -S '<fd>'; return }
    $fd = A2I $Data[0]
    foreach ($u in $Script:ServerIF.Users) {
        if ($u.Fd -eq $fd) {
            Kill-Conn -U $u -Reason $Script:KILL_COMMAND
            Send-UData -U $U -S "Disconnected`r`n"
            return
        }
    }
    Send-UData -U $U -S "No such connection was found.`r`n"
}

function Invoke-SysSay {
    param($U, [string[]]$Data, [int]$Count)
    if ($Count -lt 2) { Write-SysUsage -U $U -Cmd 11 -S '<user> <text>'; return }
    $rest = @()
    for ($i = 1; $i -lt $Count; $i++) { $rest += $Data[$i] }
    $buf = $rest -join ' '
    if (-not (Invoke-SendMulticast -Source $null -Dest $Data[0] -S $buf -Cmd $Script:CL_MESSAGE -MultiOk $true -Ex $null)) {
        Send-UData -U $U -S ("client '{0}' unknown.`r`n" -f $Data[0])
        return
    }
}

function Invoke-SysClients {
    param($U, [string[]]$Data, [int]$Count)
    if ($Count -gt 0) {
        $match = $null
        $multi = $false
        foreach ($c in $Script:RootClient) {
            if (($c.Callsign.IndexOf($Data[0], [StringComparison]::OrdinalIgnoreCase) -ge 0) -or
                ($c.Cid.IndexOf($Data[0], [StringComparison]::OrdinalIgnoreCase) -ge 0)) {
                if ($match) { $multi = $true; break }
                $match = $c
            }
        }
        if (-not $multi) {
            if (-not $match) {
                Send-UData -U $U -S "No match.`r`n"
                return
            }
            Send-UData -U $U -S ("Callsign    : {0}`r`n" -f $match.Callsign)
            if ($match.RealName.Length -gt 0) {
                Send-UData -U $U -S ("Real name   : {0}`r`n" -f $match.RealName)
            }
            Send-UData -U $U -S ("Type        : {0}`r`n" -f $(if ($match.Type -eq $Script:CLIENT_ATC) { 'atc' } else { 'pilot' }))
            Send-UData -U $U -S ("Online      : {0}`r`n" -f (Format-Elapsed -Now ((Get-MTime) - $match.StartTime)))
            Send-UData -U $U -S ("Idle        : {0}`r`n" -f (Format-Elapsed -Now ((Get-MTime) - $match.Alive)))
            if ($match.Frequency -ne 0 -and $match.Frequency -lt 100000) {
                Send-UData -U $U -S ("Frequency   : 1{0:00}.{1:000}`r`n" -f ([int]($match.Frequency / 1000)), ($match.Frequency % 1000))
            }
            if ($match.PositionOk) {
                Send-UData -U $U -S ("Location    : {0}`r`n" -f (Format-Loc -Lat $match.Lat -Lon $match.Lon))
                Send-UData -U $U -S ("Altitude    : {0}`r`n" -f $match.Altitude)
                if ($match.Type -eq $Script:CLIENT_PILOT) {
                    Send-UData -U $U -S ("Groundspeed : {0}`r`n" -f $match.GroundSpeed)
                    Send-UData -U $U -S ("Transponder : {0}`r`n" -f $match.Transponder)
                } else {
                    Send-UData -U $U -S ("Facility    : {0}`r`n" -f $match.FacilityType)
                }
            }
            return
        }
    }
    Send-UData -U $U -S "Call-sign    CID     Online   Idle     Type  Server     Frequency`r`n"
    Send-UData -U $U -S ("-" * 65 + "`r`n")
    foreach ($c in $Script:RootClient) {
        if ($Count -gt 0 -and
            ($c.Callsign.IndexOf($Data[0], [StringComparison]::OrdinalIgnoreCase) -lt 0) -and
            ($c.Cid.IndexOf($Data[0], [StringComparison]::OrdinalIgnoreCase) -lt 0)) { continue }
        $line = '{0}   {1} {2} {3} {4} {5} {6}' -f `
            $c.Callsign.PadRight(10), $c.Cid.PadRight(7),
            (Format-Elapsed -Now ((Get-MTime) - $c.StartTime)),
            (Format-Elapsed -Now ((Get-MTime) - $c.Alive)),
            ($(if ($c.Type -eq $Script:CLIENT_ATC) { 'ATC' } else { 'PILOT' })).PadRight(5),
            $c.Location.Ident.PadRight(10), $c.Frequency
        if ($c.Frequency -ne 0 -and $c.Frequency -lt 100000) {
            $line += (' 1{0:00}.{1:000}' -f ([int]($c.Frequency / 1000)), ($c.Frequency % 1000))
        }
        Send-UData -U $U -S ($line + "`r`n")
    }
}

function Invoke-SysCert {
    param($U, [string[]]$Data, [int]$Count)
    if ($Count -lt 2) {
        Send-UData -U $U -S "CID        Max level      Origin     Creation (UTC)       Last used (local)`r`n"
        Send-UData -U $U -S ("-" * 75 + "`r`n")
        foreach ($c in $Script:RootCert) {
            if ($Count -eq 1 -and ($c.Cid.IndexOf($Data[0], [StringComparison]::OrdinalIgnoreCase) -lt 0)) { continue }
            Send-UData -U $U -S ('{0} {1}  {2} {3}  {4}' -f `
                $c.Cid.PadRight(10), $Script:CertLevels[$c.Level].PadRight(13),
                $c.Origin.PadRight(10), (Format-SprintDate -Now $c.Creation),
                (Format-SprintDate -Now $c.PrevVisit) + "`r`n")
        }
        return
    }
    $mode = -1
    if (Test-StrIEqual $Data[0] 'add')         { $mode = $Script:CERT_ADD }
    elseif (Test-StrIEqual $Data[0] 'delete')  { $mode = $Script:CERT_DELETE }
    elseif (Test-StrIEqual $Data[0] 'modify')  { $mode = $Script:CERT_MODIFY }
    else {
        Send-UData -U $U -S "Invalid mode, should be 'add', 'delete' or 'modify'.`r`n"
        return
    }
    $c = Get-Cert -Cid $Data[1]
    switch ($mode) {
        $Script:CERT_ADD {
            if ($Count -lt 4) { Write-SysUsage -U $U -Cmd 13 -S 'add <cid> <pwd> <level>'; return }
            if ($c) { Send-UData -U $U -S "Certificate already exists.`r`n"; return }
            $level = Resolve-CertLevel -Name $Data[3]
            if ($level -lt 0) {
                Send-UData -U $U -S "Unknown level, use 'help cert' for help.`r`n"
                return
            }
            $c = New-Certificate -Cid $Data[1] -Password $Data[2] -Level $level -Creation (Get-MGMTime) -Origin $Script:MyServer.Ident
            Invoke-SendCert -Dest '*' -Cmd $mode -Cert $c -Direction $null
        }
        $Script:CERT_DELETE {
            if (-not $c) { Send-UData -U $U -S "Certificate does not exist.`r`n"; return }
            Invoke-SendCert -Dest '*' -Cmd $mode -Cert $c -Direction $null
            Remove-Certificate -Cert $c
        }
        $Script:CERT_MODIFY {
            if (-not $c) { Send-UData -U $U -S "Certificate does not exist.`r`n"; return }
            if ($Count -lt 3) { Write-SysUsage -U $U -Cmd 13 -S 'modify <cid> <level>'; return }
            $level = Resolve-CertLevel -Name $Data[2]
            if ($level -lt 0) {
                Send-UData -U $U -S "Unknown level, use 'help cert' for help.`r`n"
                return
            }
            Set-CertificateConfig -Cert $c -Password $null -Level $level -Creation (Get-MGMTime) -Origin $Script:MyServer.Ident
            Invoke-SendCert -Dest '*' -Cmd $mode -Cert $c -Direction $null
        }
    }
    Send-UData -U $U -S "Your change has been executed, but the certificate file`r`n"
    Send-UData -U $U -S "has not been updated. Please update this file if your change`r`n"
    Send-UData -U $U -S "should be permanent.`r`n"
}

function Resolve-CertLevel {
    param([string]$Name)
    for ($l = 0; $l -le $Script:LEV_MAX; $l++) {
        if (Test-StrIEqual $Script:CertLevels[$l] $Name) { return $l }
    }
    return -1
}

function Invoke-SysDistance {
    param($U, [string[]]$Data, [int]$Count)
    if ($Count -lt 2) { Write-SysUsage -U $U -Cmd 15 -S '<client1> <client2>'; return }
    $c1 = Get-FsdClient -Ident $Data[0]
    if (-not $c1) { Send-UData -U $U -S ("client '{0}' not found.`r`n" -f $Data[0]); return }
    $c2 = Get-FsdClient -Ident $Data[1]
    if (-not $c2) { Send-UData -U $U -S ("client '{0}' not found.`r`n" -f $Data[1]); return }
    if (-not $c1.PositionOk) {
        Send-UData -U $U -S ("client '{0}' did not send a position report.`r`n" -f $Data[0]); return
    }
    if (-not $c2.PositionOk) {
        Send-UData -U $U -S ("client '{0}' did not send a position report.`r`n" -f $Data[1]); return
    }
    Send-UData -U $U -S ((F6 (Get-ClientDistance -Client $c1 -Other $c2)) + " NM.`r`n")
}

function Invoke-SysTime {
    param($U)
    $now = [DateTime]::Now
    Send-UData -U $U -S ("{0:00}:{1:00}:{2:00} local`r`n" -f $now.Hour, $now.Minute, $now.Second)
    $utc = [DateTime]::UtcNow
    Send-UData -U $U -S ("{0:00}:{1:00}:{2:00} UTC`r`n" -f $utc.Hour, $utc.Minute, $utc.Second)
}

function Invoke-SysWeather {
    param($U, [string[]]$Data, [int]$Count)
    if ($Count -lt 1) { Write-SysUsage -U $U -Cmd 6 -S '<profile>'; return }
    $s = Invoke-RequestMetar -Client $Script:MyServer.Ident -Metar $Data[0] -Parsed 1 -Fd $U.Fd
    if ($s) { Send-UData -U $U -S ("Weather request sent to METAR host {0}.`n`r" -f $s.Ident) }
    else    { Send-UData -U $U -S "No METAR host in network.`r`n" }
}

function Invoke-SysMetar {
    param($U, [string[]]$Data, [int]$Count)
    if ($Count -lt 1) { Write-SysUsage -U $U -Cmd 20 -S '<profile>'; return }
    $s = Invoke-RequestMetar -Client $Script:MyServer.Ident -Metar $Data[0] -Parsed 0 -Fd $U.Fd
    if ($s) { Send-UData -U $U -S ("Metar request sent to METAR host {0}.`n`r" -f $s.Ident) }
    else    { Send-UData -U $U -S "No METAR host in network.`r`n" }
}

function Write-SysWeather {
    param($U, $Wp)
    Send-UData -U $U -S ("`r`nWeather profile {0}:`r`n`r`n" -f $Wp.Name)

    $line = '{0}{1}{2}' -f 'Cloud layer'.PadRight(20), '1'.PadRight(10), '2'.PadRight(10)
    Send-UData -U $U -S ($line + "`r`n")
    $line = '  Floor'.PadRight(20)
    for ($x = 0; $x -lt 2; $x++) { $line += ('{0}' -f $Wp.Clouds[$x].Floor.ToString().PadRight(10)) }
    Send-UData -U $U -S ($line + "`r`n")
    $line = '  Ceiling'.PadRight(20)
    for ($x = 0; $x -lt 2; $x++) { $line += ('{0}' -f $Wp.Clouds[$x].Ceiling.ToString().PadRight(10)) }
    Send-UData -U $U -S ($line + "`r`n")
    $line = '  Coverage'.PadRight(20)
    for ($x = 0; $x -lt 2; $x++) { $line += ('{0}' -f $Wp.Clouds[$x].Coverage.ToString().PadRight(10)) }
    Send-UData -U $U -S ($line + "`r`n")
    $line = '  Turbulence'.PadRight(20)
    for ($x = 0; $x -lt 2; $x++) { $line += ('{0}' -f $Wp.Clouds[$x].Turbulence.ToString().PadRight(10)) }
    Send-UData -U $U -S ($line + "`r`n")
    $line = '  Icing'.PadRight(20)
    for ($x = 0; $x -lt 2; $x++) {
        $v = if ($Wp.Clouds[$x].Icing) { 'Yes' } else { 'No' }
        $line += $v.PadRight(10)
    }
    Send-UData -U $U -S ($line + "`r`n")

    $line = '{0}{1}{2}{3}{4}' -f 'Wind layer'.PadRight(20), '1'.PadRight(10), '2'.PadRight(10), '3'.PadRight(10), '4'.PadRight(10)
    Send-UData -U $U -S ("`r`n" + $line + "`r`n")
    $line = '  Floor'.PadRight(20)
    for ($x = 0; $x -lt 4; $x++) { $line += ('{0}' -f $Wp.Winds[$x].Floor.ToString().PadRight(10)) }
    Send-UData -U $U -S ($line + "`r`n")
    $line = '  Ceiling'.PadRight(20)
    for ($x = 0; $x -lt 4; $x++) { $line += ('{0}' -f $Wp.Winds[$x].Ceiling.ToString().PadRight(10)) }
    Send-UData -U $U -S ($line + "`r`n")
    $line = '  Direction'.PadRight(20)
    for ($x = 0; $x -lt 4; $x++) { $line += ('{0}' -f $Wp.Winds[$x].Direction.ToString().PadRight(10)) }
    Send-UData -U $U -S ($line + "`r`n")
    $line = '  Speed'.PadRight(20)
    for ($x = 0; $x -lt 4; $x++) { $line += ('{0}' -f $Wp.Winds[$x].Speed.ToString().PadRight(10)) }
    Send-UData -U $U -S ($line + "`r`n")
    $line = '  Gusting'.PadRight(20)
    for ($x = 0; $x -lt 4; $x++) {
        $v = if ($Wp.Winds[$x].Gusting) { 'Yes' } else { 'No' }
        $line += $v.PadRight(10)
    }
    Send-UData -U $U -S ($line + "`r`n")

    $line = '{0}{1}{2}{3}{4}' -f 'Temp layer'.PadRight(20), '1'.PadRight(10), '2'.PadRight(10), '3'.PadRight(10), '4'.PadRight(10)
    Send-UData -U $U -S ("`r`n" + $line + "`r`n")
    $line = '  Ceiling'.PadRight(20)
    for ($x = 0; $x -lt 4; $x++) { $line += ('{0}' -f $Wp.Temps[$x].Ceiling.ToString().PadRight(10)) }
    Send-UData -U $U -S ($line + "`r`n")
    $line = '  Temperature'.PadRight(20)
    for ($x = 0; $x -lt 4; $x++) { $line += ('{0}' -f $Wp.Temps[$x].Temp.ToString().PadRight(10)) }
    Send-UData -U $U -S ($line + "`r`n`r`n")

    Send-UData -U $U -S ("Visibility  : " + (F2 $Wp.Visibility) + " SM`r`n")
    Send-UData -U $U -S ("Barometer   : {0} Hg`r`n" -f $Wp.Barometer)
    Write-Prompt -U $U
}

function Invoke-SysRange {
    param($U, [string[]]$Data, [int]$Count)
    if ($Count -lt 1) { Write-SysUsage -U $U -Cmd 16 -S '<callsign>'; return }
    $c = Get-FsdClient -Ident $Data[0]
    if (-not $c) { Send-UData -U $U -S "No such callsign.`n`r"; return }
    Send-UData -U $U -S ("Range : {0} NM.`r`n" -f (Get-ClientRange -Client $c))
}

function Invoke-SysLog {
    param($U, [string[]]$Data, [int]$Count)
    if ($Count -lt 2) {
        Write-SysUsage -U $U -Cmd 17 -S "(show|delete) <maxlevel> [amount]`r`n  Where level is 0=Emergency, 1=Alert, 2=Critical, 3=Error, 4=Warning, 5=Info`r`n  6=Debug"
        return
    }
    $maxlevel = A2I $Data[1]
    $amount = $Script:MAXLOG
    if ($Count -gt 2) { $amount = A2I $Data[2] }
    if ($amount -gt $Script:MAXLOG) { $amount = $Script:MAXLOG }
    if ($maxlevel -ge $Script:L_MAX) { $maxlevel = $Script:L_MAX - 1 }
    $mode = 0
    if (Test-StrIEqual $Data[0] 'show')   { $mode = 1 }
    elseif (Test-StrIEqual $Data[0] 'delete') { $mode = 2 }
    else {
        Send-UData -U $U -S "Invalid operation mode, use 'show' or 'delete'.`r`n"
        return
    }
    for ($i = $Script:LogHistory.Count - 1; $i -ge 0 -and $amount -gt 0; $i--) {
        $entry = $Script:LogHistory[$i]
        if ($entry.Level -gt $maxlevel) { continue }
        if ($mode -eq 1) { Send-UData -U $U -S ($entry.Msg + "`r`n") }
        else { $Script:LogHistory.RemoveAt($i) }
        $amount--
    }
}

function Invoke-SysPwd {
    param($U, [string[]]$Data, [int]$Count)
    if ($Count -lt 1) { Write-SysUsage -U $U -Cmd 14 -S '<password>'; return }
    $sgroup = Get-ConfigGroup -Name 'system'
    $sentry = if ($sgroup) { Get-ConfigEntry -Group $sgroup -Name 'password' } else { $null }
    $buf = if ($sentry) { $sentry.Data } else { $null }
    if ($buf -and ($buf -ceq $Data[0])) { $U.Authorized = $true }
    if (-not $U.Authorized) { Send-UData -U $U -S "Password incorrect.`r`n" }
    else { Send-UData -U $U -S "Password correct.`r`n" }
}

function Invoke-SysWall {
    param($U, [string[]]$Data, [int]$Count)
    if ($Count -lt 1) { Write-SysUsage -U $U -Cmd 18 -S '<text>'; return }
    $buf = $Data -join ' '
    foreach ($u in $Script:ClientIF.Users) {
        $c = $u.ThisClient
        if (-not $c) { continue }
        Invoke-SendGeneric -To $c.Callsign -Dest $c -Ex $null -Source $null `
            -From 'server' -S $buf -Cmd $Script:CL_MESSAGE
    }
}

function Invoke-SysWp {
    param($U, [string[]]$Data, [int]$Count)
    $help = '<show|create|delete|activate|set> <name> ...'
    if ($Count -eq 0) { Write-SysUsage -U $U -Cmd 21 -S $help; return }
    $mode = $Data[0]
    if (Test-StrIEqual $mode 'show') {
        if ($Count -eq 1) {
            Send-UData -U $U -S "Active  Name  Origin     Creation`r`n"
            Send-UData -U $U -S ("-" * 33 + "`r`n")
            foreach ($wp in $Script:RootProfile) {
                $org = if ($wp.Origin) { $wp.Origin } else { '<local>' }
                Send-UData -U $U -S ('{0}  {1}  {2} {3}' -f `
                    ($(if ($wp.Active) { 'Yes' } else { 'No' })).PadRight(6),
                    $wp.Name.PadRight(4), $org.PadRight(10),
                    (Format-SprintDate -Now $wp.Creation) + "`r`n")
            }
        } else {
            $wp = Get-WProfile -Name $Data[1]
            if (-not $wp) {
                Send-UData -U $U -S ("Could not find weather profile '{0}'`r`n" -f $Data[1])
                return
            }
            Write-SysWeather -U $U -Wp $wp
        }
        return
    }
    if ($Count -lt 2) { Write-SysUsage -U $U -Cmd 21 -S $help; return }
    $name = ConvertTo-Upper $Data[1]
    $wp = Get-WProfile -Name $name
    if (Test-StrIEqual $mode 'create') {
        if ($wp) { Send-UData -U $U -S "Weather profile already exists!`r`n"; return }
        $s = Invoke-RequestMetar -Client $Script:MyServer.Ident -Metar $name -Parsed 1 -Fd -2
        if ($s) {
            Send-UData -U $U -S ("A METAR request has been sent out to server {0} to get the initial data.`r`n" -f $s.Ident)
            Send-UData -U $U -S "The weather profile will created when the data arrives.`r`n"
        } else {
            New-WProfile -Name $name -Creation (Get-MGMTime) -Origin $Script:MyServer.Ident | Out-Null
            Send-UData -U $U -S "No METAR host in network.`r`n"
            Send-UData -U $U -S "The weather profile has been created without default data.`r`n"
        }
        return
    }
    if (-not $wp) {
        Send-UData -U $U -S ("Could not find weather profile '{0}'`r`n" -f $name)
        return
    }
    if (Test-StrIEqual $mode 'delete') {
        if ($wp.Active) { Invoke-SendDelWp -Wp $wp }
        Remove-WProfile -Wp $wp
        Send-UData -U $U -S "Weather profile deleted.`r`n"
    } elseif (Test-StrIEqual $mode 'activate') {
        Enable-WProfile -Wp $wp
        Update-WProfileRawCode -Wp $wp
        Invoke-SendAddWp -Direction $null -Wp $wp
        Send-UData -U $U -S "Weather profile now in effect!`r`n"
    } elseif (Test-StrIEqual $mode 'set') {
        $p = ''
        $v = ''
        if ($Count -gt 2) { $p = $Data[2] }
        if ($Count -gt 3) { $v = $Data[3] }
        $val = Try-A2I $v
        if ($null -eq $val) {
            Send-UData -U $U -S ("Invalid value '{0}'`r`n" -f $v)
        } else {
            Invoke-SysWpSet -U $U -Wp $wp -P $p -Val $val
        }
    } else {
        Send-UData -U $U -S "Invalid wp mode.`r`n"
    }
}

function Invoke-SysWpSet {
    param($U, $Wp, [string]$P, [int]$Val)
    $cat1 = @('winds', 'clouds', 'temperature', 'pressure', 'visibility')
    $parts = $P -split '\.', 2
    $cat = $parts[0]
    $where = if ($parts.Count -gt 1) { $parts[1] } else { $null }
    $x = -1
    for ($i = 0; $i -lt $cat1.Count; $i++) {
        if (Test-StrIEqual $cat $cat1[$i]) { $x = $i; break }
    }
    if ($x -lt 0) {
        Send-UData -U $U -S ("Invalid category '{0}'.`r`n" -f $cat)
        return
    }
    switch ($x) {
        3 { $Wp.Barometer = $Val; return }
        4 { $Wp.Visibility = [double]$Val; return }
    }
    if (-not $where) {
        Send-UData -U $U -S "Invalid parameter`r`n"
        return
    }
    $sub = $where -split '\.', 2
    $idxStr = $sub[0]
    $more = if ($sub.Count -gt 1) { $sub[1] } else { $null }
    $index = A2I $idxStr
    if ($idxStr -notmatch '^[0-9]+$') {
        Send-UData -U $U -S ("Invalid index '{0}'`r`n" -f $idxStr)
        return
    }
    $index--
    $limit = 4
    if ($x -eq 1) { $limit = 2 }
    if ($index -lt 0 -or $index -gt $limit) {
        Send-UData -U $U -S ("Invalid index {0}`r`n" -f ($index + 1))
        return
    }
    if (-not $more) {
        Send-UData -U $U -S "Invalid parameter`r`n"
        return
    }
    $strings = @()
    switch ($x) {
        0 { $strings = @('floor', 'ceiling', 'direction', 'speed', 'gusting') }
        1 { $strings = @('floor', 'ceiling', 'coverage', 'turbulence', 'icing') }
        2 { $strings = @('ceiling', 'temperature') }
    }
    $y = -1
    for ($i = 0; $i -lt $strings.Count; $i++) {
        if (Test-StrIEqual $more $strings[$i]) { $y = $i; break }
    }
    if ($y -lt 0) {
        Send-UData -U $U -S ("Invalid specifier '{0}'`r`n" -f $more)
        return
    }
    switch ($x) {
        0 {
            if ($index -ge $Wp.Winds.Count) { Send-UData -U $U -S "Invalid index`r`n"; return }
            switch ($y) {
                0 { $Wp.Winds[$index].Floor = $Val }
                1 { $Wp.Winds[$index].Ceiling = $Val }
                2 { $Wp.Winds[$index].Direction = $Val }
                3 { $Wp.Winds[$index].Speed = $Val }
                4 { $Wp.Winds[$index].Gusting = $(if ($Val) { 1 } else { 0 }) }
            }
        }
        1 {
            if ($index -ge $Wp.Clouds.Count) { Send-UData -U $U -S "Invalid index`r`n"; return }
            switch ($y) {
                0 { $Wp.Clouds[$index].Floor = $Val }
                1 { $Wp.Clouds[$index].Ceiling = $Val }
                2 { $Wp.Clouds[$index].Coverage = $Val }
                3 { $Wp.Clouds[$index].Turbulence = $Val }
                4 { $Wp.Clouds[$index].Icing = $(if ($Val) { 1 } else { 0 }) }
            }
        }
        2 {
            if ($index -ge $Wp.Temps.Count) { Send-UData -U $U -S "Invalid index`r`n"; return }
            switch ($y) {
                0 { $Wp.Temps[$index].Ceiling = $Val }
                1 { $Wp.Temps[$index].Temp = $Val }
            }
        }
    }
}

function Invoke-SysKill {
    param($U, [string[]]$Data, [int]$Count)
    if ($Count -lt 2) { Write-SysUsage -U $U -Cmd 22 -S '<callsign> <reason>'; return }
    $c = Get-FsdClient -Ident $Data[0]
    if (-not $c) {
        Send-UData -U $U -S ("Could not find client '{0}'`r`n" -f $Data[0])
        return
    }
    $rest = @()
    for ($i = 1; $i -lt $Count; $i++) { $rest += $Data[$i] }
    Invoke-SendKill -Who $c -Reason ($rest -join ' ')
    Send-UData -U $U -S "Killed`r`n"
}

function Invoke-SysPos {
    param($U, [string[]]$Data, [int]$Count)
    if ($Count -lt 2) { Write-SysUsage -U $U -Cmd 23 -S '<lat> <lon'; return }
    $U.Lat = A2F $Data[0]
    $U.Lon = A2F $Data[1]
    Send-UData -U $U -S "Position set`r`n"
}

function Invoke-SysDump {
    param($U, [string[]]$Data, [int]$Count)
    if ($Count -lt 2) { Write-SysUsage -U $U -Cmd 24 -S '<fd> <file>'; return }
    $num = A2I $Data[0]
    foreach ($u in $Script:ServerIF.Users) {
        if ($u.Fd -eq $num) {
            try {
                [System.IO.File]::WriteAllText($Data[1], $u.OutBuf, $Script:FsdEnc)
                Send-UData -U $U -S "Done`r`n"
            } catch {
                Send-UData -U $U -S ("{0}: {1}`r`n" -f $Data[1], $_.Exception.Message)
            }
            return
        }
    }
    Send-UData -U $U -S "Can't find fd`r`n"
}

function Invoke-SysRefMetar {
    param($U)
    if ($Script:MetarMgr.Source -eq $Script:SOURCE_NETWORK) {
        Send-UData -U $U -S "Servers doesn't use a local METAR file.`r`n"
        return
    }
    if ($Script:MetarMgr.Downloading) {
        Send-UData -U $U -S "Already downloading latest METAR information.`r`n"
        return
    }
    Send-UData -U $U -S "Starting download of metar data.`r`n"
    Start-MetarDownload
}
