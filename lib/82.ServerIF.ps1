# ============================================================================
#  PowerShell-FSD - 82.ServerIF.ps1
#  Server-to-server interface: FSD network protocol (routing, feeds, sync,
#  multicasts)
# ============================================================================

function New-ServerInterface {
    param([int]$Port)
    $iface = New-FsdInterface -Kind 'server' -Port $Port -Code 'server' -Description 'server interface'
    $iface.PacketCount = 0
    $iface.LastSync    = 0
    $iface.VarMcHandled = Add-MgrVar -Name 'protocol.multicast.handled' -Type 'int'
    $iface.VarMcDrops   = Add-MgrVar -Name 'protocol.multicast.dropped' -Type 'int'
    $iface.VarUcHandled = Add-MgrVar -Name 'protocol.unicast.handled'   -Type 'int'
    $iface.VarUcOverrun = Add-MgrVar -Name 'protocol.unicast.overruns'  -Type 'int'
    $iface.VarFailed    = Add-MgrVar -Name 'protocol.errors.invalidcommand' -Type 'int'
    $iface.VarBounce    = Add-MgrVar -Name 'protocol.errors.bounce'     -Type 'int'
    $iface.VarShape     = Add-MgrVar -Name 'protocol.errors.shape'      -Type 'int'
    $iface.VarIntErr    = Add-MgrVar -Name 'protocol.errors.integer'    -Type 'int'
    $Script:ServerIF = $iface
    return $iface
}

function Invoke-ServerIFRun {
    param($Iface)
    $now = Get-MTime
    $busy = Invoke-IFRunCore -Iface $Iface
    if (($now - $Iface.LastSync) -gt $Script:SYNCTIMEOUT) { Invoke-SendSync }
    foreach ($u in $Iface.Users.ToArray()) {
        if (-not $u.ClientOk -and (($now - $u.StartupTime) -gt $Script:SERVERMAXTOOK)) {
            Kill-Conn -U $u -Reason $Script:KILL_INITTIMEOUT
        }
    }
    return $busy
}

# ---------------------------------------------------------------------------
# Connection setup / teardown
# ---------------------------------------------------------------------------

function Initialize-ServerConn {
    param($U)
    # feed(): bring the new neighbour up to date
    foreach ($s in $Script:RootServer.ToArray()) {
        Invoke-SendServerNotify -Dest '*' -Subject $s -ToWho $U
    }
    foreach ($c in $Script:RootClient.ToArray()) {
        Invoke-SendAddClient -Dest '*' -Who $c -Direction $U -Source $null -Feed 1
        if ($c.Plan) { Invoke-SendPlanS2S -Dest '*' -Who $c -Direction $U }
    }
    foreach ($cert in $Script:RootCert.ToArray()) {
        Invoke-SendCert -Dest '*' -Cmd $Script:CERT_ADD -Cert $cert -Direction $U
    }
    foreach ($wp in $Script:RootProfile.ToArray()) {
        Invoke-SendAddWp -Direction $U -Wp $wp
    }
}

function Remove-ServerConn {
    # ~servuser(): announce LINKDOWN for the servers that were routed via us
    param($U)
    $buf = ''
    foreach ($s in $Script:RootServer.ToArray()) {
        if ($s.Path -and [object]::ReferenceEquals($s.Path, $U)) {
            Set-ServerPath -Srv $s -Conn $null -Hops -1
            if ($buf) { $buf += ':' }
            $buf += $s.Ident
        }
    }
    if ($buf) {
        Invoke-SendLinkDown -Data $buf
        Write-Dolog -Level $Script:L_ALERT -Message 'link down'
    }
    Invoke-SendSync
}

# ---------------------------------------------------------------------------
# Packet assembly and routing (servinterface::sendpacket)
# ---------------------------------------------------------------------------

function Invoke-IncPacketCount {
    $Script:ServerIF.PacketCount++
    if ($Script:ServerIF.PacketCount -lt 0 -or $Script:ServerIF.PacketCount -gt 2000000000) {
        Invoke-SendReset
    }
}

