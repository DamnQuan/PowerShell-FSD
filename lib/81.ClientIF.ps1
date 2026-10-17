# ============================================================================
#  PowerShell-FSD - 81.ClientIF.ps1
#  Client (pilot/ATC) interface: connection handling and the client protocol
# ============================================================================

function New-ClientInterface {
    param([int]$Port)
    $iface = New-FsdInterface -Kind 'client' -Port $Port -Code 'client' -Description 'client interface'
    $iface.PrevWindDelta = Get-MTime
    $Script:ClientIF = $iface
    return $iface
}

function Invoke-ClientIFRun {
    $busy = Invoke-IFRunCore -Iface $Script:ClientIF
    if (((Get-MTime) - $Script:ClientIF.PrevWindDelta) -gt $Script:WINDDELTATIMEOUT) {
        $Script:ClientIF.PrevWindDelta = Get-MTime
        Invoke-SendWindDelta
    }
    return $busy
}

# ---------------------------------------------------------------------------
# Connection setup / teardown
# ---------------------------------------------------------------------------

function Initialize-ClientConn {
    # cluser ctor: enforce maxclients
    param($U)
    $gu = Get-ConfigGroup -Name 'system'
    $e = if ($gu) { Get-ConfigEntry -Group $gu -Name 'maxclients' } else { $null }
    $total = $Script:ClientIF.Users.Count
    if ($e -and ((A2I $e.Data) -le $total)) {
        Invoke-ShowError -U $U -Num $Script:ERR_SERVFULL -Env ''
        Kill-Conn -U $U -Reason $Script:KILL_COMMAND
    }
}

function Remove-ClientConn {
    # ~cluser(): unregister the client and tell the network
    param($U)
    if ($U.ThisClient) {
        Invoke-SendRmClient -Direction $null -Dest '*' -Who $U.ThisClient -Ex $U
        Remove-FsdClient -Client $U.ThisClient
    }
}

# ---------------------------------------------------------------------------
# Common helpers
# ---------------------------------------------------------------------------