function Invoke-S2SSend {
    # convenience: send using the current packet counter, then increment it
    param($Exclude, $Direction, [int]$CmdNum, [string]$To, [string]$From, [int]$Hc, [int]$Bi, [string]$Data)
    Invoke-S2SSendPacket -Exclude $Exclude -Direction $Direction -CmdNum $CmdNum `
        -To $To -From $From -Pc $Script:ServerIF.PacketCount -Hc $Hc -Bi $Bi -Data $Data
    Invoke-IncPacketCount
}

function Invoke-S2SAssemble {
    param([int]$CmdNum, [string]$To, [string]$From, [int]$Bi, [int]$Pc, [int]$Hc, [string]$Data)
    $b = if ($Bi) { 'B' } else { 'U' }
    return ('{0}:{1}:{2}:{3}{4}:{5}:{6}' -f $Script:CmdNames[$CmdNum], $To, $From, $b, $Pc, $Hc, $Data)
}

function Test-ServerOk {
    # SERVOK(): may this server link receive the packet?
    param($U, $Exclude, [int]$CmdNum)
    if ($Exclude -and [object]::ReferenceEquals($U, $Exclude)) { return $false }
    if ($Script:SilentOk[$CmdNum]) { return $true }
    if (-not $U.ThisServer) { return $true }
    if (($U.ThisServer.Flags -band $Script:SERVER_SILENT) -eq 0) { return $true }
    return $false
}

function Invoke-S2SBroadcast {
    param($Exclude, [int]$CmdNum, [int]$SlCheck, [string]$Buf)
    foreach ($u in $Script:ServerIF.Users.ToArray()) {
        if (Test-ServerOk -U $u -Exclude $Exclude -CmdNum $CmdNum) {
            Send-UsL -U $u -S ($Buf + "`r`n") -Check $SlCheck
        }
    }
}

function Invoke-S2SSendPacket {
    param($Exclude, $Direction, [int]$CmdNum, [string]$To, [string]$From,
          [int]$Pc, [int]$Hc, [int]$Bi, [string]$Data)
    $slcheck = ($CmdNum -eq $Script:CMD_PD -or $CmdNum -eq $Script:CMD_AD)
    $Hc++
    $buf = Invoke-S2SAssemble -CmdNum $CmdNum -To $To -From $From -Bi $Bi -Pc $Pc -Hc $Hc -Data $Data

    if ($Direction) {
        Send-UsL -U $Direction -S ($buf + "`n") -Check $slcheck
        return
    }

    $c0 = if ($To.Length -gt 0) { $To[0] } else { ' ' }
    switch ($c0) {
        { $_ -eq '@' -or $_ -eq '*' } {
            if (-not $Bi) {
                $buf = Invoke-S2SAssemble -CmdNum $CmdNum -To $To -From $From -Bi 1 -Pc $Pc -Hc $Hc -Data $Data
            }
            Invoke-S2SBroadcast -Exclude $Exclude -CmdNum $CmdNum -SlCheck $slcheck -Buf $buf
        }
        '%' {
            $needle = if ($To.Length -gt 1) { $To.Substring(1) } else { '' }
            $target = $null
            foreach ($tc in $Script:RootClient) {
                if (Test-StrIEqual $tc.Callsign $needle) { $target = $tc; break }
            }
            if ($target) {
                $srv = $target.Location
                if (-not [object]::ReferenceEquals($srv, $Script:MyServer)) {
                    if ($srv.Path) {
                        Send-UsL -U $srv.Path -S ($buf + "`r`n") -Check $slcheck
                    } else {
                        if (-not $Bi) {
                            $buf = Invoke-S2SAssemble -CmdNum $CmdNum -To $To -From $From -Bi 1 -Pc $Pc -Hc $Hc -Data $Data
                        }
                        Invoke-S2SBroadcast -Exclude $Exclude -CmdNum $CmdNum -SlCheck $slcheck -Buf $buf
                    }
                }
            }
        }
        default {
            $srv = Get-FsdServer -Ident $To
            if ($srv) {
                if ($srv.Path) {
                    Send-UsL -U $srv.Path -S ($buf + "`r`n") -Check $slcheck
                } else {
                    if (-not $Bi) {
                        $buf = Invoke-S2SAssemble -CmdNum $CmdNum -To $To -From $From -Bi 1 -Pc $Pc -Hc $Hc -Data $Data
                    }
                    Invoke-S2SBroadcast -Exclude $Exclude -CmdNum $CmdNum -SlCheck $slcheck -Buf $buf
                }
            }
        }
    }
}

# ---------------------------------------------------------------------------
# High level senders
# ---------------------------------------------------------------------------

function Invoke-SendSync {
    Invoke-S2SSend -Exclude $null -Direction $null -CmdNum $Script:CMD_SYNC `
        -To '*' -From $Script:MyServer.Ident -Hc 0 -Bi 0 -Data ''
    $Script:ServerIF.LastSync = Get-MTime
    Invoke-IncPacketCount
}

function Invoke-SendServerNotify {
    param([string]$Dest, $Subject, $ToWho)
    $first = if ([object]::ReferenceEquals($Subject, $Script:MyServer)) { 0 } else { 1 }
    $buf = '{0}:{1}:{2}:{3}:{4}:{5}:{6}:{7}' -f `
        $first, $Subject.Ident, $Subject.Name, $Subject.Email, $Subject.Hostname,
        $Subject.Version, $Subject.Flags, $Subject.Location
    Invoke-S2SSend -Exclude $null -Direction $ToWho -CmdNum $Script:CMD_NOTIFY `
        -To $Dest -From $Script:MyServer.Ident -Hc 0 -Bi 1 -Data $buf
}

function Invoke-SendReqMetar {
    param([string]$Client, [string]$Metar, [int]$Fd, [int]$Parsed, $Dest)
    $buf = '{0}:{1}:{2}:{3}' -f $Client, $Metar, $Parsed, $Fd
    Invoke-S2SSend -Exclude $null -Direction $null -CmdNum $Script:CMD_REQMETAR `
        -To $Dest.Ident -From $Script:MyServer.Ident -Hc 0 -Bi 0 -Data $buf
}

function Invoke-SendLinkDown {
    param([string]$Data)
    Invoke-S2SSend -Exclude $null -Direction $null -CmdNum $Script:CMD_LINKDOWN `
        -To '*' -From $Script:MyServer.Ident -Hc 0 -Bi 1 -Data $Data
}

function Invoke-SendPong {
    param([string]$Dest, [string]$Data)
    Invoke-S2SSend -Exclude $null -Direction $null -CmdNum $Script:CMD_PONG `
        -To $Dest -From $Script:MyServer.Ident -Hc 0 -Bi 0 -Data $Data
}

function Invoke-SendPing {
    param([string]$Dest, [string]$Data)
    Invoke-S2SSend -Exclude $null -Direction $null -CmdNum $Script:CMD_PING `
        -To $Dest -From $Script:MyServer.Ident -Hc 0 -Bi 0 -Data $Data
}

function Invoke-SendAddClient {
    param([string]$Dest, $Who, $Direction, $Source, [int]$Feed)
    $buf = '{0}:{1}:{2}:{3}:{4}:{5}:{6}:{7}' -f `
        $Who.Cid, $Who.Location.Ident, $Who.Callsign, $Who.Type, $Who.Rating,
        $Who.Protocol, $Who.RealName, $Who.SimType
    Invoke-S2SSend -Exclude $null -Direction $Direction -CmdNum $Script:CMD_ADDCLIENT `
        -To $Dest -From $Script:MyServer.Ident -Hc 0 -Bi 0 -Data $buf
    if (-not $Feed) {
        if ($Who.Type -eq $Script:CLIENT_ATC)   { Invoke-SendAA -Who $Who -Ex $Source }
        if ($Who.Type -eq $Script:CLIENT_PILOT) { Invoke-SendAP -Who $Who -Ex $Source }
    }
}

function Invoke-SendRmClient {
    param($Direction, [string]$Dest, $Who, $Ex)
    $buf = $Who.Callsign
    Invoke-S2SSend -Exclude $null -Direction $Direction -CmdNum $Script:CMD_RMCLIENT `
        -To $Dest -From $Script:MyServer.Ident -Hc 0 -Bi 0 -Data $buf
    if ($Dest -ceq '*') {
        if ($Who.Type -eq $Script:CLIENT_ATC)   { Invoke-SendDA -Who $Who -Ex $Ex }
        else { Invoke-SendDP -Who $Who -Ex $Ex }
    }
}

function Invoke-SendPilotData {
    param($Who, $Ex)
    $data = '{0}:{1}:{2}:{3}:{4}:{5}:{6}:{7}:{8}:{9}' -f `
        $Who.IdentFlag, $Who.Callsign, $Who.Transponder, $Who.Rating,
        (F5 $Who.Lat), (F5 $Who.Lon), $Who.Altitude, $Who.GroundSpeed, $Who.Pbh, $Who.Flags
    Invoke-S2SSend -Exclude $null -Direction $null -CmdNum $Script:CMD_PD `
        -To '*' -From $Script:MyServer.Ident -Hc 0 -Bi 0 -Data $data
    Invoke-SendPilotPos -Who $Who -Ex $Ex
}

function Invoke-SendAtcData {
    param($Who, $Ex)
    $data = '{0}:{1}:{2}:{3}:{4}:{5}:{6}:{7}' -f `
        $Who.Callsign, $Who.Frequency, $Who.FacilityType, $Who.VisualRange, $Who.Rating,
        (F5 $Who.Lat), (F5 $Who.Lon), $Who.Altitude
    Invoke-S2SSend -Exclude $null -Direction $null -CmdNum $Script:CMD_AD `
        -To '*' -From $Script:MyServer.Ident -Hc 0 -Bi 0 -Data $data
    Invoke-SendAtcPos -Who $Who -Ex $Ex
}

function Invoke-SendCert {
    param([string]$Dest, [int]$Cmd, $Cert, $Direction)
    $data = '{0}:{1}:{2}:{3}:{4}:{5}' -f `
        $Cmd, $Cert.Cid, $Cert.Password, $Cert.Level, $Cert.Creation, $Cert.Origin
    Invoke-S2SSend -Exclude $null -Direction $Direction -CmdNum $Script:CMD_CERT `
        -To $Dest -From $Script:MyServer.Ident -Hc 0 -Bi 0 -Data $data
}