function Invoke-ShowError {
    param($U, [int]$Num, [string]$Env)
    $cs = if ($U.ThisClient) { $U.ThisClient.Callsign } else { 'unknown' }
    Send-UData -U $U -S ('{0}server:{1}:{2}:{3}:{4}' -f `
        $Script:ClCmdNames[$Script:CL_ERROR], $cs, $Num.ToString('000', $Script:Inv), $Env, $Script:ErrStr[$Num])
    return $Num
}

# callsignok(): 0 on success or error code
function Test-CallsignOk {
    param([string]$Name)
    if ($Name.Length -lt 2 -or $Name.Length -gt $Script:CALLSIGNBYTES) { return $Script:ERR_CSINVALID }
    if (Test-ContainsAny -S $Name -Chars ('!@#$%*:& ' + "`t")) { return $Script:ERR_CSINVALID }
    foreach ($c in $Script:RootClient) {
        if (Test-StrIEqual $c.Callsign $Name) { return $Script:ERR_CSINUSE }
    }
    return $Script:ERR_OK
}

function Test-CheckSource {
    param($U, [string]$From)
    if (-not (Test-StrIEqual $From $U.ThisClient.Callsign)) {
        Invoke-ShowError -U $U -Num $Script:ERR_SRCINVALID -Env $From | Out-Null
        return $false
    }
    return $true
}

function Get-CommIndex {
    param([string]$Cmd)
    for ($i = 0; $i -lt $Script:ClCmdNames.Count; $i++) {
        if ($Cmd.StartsWith($Script:ClCmdNames[$i])) { return $i }
    }
    return -1
}

# checklogin(): returns the granted level, -1 invalid cid/pwd, -2 empty cid
function Invoke-CheckLogin {
    param([string]$Id, [string]$Pwd, [int]$Req, $U)
    if ($Id -eq '') { return -2 }
    $r = Test-MaxLevel -Id $Id -Pwd $Pwd
    if (-not $r.Ok) {
        Invoke-ShowError -U $U -Num $Script:ERR_CIDINVALID -Env $Id | Out-Null
        return -1
    }
    if ($Req -gt $r.Max) { return $r.Max }
    return $Req
}

function Invoke-ReadMotd {
    param($U)
    $who = $U.ThisClient
    Invoke-SendGeneric -To $who.Callsign -Dest $who -Ex $null -Source $null -From 'server' -S $Script:PRODUCT -Cmd $Script:CL_MESSAGE
    $path = Join-Path $Script:FsdDir $Script:PATH_FSD_MOTD
    if (-not (Test-Path -LiteralPath $path)) { return }
    foreach ($line in [System.IO.File]::ReadAllLines($path, $Script:FsdEnc)) {
        Invoke-SendGeneric -To $who.Callsign -Dest $who -Ex $null -Source $null -From 'server' -S $line -Cmd $Script:CL_MESSAGE
    }
}

# ---------------------------------------------------------------------------
# Client command handlers (cluser.cpp)
# ---------------------------------------------------------------------------

function Invoke-ClientParse {
    param($U, [string]$Line)
    # setactive()
    $U.LastActive = Get-MTime
    $U.LastPing = Get-MTime
    Invoke-ClientDoParse -U $U -Line $Line
}

function Invoke-ClientDoParse {
    param($U, [string]$Line)
    $cmdLen = [Math]::Min(3, $Line.Length)
    $cmd = $Line.Substring(0, $cmdLen)
    $index = Get-CommIndex -Cmd $cmd
    if ($index -lt 0) {
        Invoke-ShowError -U $U -Num $Script:ERR_SYNTAX -Env '' | Out-Null
        return
    }
    if (-not $U.ThisClient -and $index -ne $Script:CL_ADDATC -and $index -ne $Script:CL_ADDPILOT) { return }

    $name = $Script:ClCmdNames[$index]
    $rest = ''
    if ($Line.Length -gt $name.Length) { $rest = $Line.Substring($name.Length) }
    $array = Break-Packet -S $rest -Max 100
    $count = $array.Count

    switch ($index) {
        $Script:CL_ADDATC     { Invoke-ExecAA -U $U -S $array -Count $count }
        $Script:CL_ADDPILOT   { Invoke-ExecAP -U $U -S $array -Count $count }
        $Script:CL_PLAN       { Invoke-ExecFP -U $U -S $array -Count $count }
        $Script:CL_RMATC      { Invoke-ExecD -U $U -S $array -Count $count }
        $Script:CL_RMPILOT    { Invoke-ExecD -U $U -S $array -Count $count }
        $Script:CL_PILOTPOS   { Invoke-ExecPilotPos -U $U -S $array -Count $count }
        $Script:CL_ATCPOS     { Invoke-ExecAtcPos -U $U -S $array -Count $count }
        $Script:CL_PONG       { Invoke-ExecMulticast -U $U -S $array -Count $count -Cmd $index -NArgs 0 -MultiOk $true }
        $Script:CL_PING       { Invoke-ExecMulticast -U $U -S $array -Count $count -Cmd $index -NArgs 0 -MultiOk $true }
        $Script:CL_MESSAGE    { Invoke-ExecMulticast -U $U -S $array -Count $count -Cmd $index -NArgs 1 -MultiOk $true }
        $Script:CL_REQHANDOFF { Invoke-ExecMulticast -U $U -S $array -Count $count -Cmd $index -NArgs 1 -MultiOk $false }
        $Script:CL_ACHANDOFF  { Invoke-ExecMulticast -U $U -S $array -Count $count -Cmd $index -NArgs 1 -MultiOk $false }
        $Script:CL_SB         { Invoke-ExecMulticast -U $U -S $array -Count $count -Cmd $index -NArgs 0 -MultiOk $false }
        $Script:CL_PC         { Invoke-ExecMulticast -U $U -S $array -Count $count -Cmd $index -NArgs 0 -MultiOk $false }
        $Script:CL_REQWEATHER { Invoke-ExecWeather -U $U -S $array -Count $count }
        $Script:CL_WEATHER    { Invoke-ExecWeather -U $U -S $array -Count $count }
        $Script:CL_REQCOM     { Invoke-ExecMulticast -U $U -S $array -Count $count -Cmd $index -NArgs 0 -MultiOk $false }
        $Script:CL_REPCOM     { Invoke-ExecMulticast -U $U -S $array -Count $count -Cmd $index -NArgs 1 -MultiOk $false }
        $Script:CL_REQACARS   { Invoke-ExecAcars -U $U -S $array -Count $count }
        $Script:CL_CR         { Invoke-ExecMulticast -U $U -S $array -Count $count -Cmd $index -NArgs 2 -MultiOk $false }
        $Script:CL_CQ         { Invoke-ExecCQ -U $U -S $array -Count $count }
        $Script:CL_KILL       { Invoke-ExecClientKill -U $U -S $array -Count $count }
        default               { Invoke-ShowError -U $U -Num $Script:ERR_SYNTAX -Env '' | Out-Null }
    }
}

function Invoke-ExecAA {
    # #AA callsign:server:realname:cid:pwd:rating:protocol
    param($U, [string[]]$S, [int]$Count)
    if ($U.ThisClient) { Invoke-ShowError -U $U -Num $Script:ERR_REGISTERED -Env '' | Out-Null; return }
    if ($Count -lt 7)  { Invoke-ShowError -U $U -Num $Script:ERR_SYNTAX -Env '' | Out-Null; return }
    $err = Test-CallsignOk -Name $S[0]
    if ($err) {
        Invoke-ShowError -U $U -Num $err -Env '' | Out-Null
        Kill-Conn -U $U -Reason $Script:KILL_COMMAND
        return
    }
    if ((A2I $S[6]) -ne $Script:NEEDREVISION) {
        Invoke-ShowError -U $U -Num $Script:ERR_REVISION -Env '' | Out-Null
        Kill-Conn -U $U -Reason $Script:KILL_PROTOCOL
        return
    }
    $req = A2I $S[5]
    if ($req -lt 0) { $req = 0 }
    $level = Invoke-CheckLogin -Id $S[3] -Pwd $S[4] -Req $req -U $U
    if ($level -eq 0) {
        Invoke-ShowError -U $U -Num $Script:ERR_CSSUSPEND -Env '' | Out-Null
        Kill-Conn -U $U -Reason $Script:KILL_COMMAND
        return
    }
    elseif ($level -eq -1) {
        Kill-Conn -U $U -Reason $Script:KILL_COMMAND
        return
    }
    elseif ($level -eq -2) { $level = 1 }
    if ($level -lt $req) {
        Invoke-ShowError -U $U -Num $Script:ERR_LEVEL -Env $S[5] | Out-Null
        Kill-Conn -U $U -Reason $Script:KILL_COMMAND
        return
    }
    $U.ThisClient = New-FsdClient -Cid $S[3] -Location $Script:MyServer -Callsign $S[0] `
        -Type $Script:CLIENT_ATC -ReqRating $level -Protocol $S[6] -RealName $S[2] -SimType -1
    Invoke-SendAddClient -Dest '*' -Who $U.ThisClient -Direction $null -Source $U -Feed 0
    Invoke-ReadMotd -U $U
}

function Invoke-ExecAP {
    # #AP callsign:server:cid:pwd:rating:protocol:simtype:realname
    param($U, [string[]]$S, [int]$Count)
    if ($U.ThisClient) { Invoke-ShowError -U $U -Num $Script:ERR_REGISTERED -Env '' | Out-Null; return }
    if ($Count -lt 8)  { Invoke-ShowError -U $U -Num $Script:ERR_SYNTAX -Env '' | Out-Null; return }
    $err = Test-CallsignOk -Name $S[0]
    if ($err) {
        Invoke-ShowError -U $U -Num $err -Env '' | Out-Null
        Kill-Conn -U $U -Reason $Script:KILL_COMMAND
        return
    }
    if ((A2I $S[5]) -ne $Script:NEEDREVISION) {
        Invoke-ShowError -U $U -Num $Script:ERR_REVISION -Env '' | Out-Null
        Kill-Conn -U $U -Reason $Script:KILL_PROTOCOL
        return
    }
    $req = A2I $S[4]
    if ($req -lt 0) { $req = 0 }
    $level = Invoke-CheckLogin -Id $S[2] -Pwd $S[3] -Req $req -U $U
    if ($level -lt 0) {
        Kill-Conn -U $U -Reason $Script:KILL_COMMAND
        return
    }
    elseif ($level -eq 0) {
        Invoke-ShowError -U $U -Num $Script:ERR_CSSUSPEND -Env '' | Out-Null
        Kill-Conn -U $U -Reason $Script:KILL_COMMAND
        return
    }
    if ($level -lt $req) {
        Invoke-ShowError -U $U -Num $Script:ERR_LEVEL -Env $S[4] | Out-Null
        Kill-Conn -U $U -Reason $Script:KILL_COMMAND
        return
    }
    $U.ThisClient = New-FsdClient -Cid $S[2] -Location $Script:MyServer -Callsign $S[0] `
        -Type $Script:CLIENT_PILOT -ReqRating $level -Protocol $S[5] -RealName $S[7] -SimType (A2I $S[6])
    Invoke-SendAddClient -Dest '*' -Who $U.ThisClient -Direction $null -Source $U -Feed 0
    Invoke-ReadMotd -U $U
}

function Invoke-ExecD {
    # #DA / #DP
    param($U, [string[]]$S, [int]$Count)
    if ($Count -eq 0) { Invoke-ShowError -U $U -Num $Script:ERR_SYNTAX -Env '' | Out-Null; return }
    if (-not (Test-CheckSource -U $U -From $S[0])) { return }
    Kill-Conn -U $U -Reason $Script:KILL_COMMAND
}

function Invoke-ExecPilotPos {
    # @ identflag:callsign:transponder:rating:lat:lon:altitude:groundspeed:pbh:flags
    param($U, [string[]]$S, [int]$Count)
    if ($Count -lt 10) { Invoke-ShowError -U $U -Num $Script:ERR_SYNTAX -Env '' | Out-Null; return }
    if (-not (Test-CheckSource -U $U -From $S[1])) { return }
    Update-ClientPilot -Client $U.ThisClient -A $S
    Invoke-SendPilotData -Who $U.ThisClient -Ex $U
}

function Invoke-ExecAtcPos {
    # % callsign:frequency:facilitytype:visualrange:rating:lat:lon:altitude
    param($U, [string[]]$S, [int]$Count)
    if ($Count -lt 8) { Invoke-ShowError -U $U -Num $Script:ERR_SYNTAX -Env '' | Out-Null; return }
    if (-not (Test-CheckSource -U $U -From $S[0])) { return }
    $rest = @()
    for ($i = 1; $i -lt $Count; $i++) { $rest += $S[$i] }
    Update-ClientAtc -Client $U.ThisClient -A $rest
    Invoke-SendAtcData -Who $U.ThisClient -Ex $U
}

function Invoke-ExecFP {
    # $FP from:to:type:aircraft:...:route
    param($U, [string[]]$S, [int]$Count)
    if ($Count -lt 17) { Invoke-ShowError -U $U -Num $Script:ERR_SYNTAX -Env '' | Out-Null; return }
    if (-not (Test-CheckSource -U $U -From $S[0])) { return }
    $rest = @()
    for ($i = 2; $i -lt $Count; $i++) { $rest += $S[$i] }
    Set-ClientPlan -Client $U.ThisClient -Fields $rest
    Invoke-SendPlanS2S -Dest '*' -Who $U.ThisClient -Direction $null
}

function Invoke-ExecWeather {
    # #RW / #WX from:to:station
    param($U, [string[]]$S, [int]$Count)
    if ($Count -lt 3) { Invoke-ShowError -U $U -Num $Script:ERR_SYNTAX -Env '' | Out-Null; return }
    if (-not (Test-CheckSource -U $U -From $S[0])) { return }
    $source = '%' + $U.ThisClient.Callsign
    Invoke-RequestMetar -Client $source -Metar $S[2] -Parsed 1 -Fd -1 | Out-Null
}

function Invoke-ExecAcars {
    # $AX from:to:...
    param($U, [string[]]$S, [int]$Count)
    if ($Count -lt 3) { Invoke-ShowError -U $U -Num $Script:ERR_SYNTAX -Env '' | Out-Null; return }
    if (-not (Test-CheckSource -U $U -From $S[0])) { return }
    if ((Test-StrIEqual $S[2] 'METAR') -and ($Count -gt 3)) {
        $source = '%' + $U.ThisClient.Callsign
        Invoke-RequestMetar -Client $source -Metar $S[3] -Parsed 0 -Fd -1 | Out-Null
    }
}

function Invoke-ExecMulticast {
    param($U, [string[]]$S, [int]$Count, [int]$Cmd, [int]$NArgs, [bool]$MultiOk)
    $need = $NArgs + 2
    if ($Count -lt $need) { Invoke-ShowError -U $U -Num $Script:ERR_SYNTAX -Env '' | Out-Null; return }
    $rest = @()
    for ($i = 2; $i -lt $Count; $i++) { $rest += $S[$i] }
    $data = ($rest -join ':')
    $from = $S[0]
    $to = $S[1]
    if (-not (Test-CheckSource -U $U -From $from)) { return }
    Invoke-SendMulticast -Source $U.ThisClient -Dest $to -S $data -Cmd $Cmd -MultiOk $MultiOk -Ex $U | Out-Null
}

function Invoke-ExecCQ {
    # $CQ from:to:type:...
    param($U, [string[]]$S, [int]$Count)
    if ($Count -lt 3) { Invoke-ShowError -U $U -Num $Script:ERR_SYNTAX -Env '' | Out-Null; return }
    if (-not (Test-StrIEqual $S[1] 'server')) {
        Invoke-ExecMulticast -U $U -S $S -Count $Count -Cmd $Script:CL_CQ -NArgs 1 -MultiOk $true
        return
    }
    if ((ConvertTo-Upper $S[2]) -eq 'RN') {
        # Compatibility note: the real-name query resolves the target in
        # field 1 (which is always 'server' here); kept as-is so that
        # behaviour matches what classic FSD clients expect.
        $cl = Get-FsdClient -Ident $S[1]
        if ($cl) {
            $data = ('{0}:{1}:RN:{2}:USER:{3}' -f $cl.Callsign, $U.ThisClient.Callsign, $cl.RealName, $cl.Rating)
            Invoke-SendPacketLocal -Dest $U.ThisClient -Source $cl -Exclude $null `
                -Broad $Script:CLIENT_ALL -Range -1 -Cmd $Script:CL_CR -Data $data
            return
        }
    }
    if (Test-StrIEqual $S[2] 'fp') {
        $cl = Get-FsdClient -Ident $S[3]
        if (-not $cl) { Invoke-ShowError -U $U -Num $Script:ERR_NOSUCHCS -Env $S[3] | Out-Null; return }
        if (-not $cl.Plan) { Invoke-ShowError -U $U -Num $Script:ERR_NOFP -Env '' | Out-Null; return }
        Invoke-SendPlanLocal -Dest $U.ThisClient -Who $cl -Range -1
        return
    }
}

function Invoke-ExecClientKill {
    # $!! from:target:reason
    param($U, [string[]]$S, [int]$Count)
    if ($Count -lt 3) { Invoke-ShowError -U $U -Num $Script:ERR_SYNTAX -Env '' | Out-Null; return }
    $cl = Get-FsdClient -Ident $S[1]
    if (-not $cl) {
        Invoke-ShowError -U $U -Num $Script:ERR_NOSUCHCS -Env $S[1] | Out-Null
        return
    }
    if ($U.ThisClient.Rating -lt 11) {
        Invoke-SendGeneric -To $U.ThisClient.Callsign -Dest $U.ThisClient -Ex $null `
            -Source $null -From 'server' -S 'You are not allowed to kill users!' -Cmd $Script:CL_MESSAGE
        Write-Dolog -Level $Script:L_ERR -Message ("{0} attempted to remove {1}, but was not allowed to" -f $U.ThisClient.Callsign, $S[1])
    } else {
        Invoke-SendGeneric -To $U.ThisClient.Callsign -Dest $U.ThisClient -Ex $null `
            -Source $null -From 'server' -S ("Attempting to kill {0}" -f $S[1]) -Cmd $Script:CL_MESSAGE
        Write-Dolog -Level $Script:L_INFO -Message ("{0} Killed {1}" -f $U.ThisClient.Callsign, $S[1])
        Invoke-SendKill -Who $cl -Reason $S[2]
    }
}

# ---------------------------------------------------------------------------
# Outgoing packet builders (clinterface.cpp)
# ---------------------------------------------------------------------------

function Get-Broad {
    param([string]$S)
    if ($S -ceq '*P') { return $Script:CLIENT_PILOT }
    if ($S -ceq '*A') { return $Script:CLIENT_ATC }
    return $Script:CLIENT_ALL
}

function Invoke-CalcRange {
    param($From, $To, [int]$Type, [int]$Range)
    switch ($Type) {
        { $_ -eq $Script:CL_PILOTPOS -or $_ -eq $Script:CL_ATCPOS } {
            if ($To.Type -eq $Script:CLIENT_ATC) { return $To.VisualRange }
            $x = Get-ClientRange -Client $To
            $y = Get-ClientRange -Client $From
            if ($From.Type -eq $Script:CLIENT_PILOT) { return ($x + $y) }
            if ($x -gt $y) { return $x }
            return $y
        }
        $Script:CL_MESSAGE {
            $x = Get-ClientRange -Client $To
            $y = Get-ClientRange -Client $From
            if ($From.Type -eq $Script:CLIENT_PILOT -and $To.Type -eq $Script:CLIENT_PILOT) { return ($x + $y) }
            if ($x -gt $y) { return $x }
            return $y
        }
        default { return $Range }
    }
}

# sendpacket(): deliver a packet to local client connections
function Invoke-SendPacketLocal {
    param($Dest, $Source, $Exclude, [int]$Broad, [int]$Range, [int]$Cmd, [string]$Data)
    if ($Dest) {
        if (-not [object]::ReferenceEquals($Dest.Location, $Script:MyServer)) { return }
    }
    foreach ($u in $Script:ClientIF.Users.ToArray()) {
        if ($u.KillFlag) { continue }
        $cl = $u.ThisClient
        if (-not $cl) { continue }
        if ($Exclude -and [object]::ReferenceEquals($Exclude, $u)) { continue }
        if ($Dest -and -not [object]::ReferenceEquals($cl, $Dest)) { continue }
        if ((($cl.Type -band $Broad) -eq 0)) { continue }
        if ($Source -and ($Range -ne -1 -or $Cmd -eq $Script:CL_PILOTPOS -or $Cmd -eq $Script:CL_ATCPOS)) {
            $checkrange = Invoke-CalcRange -From $Source -To $cl -Type $Cmd -Range $Range
            $distance = Get-ClientDistance -Client $cl -Other $Source
            if ($distance -eq -1 -or $distance -gt $checkrange) { continue }
        }
        $check = ($Cmd -eq $Script:CL_ATCPOS -or $Cmd -eq $Script:CL_PILOTPOS)
        Send-UsL -U $u -S ($Script:ClCmdNames[$Cmd] + $Data + "`r`n") -Check $check
    }
}

function Invoke-SendGeneric {
    param([string]$To, $Dest, $Ex, $Source, [string]$From, [string]$S, [int]$Cmd)
    $buf = '{0}:{1}:{2}' -f $From, $To, $S
    $range = -1
    if ($To.Length -gt 0 -and $To[0] -eq '@' -and $Source) {
        $range = Get-ClientRange -Client $Source
    }
    Invoke-SendPacketLocal -Dest $Dest -Source $Source -Exclude $Ex `
        -Broad (Get-Broad -S $To) -Range $range -Cmd $Cmd -Data $buf
}

function Invoke-SendAA {
    # Wire format note: the #AA announcement intentionally contains an empty
    # field before the rating and does not repeat the protocol revision;
    # classic FSD clients parse exactly this layout.
    param($Who, $Ex)
    $data = '{0}:SERVER:{1}:{2}::{3}' -f $Who.Callsign, $Who.RealName, $Who.Cid, $Who.Rating
    Invoke-SendPacketLocal -Dest $null -Source $null -Exclude $Ex `
        -Broad $Script:CLIENT_ALL -Range -1 -Cmd $Script:CL_ADDATC -Data $data
}

function Invoke-SendAP {
    param($Who, $Ex)
    $data = '{0}:SERVER:{1}::{2}:{3}:{4}' -f $Who.Callsign, $Who.Cid, $Who.Rating, $Who.Protocol, $Who.SimType
    Invoke-SendPacketLocal -Dest $null -Source $null -Exclude $Ex `
        -Broad $Script:CLIENT_ALL -Range -1 -Cmd $Script:CL_ADDPILOT -Data $data
}

function Invoke-SendDA {
    param($Who, $Ex)
    $data = '{0}:{1}' -f $Who.Callsign, $Who.Cid
    Invoke-SendPacketLocal -Dest $null -Source $null -Exclude $Ex `
        -Broad $Script:CLIENT_ALL -Range -1 -Cmd $Script:CL_RMATC -Data $data
}

function Invoke-SendDP {
    param($Who, $Ex)
    $data = '{0}:{1}' -f $Who.Callsign, $Who.Cid
    Invoke-SendPacketLocal -Dest $null -Source $null -Exclude $Ex `
        -Broad $Script:CLIENT_ALL -Range -1 -Cmd $Script:CL_RMPILOT -Data $data
}

function Invoke-SendPilotPos {
    param($Who, $Ex)
    $data = '{0}:{1}:{2}:{3}:{4}:{5}:{6}:{7}:{8}:{9}' -f `
        $Who.IdentFlag, $Who.Callsign, $Who.Transponder, $Who.Rating,
        (F5 $Who.Lat), (F5 $Who.Lon), $Who.Altitude, $Who.GroundSpeed, $Who.Pbh, $Who.Flags
    Invoke-SendPacketLocal -Dest $null -Source $Who -Exclude $Ex `
        -Broad $Script:CLIENT_ALL -Range -1 -Cmd $Script:CL_PILOTPOS -Data $data
}

function Invoke-SendAtcPos {
    param($Who, $Ex)
    $data = '{0}:{1}:{2}:{3}:{4}:{5}:{6}:{7}' -f `
        $Who.Callsign, $Who.Frequency, $Who.FacilityType, $Who.VisualRange, $Who.Rating,
        (F5 $Who.Lat), (F5 $Who.Lon), $Who.Altitude
    Invoke-SendPacketLocal -Dest $null -Source $Who -Exclude $Ex `
        -Broad $Script:CLIENT_ALL -Range -1 -Cmd $Script:CL_ATCPOS -Data $data
}

function Invoke-SendPlanLocal {
    param($Dest, $Who, [int]$Range)
    if (-not $Who.Plan) { return }
    $cs = if ($Dest) { $Dest.Callsign } else { '*A' }
    $plan = $Who.Plan
    $buf = '{0}:{1}:{2}:{3}:{4}:{5}:{6}:{7}:{8}:{9}:{10}:{11}:{12}:{13}:{14}:{15}:{16}' -f `
        $Who.Callsign, $cs, $plan.Type, $plan.Aircraft,
        $plan.TasCruise, $plan.DepAirport, $plan.DepTime, $plan.ActDepTime,
        $plan.Alt, $plan.DestAirport, $plan.HrsEnroute, $plan.MinEnroute,
        $plan.HrsFuel, $plan.MinFuel, $plan.AltAirport, $plan.Remarks, $plan.Route
    Invoke-SendPacketLocal -Dest $Dest -Source $null -Exclude $null `
        -Broad $Script:CLIENT_ATC -Range $Range -Cmd $Script:CL_PLAN -Data $buf
}

function Invoke-SendWeatherLocal {
    param($Who, $Wp)
    Repair-WProfile -Wp $Wp -Lat $Who.Lat -Lon $Who.Lon

    $buf = 'server:{0}' -f $Who.Callsign
    foreach ($l in $Wp.Temps)  { $buf += ':{0}:{1}' -f $l.Ceiling, $l.Temp }
    $buf += ':{0}' -f $Wp.Barometer
    Invoke-SendPacketLocal -Dest $Who -Source $null -Exclude $null `
        -Broad $Script:CLIENT_ALL -Range -1 -Cmd $Script:CL_TEMPDATA -Data $buf

    $buf = 'server:{0}' -f $Who.Callsign
    foreach ($l in $Wp.Winds) {
        $buf += ':{0}:{1}:{2}:{3}:{4}:{5}' -f $l.Ceiling, $l.Floor, $l.Direction, $l.Speed, $l.Gusting, $l.Turbulence
    }
    Invoke-SendPacketLocal -Dest $Who -Source $null -Exclude $null `
        -Broad $Script:CLIENT_ALL -Range -1 -Cmd $Script:CL_WINDDATA -Data $buf

    $buf = 'server:{0}' -f $Who.Callsign
    for ($x = 0; $x -lt 3; $x++) {
        $c = if ($x -eq 2) { $Wp.TStorm } else { $Wp.Clouds[$x] }
        $buf += ':{0}:{1}:{2}:{3}:{4}' -f $c.Ceiling, $c.Floor, $c.Coverage, $c.Icing, $c.Turbulence
    }
    $buf += ':{0}' -f (F2 $Wp.Visibility)
    Invoke-SendPacketLocal -Dest $Who -Source $null -Exclude $null `
        -Broad $Script:CLIENT_ALL -Range -1 -Cmd $Script:CL_CLOUDDATA -Data $buf
}

function Invoke-SendMetarLocal {
    param($Who, [string]$Data)
    $buf = 'server:{0}:METAR:{1}' -f $Who.Callsign, $Data
    Invoke-SendPacketLocal -Dest $Who -Source $null -Exclude $null `
        -Broad $Script:CLIENT_ALL -Range -1 -Cmd $Script:CL_REPACARS -Data $buf
}

function Invoke-SendNowxLocal {
    param($Who, [string]$Station)
    foreach ($u in $Script:ClientIF.Users) {
        if ($u.ThisClient -and [object]::ReferenceEquals($u.ThisClient, $Who)) {
            Invoke-ShowError -U $u -Num $Script:ERR_NOWEATHER -Env $Station | Out-Null
            break
        }
    }
}

function Invoke-HandleKillLocal {
    param($Who, [string]$Reason)
    if (-not [object]::ReferenceEquals($Who.Location, $Script:MyServer)) { return }
    foreach ($u in $Script:ClientIF.Users) {
        if ($u.ThisClient -and [object]::ReferenceEquals($u.ThisClient, $Who)) {
            $buf = 'SERVER:{0}:{1}' -f $Who.Callsign, $Reason
            Invoke-SendPacketLocal -Dest $Who -Source $null -Exclude $null `
                -Broad $Script:CLIENT_ALL -Range -1 -Cmd $Script:CL_KILL -Data $buf
            Kill-Conn -U $u -Reason $Script:KILL_KILL
        }
    }
}

function Invoke-SendWindDelta {
    Reset-MRand -Seed ([int]([DateTimeOffset]::Now.ToUnixTimeSeconds()))
    $speed = (Mod-C (Get-MRand) 11) - 5
    $direction = (Mod-C (Get-MRand) 21) - 10
    $buf = 'SERVER:*:{0}:{1}' -f $speed, $direction
    Invoke-SendPacketLocal -Dest $null -Source $null -Exclude $null `
        -Broad $Script:CLIENT_ALL -Range -1 -Cmd $Script:CL_WDELTA -Data $buf
}