function Invoke-SendReset {
    Invoke-S2SSendPacket -Exclude $null -Direction $null -CmdNum $Script:CMD_RESET `
        -To '*' -From $Script:MyServer.Ident -Pc $Script:ServerIF.PacketCount -Hc 0 -Bi 0 -Data ''
    $Script:ServerIF.PacketCount = 0
}

function Invoke-SendMulticast {
    param($Source, [string]$Dest, [string]$S, [int]$Cmd, [bool]$MultiOk, $Ex)
    $destination = $null
    $sourcestr = if ($Source) { $Source.Callsign } else { 'server' }
    if ($Source -and (Test-StrIEqual $Dest 'server')) {
        if ($Cmd -eq $Script:CL_PING) {
            Invoke-SendGeneric -To $Source.Callsign -Dest $Source -Ex $null `
                -Source $null -From 'server' -S $S -Cmd $Script:CL_PONG
        }
        return $true
    }
    $servdest = ''
    $c0 = if ($Dest.Length -gt 0) { $Dest[0] } else { ' ' }
    if ($c0 -eq '@' -or $c0 -eq '*') {
        if (-not $MultiOk) { return $false }
        $servdest = $Dest
    } else {
        $servdest = '%' + $Dest
        $destination = Get-FsdClient -Ident $Dest
        if (-not $destination) { return $false }
    }
    $data = '{0}:{1}:{2}' -f $Cmd, $sourcestr, $S
    Invoke-S2SSend -Exclude $null -Direction $null -CmdNum $Script:CMD_MULTIC `
        -To $servdest -From $Script:MyServer.Ident -Hc 0 -Bi 0 -Data $data
    Invoke-SendGeneric -To $Dest -Dest $destination -Ex $Ex -Source $Source -From $sourcestr -S $S -Cmd $Cmd
    return $true
}

function Invoke-SendPlanS2S {
    param([string]$Dest, $Who, $Direction)
    if (-not $Who.Plan) { return }
    $plan = $Who.Plan
    $buf = '{0}:{1}:{2}:{3}:{4}:{5}:{6}:{7}:{8}:{9}:{10}:{11}:{12}:{13}:{14}:{15}:{16}' -f `
        $Who.Callsign, $plan.Revision, $plan.Type, $plan.Aircraft,
        $plan.TasCruise, $plan.DepAirport, $plan.DepTime, $plan.ActDepTime,
        $plan.Alt, $plan.DestAirport, $plan.HrsEnroute, $plan.MinEnroute,
        $plan.HrsFuel, $plan.MinFuel, $plan.AltAirport, $plan.Remarks, $plan.Route
    Invoke-S2SSend -Exclude $null -Direction $Direction -CmdNum $Script:CMD_PLAN `
        -To $Dest -From $Script:MyServer.Ident -Hc 0 -Bi 0 -Data $buf
    Invoke-SendPlanLocal -Dest $null -Who $Who -Range 400
}

function Invoke-SendWeather {
    param([string]$Dest, [int]$Fd, $Wp)
    if (Test-StrIEqual $Dest $Script:MyServer.Ident) {
        Invoke-SysReceiveWeather -Fd $Fd -Wp $Wp
        return
    }
    if ($Dest.Length -gt 0 -and $Dest[0] -eq '%') {
        $c = Get-FsdClient -Ident ($Dest.Substring(1))
        if (-not $c) { return }
        if ([object]::ReferenceEquals($c.Location, $Script:MyServer)) {
            Invoke-SendWeatherLocal -Who $c -Wp $Wp
            return
        }
    }
    $weather = Export-WProfileString -Wp $Wp
    $data = '{0}:{1}:{2}' -f $Wp.Name, $Fd, $weather
    Invoke-S2SSend -Exclude $null -Direction $null -CmdNum $Script:CMD_WEATHER `
        -To $Dest -From $Script:MyServer.Ident -Hc 0 -Bi 0 -Data $data
}

function Invoke-SendMetar {
    param([string]$Dest, [int]$Fd, [string]$Station, [string]$Data)
    if (Test-StrIEqual $Dest $Script:MyServer.Ident) {
        Invoke-SysReceiveMetar -Fd $Fd -Station $Station -Data $Data
        return
    }
    if ($Dest.Length -gt 0 -and $Dest[0] -eq '%') {
        $c = Get-FsdClient -Ident ($Dest.Substring(1))
        if (-not $c) { return }
        if ([object]::ReferenceEquals($c.Location, $Script:MyServer)) {
            Invoke-SendMetarLocal -Who $c -Data $Data
            return
        }
    }
    $buf = '{0}:{1}:{2}' -f $Station, $Fd, $Data
    Invoke-S2SSend -Exclude $null -Direction $null -CmdNum $Script:CMD_METAR `
        -To $Dest -From $Script:MyServer.Ident -Hc 0 -Bi 0 -Data $buf
}

function Invoke-SendNowx {
    param([string]$Dest, [int]$Fd, [string]$Station)
    if (Test-StrIEqual $Dest $Script:MyServer.Ident) {
        Invoke-SysReceiveNowx -Fd $Fd -Station $Station
        return
    }
    if ($Dest.Length -gt 0 -and $Dest[0] -eq '%') {
        $c = Get-FsdClient -Ident ($Dest.Substring(1))
        if (-not $c) { return }
        if ([object]::ReferenceEquals($c.Location, $Script:MyServer)) {
            Invoke-SendNowxLocal -Who $c -Station $Station
            return
        }
    }
    $buf = '{0}:{1}' -f $Station, $Fd
    Invoke-S2SSend -Exclude $null -Direction $null -CmdNum $Script:CMD_NOWX `
        -To $Dest -From $Script:MyServer.Ident -Hc 0 -Bi 0 -Data $buf
}

function Invoke-SendAddWp {
    param($Direction, $Wp)
    $weather = Export-WProfileString -Wp $Wp
    $origin = if ($Wp.Origin) { $Wp.Origin } else { '' }
    $buf = '{0}:{1}:{2}:{3}' -f $Wp.Name, $Wp.Version, $origin, $weather
    Invoke-S2SSend -Exclude $null -Direction $Direction -CmdNum $Script:CMD_ADDWPROF `
        -To '*' -From $Script:MyServer.Ident -Hc 0 -Bi 0 -Data $buf
}

function Invoke-SendDelWp {
    param($Wp)
    Invoke-S2SSend -Exclude $null -Direction $null -CmdNum $Script:CMD_DELWPROF `
        -To '*' -From $Script:MyServer.Ident -Hc 0 -Bi 0 -Data $Wp.Name
}

function Invoke-SendKill {
    param($Who, [string]$Reason)
    if ([object]::ReferenceEquals($Who.Location, $Script:MyServer)) {
        Invoke-HandleKillLocal -Who $Who -Reason $Reason
        return
    }
    $data = '{0}:{1}' -f $Who.Callsign, $Reason
    Invoke-S2SSend -Exclude $null -Direction $null -CmdNum $Script:CMD_KILL `
        -To $Who.Location.Ident -From $Script:MyServer.Ident -Hc 0 -Bi 1 -Data $data
}

function Invoke-ClientDropped {
    param($Who)
    foreach ($u in $Script:ServerIF.Users) {
        if ($u.ThisServer -and ($u.ThisServer.Flags -band $Script:SERVER_SILENT)) {
            Invoke-SendRmClient -Direction $u -Dest $u.ThisServer.Name -Who $Who -Ex $null
        }
    }
}

# ---------------------------------------------------------------------------
# Incoming packet handling (servuser.cpp)
# ---------------------------------------------------------------------------

function Invoke-ServerParse {
    param($U, [string]$Line)
    if ($Line.Length -gt 0 -and $Line[0] -eq '#') { return }
    $U.LastActive = Get-MTime
    $U.LastPing = Get-MTime
    if ($Line.Length -eq 0 -or $Line[0] -ne '\') {
        Invoke-ServerDoParse -U $U -Line $Line
        return
    }
    switch ($Line[1]) {
        'q' { Kill-Conn -U $U -Reason $Script:KILL_COMMAND }
        'l' {
            $filter = $Line.Substring(2).Trim()
            foreach ($l in (Get-MgrListing -Filter $filter)) {
                Send-UData -U $U -S ($l + "`r`n")
            }
        }
        default { Send-UData -U $U -S "Syntax error, type \h for help`r`n" }
    }
}

function Test-NeedLocalDelivery {
    param([string]$Dest)
    if ($Dest.Length -eq 0) { return $false }
    if ($Dest[0] -eq '*') { return $true }
    if ($Dest[0] -eq '@') { return $true }
    if ($Dest[0] -eq '%') {
        $needle = $Dest.Substring(1)
        foreach ($tc in $Script:RootClient) {
            if ((Test-StrIEqual $tc.Callsign $needle) -and [object]::ReferenceEquals($tc.Location, $Script:MyServer)) {
                return $true
            }
        }
        return $false
    }
    if (Test-StrIEqual $Dest $Script:MyServer.Ident) { return $true }
    return $false
}

function Invoke-ServerDoParse {
    param($U, [string]$Line)
    $array = Break-Packet -S $Line -Max 100
    $count = $array.Count
    if ($count -lt 6) {
        Inc-MgrVar -Num $Script:ServerIF.VarShape
        Send-UData -U $U -S "# Missing basic packet fields, syntax error`r`n"
        return
    }

    $pcField = if ($array[3].Length -gt 1) { $array[3].Substring(1) } else { '' }
    $pc = Try-A2I $pcField
    $hops = Try-A2I $array[4]
    $from = $array[2]
    $to = $array[1]
    $bi = ($array[3].Length -gt 0 -and $array[3][0] -eq 'B')
    if ($null -eq $pc -or $null -eq $hops) {
        Inc-MgrVar -Num $Script:ServerIF.VarIntErr
        return
    }
    if ($hops -gt $Script:MAXHOPS) {
        Inc-MgrVar -Num $Script:ServerIF.VarBounce
        return
    }

    $origin = Get-FsdServer -Ident $from
    if ($origin) {
        Set-ServerAlive -Srv $origin
        if ([object]::ReferenceEquals($origin, $Script:MyServer)) { return }
        if ($hops -lt $origin.Hops -or $origin.Hops -eq -1) {
            Set-ServerPath -Srv $origin -Conn $U -Hops $hops
        }
        if (($pc -le $origin.PCount) -or ($pc -gt ($origin.PCount + $Script:MAXSPACE))) {
            if (($pc -eq $origin.PCount) -or ($bi -and $origin.PacketDrops -lt 100) -or
                ($bi -and $pc -gt ($origin.PCount + $Script:MAXSPACE))) {
                Inc-MgrVar -Num $Script:ServerIF.VarMcDrops
                $origin.PacketDrops++
                return
            }
            Inc-MgrVar -Num $Script:ServerIF.VarUcOverrun
        }
        if ($origin.PacketDrops -ge 100) { $origin.PCount = $pc }
        if ($pc -gt $origin.PCount) { $origin.PCount = $pc }
        if ($bi) {
            Set-ServerPath -Srv $origin -Conn $U -Hops $hops
            $origin.PacketDrops = 0
        }
    }

    $idx = -1
    for ($i = 0; $i -lt $Script:CmdNames.Count; $i++) {
        if (Test-StrIEqual $Script:CmdNames[$i] $array[0]) { $idx = $i; break }
    }
    if ($idx -lt 0) {
        Send-UData -U $U -S "# Unknown command, Syntax error`r`n"
        Inc-MgrVar -Num $Script:ServerIF.VarFailed
        return
    }

    $U.ClientOk = $true
    if (-not $origin -and $idx -ne $Script:CMD_NOTIFY) { return }

    $rest = @()
    for ($i = 5; $i -lt $count; $i++) { $rest += $array[$i] }

    if (-not (Test-NeedLocalDelivery -Dest $to)) {
        if (-not (Test-StrIEqual $to $Script:MyServer.Ident)) {
            Invoke-S2SSendPacket -Exclude $U -Direction $null -CmdNum $idx `
                -To $to -From $from -Pc $pc -Hc $hops -Bi $bi -Data ($rest -join ':')
        }
        return
    }

    $cmdData = @()
    for ($i = 1; $i -lt $count; $i++) { $cmdData += $array[$i] }
    $needforward = Invoke-ServerRuncmd -Num $idx -Data $cmdData -Count $cmdData.Count -U $U

    if ((-not (Test-StrIEqual $to $Script:MyServer.Ident)) -and $needforward) {
        Invoke-S2SSendPacket -Exclude $U -Direction $null -CmdNum $idx `
            -To $to -From $from -Pc $pc -Hc $hops -Bi $bi -Data ($rest -join ':')
    }
    if ($bi) { Inc-MgrVar -Num $Script:ServerIF.VarMcHandled }
    else     { Inc-MgrVar -Num $Script:ServerIF.VarUcHandled }
}

function Invoke-ServerRuncmd {
    # returns $true when the packet needs to be forwarded to other servers
    param([int]$Num, [string[]]$Data, [int]$Count, $U)
    switch ($Num) {
        $Script:CMD_NOTIFY    { Invoke-S2SExecNotify -U $U -Data $Data -Count $Count; return $true }
        $Script:CMD_PING      { Invoke-S2SExecPing -U $U -Data $Data -Count $Count; return $true }
        $Script:CMD_LINKDOWN  { Invoke-S2SExecLinkDown -U $U -Data $Data -Count $Count; return $true }
        $Script:CMD_PONG      { Invoke-S2SExecPong -U $U -Data $Data -Count $Count; return $true }
        $Script:CMD_SYNC      { return $true }
        $Script:CMD_ADDCLIENT { return (Invoke-S2SExecAddClient -U $U -Data $Data -Count $Count) }
        $Script:CMD_RMCLIENT  { Invoke-S2SExecRmClient -U $U -Data $Data -Count $Count; return $true }
        $Script:CMD_PD        { Invoke-S2SExecPd -U $U -Data $Data -Count $Count; return $true }
        $Script:CMD_AD        { Invoke-S2SExecAd -U $U -Data $Data -Count $Count; return $true }
        $Script:CMD_CERT      { return (Invoke-S2SExecCert -U $U -Data $Data -Count $Count) }
        $Script:CMD_MULTIC    { Invoke-S2SExecMultic -U $U -Data $Data -Count $Count; return $true }
        $Script:CMD_PLAN      { return (Invoke-S2SExecPlan -U $U -Data $Data -Count $Count) }
        $Script:CMD_REQMETAR  { Invoke-S2SExecReqMetar -U $U -Data $Data -Count $Count; return $true }
        $Script:CMD_WEATHER   { Invoke-S2SExecWeather -U $U -Data $Data -Count $Count; return $true }
        $Script:CMD_METAR     { Invoke-S2SExecMetar -U $U -Data $Data -Count $Count; return $true }
        $Script:CMD_NOWX      { Invoke-S2SExecNowx -U $U -Data $Data -Count $Count; return $true }
        $Script:CMD_ADDWPROF  { Invoke-S2SExecAddWp -U $U -Data $Data -Count $Count; return $true }
        $Script:CMD_DELWPROF  { Invoke-S2SExecDelWp -U $U -Data $Data -Count $Count; return $true }
        $Script:CMD_KILL      { Invoke-S2SExecKill -U $U -Data $Data -Count $Count; return $true }
        $Script:CMD_RESET     { Invoke-S2SExecReset -U $U -Data $Data -Count $Count; return $true }
    }
    return $true
}

function Invoke-S2SExecNotify {
    param($U, [string[]]$Data, [int]$Count)
    if ($Count -lt 11) { return }
    $feedflag = A2I $Data[4]
    $hops = A2I $Data[3]
    $s = Get-FsdServer -Ident $Data[5]
    if ($s -and [object]::ReferenceEquals($s, $Script:MyServer)) { return }
    $loc = if ($Count -eq 12) { $Data[11] } else { '' }
    if (-not $s) {
        $s = New-FsdServer -Ident $Data[5] -Name $Data[6] -Email $Data[7] `
            -Hostname $Data[8] -SVersion $Data[9] -Flags (A2I $Data[10]) -Location $loc
    } else {
        Set-FsdServerConfig -Srv $s -Name $Data[6] -Email $Data[7] `
            -Hostname $Data[8] -SVersion $Data[9] -Location $loc
    }
    if (-not $feedflag -and $hops -eq 1) { $U.ThisServer = $s }
    if ($feedflag -or ($s.Hops -gt -1 -and $hops -ge $s.Hops)) { return }
    Set-ServerPath -Srv $s -Conn $U -Hops $hops
}

function Invoke-S2SExecPing {
    param($U, [string[]]$Data, [int]$Count)
    $payload = @()
    for ($i = 4; $i -lt $Count; $i++) { $payload += $Data[$i] }
    Invoke-SendPong -Dest $Data[1] -Data ($payload -join ':')
}

function Invoke-S2SExecPong {
    param($U, [string[]]$Data, [int]$Count)
    if ($Count -lt 5) { return }
    $fd = A2I $Data[4]
    $source = Get-FsdServer -Ident $Data[1]
    if (-not $source) { return }
    Receive-ServerPong -Srv $source -Data $Data[4]
    if ($fd -ne -1) {
        Invoke-SysReceivePong -From $Data[1] -Data $Data[4] -Pc $Data[2] -Hops $Data[3]
    }
}

function Invoke-S2SExecLinkDown {
    param($U, [string[]]$Data, [int]$Count)
    for ($x = 4; $x -lt $Count; $x++) {
        $temp = Get-FsdServer -Ident $Data[$x]
        if (-not $temp) { continue }
        if ($temp.Path -and [object]::ReferenceEquals($temp.Path, $U)) {
            Set-ServerPath -Srv $temp -Conn $null -Hops -1
        }
    }
    Invoke-SendSync
}

function Invoke-S2SExecAddClient {
    param($U, [string[]]$Data, [int]$Count)
    if ($Count -lt 12) { return $true }
    $location = Get-FsdServer -Ident $Data[5]
    if (-not $location -or [object]::ReferenceEquals($location, $Script:MyServer)) { return $true }
    $type = A2I $Data[7]
    $c = Get-FsdClient -Ident $Data[6]
    if ($c) { return $false }
    $c = New-FsdClient -Cid $Data[4] -Location $location -Callsign $Data[6] -Type $type `
        -ReqRating (A2I $Data[8]) -Protocol $Data[9] -RealName $Data[10] -SimType (A2I $Data[11])
    if ($type -eq $Script:CLIENT_ATC)   { Invoke-SendAA -Who $c -Ex $null }
    if ($type -eq $Script:CLIENT_PILOT) { Invoke-SendAP -Who $c -Ex $null }
    return $true
}

function Invoke-S2SExecRmClient {
    param($U, [string[]]$Data, [int]$Count)
    if ($Count -lt 5) { return }
    $c = Get-FsdClient -Ident $Data[4]
    if ($c) {
        $type = $c.Type
        if ([object]::ReferenceEquals($c.Location, $Script:MyServer)) { return }
        if ($type -eq $Script:CLIENT_ATC)   { Invoke-SendDA -Who $c -Ex $null }
        if ($type -eq $Script:CLIENT_PILOT) { Invoke-SendDP -Who $c -Ex $null }
        Remove-FsdClient -Client $c
    }
}

function Invoke-S2SExecAd {
    param($U, [string[]]$Data, [int]$Count)
    if ($Count -lt 12) { return }
    $who = Get-FsdClient -Ident $Data[4]
    if (-not $who) { return }
    $rest = @()
    for ($i = 5; $i -lt $Count; $i++) { $rest += $Data[$i] }
    Update-ClientAtc -Client $who -A $rest
    Invoke-SendAtcPos -Who $who -Ex $null
}

function Invoke-S2SExecPd {
    param($U, [string[]]$Data, [int]$Count)
    if ($Count -lt 14) { return }
    $who = Get-FsdClient -Ident $Data[5]
    if (-not $who) { return }
    $rest = @()
    for ($i = 4; $i -lt $Count; $i++) { $rest += $Data[$i] }
    Update-ClientPilot -Client $who -A $rest
    Invoke-SendPilotPos -Who $who -Ex $null
}

function Invoke-S2SExecCert {
    param($U, [string[]]$Data, [int]$Count)
    if ($Count -lt 10) { return $false }
    $group = Get-ConfigGroup -Name 'hosts'
    $entry = if ($group) { Get-ConfigEntry -Group $group -Name 'certificates' } else { $null }
    $ok = if ($entry) { Test-ConfigInList -Entry $entry -Needle $Data[9] } else { $true }
    $level = A2I $Data[7]
    $c = Get-Cert -Cid $Data[5]
    $now = A2I $Data[8]
    switch (A2I $Data[4]) {
        $Script:CERT_ADD {
            if (-not $c) {
                if ($ok) { New-Certificate -Cid $Data[5] -Password $Data[6] -Level $level -Creation $now -Origin $Data[9] | Out-Null }
            } elseif ($now -gt $c.Creation) {
                if ($ok) { Set-CertificateConfig -Cert $c -Password $null -Level $level -Creation $now -Origin $Data[9] }
            } else { return $false }
        }
        $Script:CERT_DELETE {
            if ($c) {
                if ($ok) { Remove-Certificate -Cert $c }
            } else { return $false }
        }
        $Script:CERT_MODIFY {
            if ($c -and $now -gt $c.Creation) {
                if ($ok) { Set-CertificateConfig -Cert $c -Password $Data[6] -Level $level -Creation $now -Origin $Data[9] }
            } else { return $false }
        }
    }
    return $true
}

function Invoke-S2SExecMultic {
    param($U, [string[]]$Data, [int]$Count)
    if ($Count -lt 7) { return }
    $source = Get-FsdClient -Ident $Data[5]
    $cmd = A2I $Data[4]
    if ($cmd -gt $Script:CL_MAX) { return }
    $c = $null
    $dest = ''
    $t0 = $Data[0]
    if ($t0.Length -gt 0 -and ($t0[0] -eq '*' -or $t0[0] -eq '@')) {
        $dest = $t0
    } else {
        $c = $null
        if ($t0.Length -gt 1) { $c = Get-FsdClient -Ident ($t0.Substring(1)) }
        if (-not $c) { return }
        $dest = $t0.Substring(1)
    }
    $payload = @()
    for ($i = 6; $i -lt $Count; $i++) { $payload += $Data[$i] }
    Invoke-SendGeneric -To $dest -Dest $c -Ex $null -Source $source -From $Data[5] `
        -S ($payload -join ':') -Cmd $cmd
}

function Invoke-S2SExecPlan {
    param($U, [string[]]$Data, [int]$Count)
    if ($Count -lt 21) { return $false }
    $revision = A2I $Data[5]
    $who = Get-FsdClient -Ident $Data[4]
    if (-not $who) { return $true }
    if ($who.Plan -and $who.Plan.Revision -ge $revision) { return $false }
    $fields = @()
    for ($i = 6; $i -lt $Count; $i++) { $fields += $Data[$i] }
    Set-ClientPlan -Client $who -Fields $fields
    $who.Plan.Revision = $revision
    Invoke-SendPlanLocal -Dest $null -Who $who -Range 400
    return $true
}

function Invoke-S2SExecReqMetar {
    param($U, [string[]]$Data, [int]$Count)
    if ($Count -lt 8) { return }
    Invoke-RequestMetar -Client $Data[4] -Metar $Data[5] -Parsed (A2I $Data[6]) -Fd (A2I $Data[7]) | Out-Null
}

function Invoke-S2SExecWeather {
    param($U, [string[]]$Data, [int]$Count)
    if ($Count -lt 56) { return }
    $prof = New-WProfile -Name $Data[4] -Creation 0 -Origin $null
    $fd = A2I $Data[5]
    $fields = @()
    for ($i = 6; $i -lt $Count; $i++) { $fields += $Data[$i] }
    Import-WProfileArray -Wp $prof -A $fields
    if ($fd -eq -1) {
        $c = $null
        if ($Data[0].Length -gt 1) { $c = Get-FsdClient -Ident ($Data[0].Substring(1)) }
        if (-not $c) { return }
        Invoke-SendWeatherLocal -Who $c -Wp $prof
    } else {
        Invoke-SysReceiveWeather -Fd $fd -Wp $prof
    }
}

function Invoke-S2SExecMetar {
    param($U, [string[]]$Data, [int]$Count)
    if ($Count -lt 7) { return }
    $fd = A2I $Data[5]
    if ($fd -ne -1) {
        Invoke-SysReceiveMetar -Fd $fd -Station $Data[4] -Data $Data[6]
    } else {
        $c = $null
        if ($Data[0].Length -gt 1) { $c = Get-FsdClient -Ident ($Data[0].Substring(1)) }
        if (-not $c) { return }
        Invoke-SendMetarLocal -Who $c -Data $Data[6]
    }
}

function Invoke-S2SExecNowx {
    param($U, [string[]]$Data, [int]$Count)
    if ($Count -lt 6) { return }
    $fd = A2I $Data[5]
    if ($fd -eq -1) {
        $c = $null
        if ($Data[0].Length -gt 1) { $c = Get-FsdClient -Ident ($Data[0].Substring(1)) }
        if (-not $c) { return }
        Invoke-SendNowxLocal -Who $c -Station $Data[4]
    } else {
        Invoke-SysReceiveNowx -Fd $fd -Station $Data[4]
    }
}

function Invoke-S2SExecAddWp {
    param($U, [string[]]$Data, [int]$Count)
    if ($Count -lt 57 -or $Script:MetarMgr.Source -eq $Script:SOURCE_NETWORK) { return }
    $group = Get-ConfigGroup -Name 'hosts'
    $entry = if ($group) { Get-ConfigEntry -Group $group -Name 'weather' } else { $null }
    $ok = if ($entry) { Test-ConfigInList -Entry $entry -Needle $Data[6] } else { $true }
    if (-not $ok) { return }
    $version = A2I $Data[5]
    $prof = Get-WProfile -Name $Data[4]
    if ($prof -and $prof.Version -ge $version) { return }
    if ($prof) { Remove-WProfile -Wp $prof }
    $prof = New-WProfile -Name $Data[4] -Creation $version -Origin $Data[6]
    $fields = @()
    for ($i = 7; $i -lt $Count; $i++) { $fields += $Data[$i] }
    Import-WProfileArray -Wp $prof -A $fields
    Update-WProfileRawCode -Wp $prof
}

function Invoke-S2SExecDelWp {
    param($U, [string[]]$Data, [int]$Count)
    if ($Count -lt 5 -or $Script:MetarMgr.Source -eq $Script:SOURCE_NETWORK) { return }
    $group = Get-ConfigGroup -Name 'hosts'
    $entry = if ($group) { Get-ConfigEntry -Group $group -Name 'weather' } else { $null }
    $ok = if ($entry) { Test-ConfigInList -Entry $entry -Needle $Data[1] } else { $true }
    if (-not $ok) { return }
    $prof = Get-WProfile -Name $Data[4]
    if (-not $prof -or -not $prof.Active) { return }
    Remove-WProfile -Wp $prof
}

function Invoke-S2SExecKill {
    param($U, [string[]]$Data, [int]$Count)
    if ($Count -lt 6) { return }
    $c = Get-FsdClient -Ident $Data[4]
    if (-not $c) { return }
    Invoke-HandleKillLocal -Who $c -Reason $Data[5]
}

function Invoke-S2SExecReset {
    param($U, [string[]]$Data, [int]$Count)
    $s = Get-FsdServer -Ident $Data[1]
    if (-not $s) { return }
    $s.PCount = 0
}
