# ============================================================================
#  PowerShell-FSD - 50.Model.ps1
#  Server / Client / Flightplan domain objects
# ============================================================================

function New-FsdServer {
    # server(ident, name, email, hostname, version, flags, location)
    param(
        [string]$Ident, [string]$Name, [string]$Email, [string]$Hostname,
        [string]$SVersion, [int]$Flags, [string]$Location
    )
    $srv = @{
        Ident       = $Ident
        Name        = $Name
        Email       = $Email
        Hostname    = $Hostname
        Version     = $SVersion
        Flags       = $Flags
        Location    = $Location
        Path        = $null        # connection (servuser) used as next hop
        Hops        = -1
        PCount      = -1
        Lag         = -1
        PacketDrops = 0
        Alive       = Get-MTime
        Check       = 0
    }
    $Script:RootServer.Add($srv) | Out-Null
    return $srv
}

function Set-FsdServerConfig {
    # configure(): update the descriptive fields
    param($Srv, [string]$Name, [string]$Email, [string]$Hostname, [string]$SVersion, [string]$Location)
    $Srv.Name     = $Name
    $Srv.Email    = $Email
    $Srv.Hostname = $Hostname
    $Srv.Version  = $SVersion
    $Srv.Location = $Location
}

function Remove-FsdServer {
    param($Srv)
    Write-Dolog -Level $Script:L_ERR -Message ("Dropping server {0}({1})" -f $Srv.Ident, $Srv.Name)
    $Script:RootServer.Remove($Srv) | Out-Null

    # Drop every client homed on this server
    for ($i = $Script:RootClient.Count - 1; $i -ge 0; $i--) {
        $c = $Script:RootClient[$i]
        if ([object]::ReferenceEquals($c.Location, $Srv)) {
            Remove-FsdClient -Client $c
        }
    }

    # Clear thisserver references on server links
    if ($Script:ServerIF) {
        foreach ($u in $Script:ServerIF.Users.ToArray()) {
            if ($u.ThisServer -and [object]::ReferenceEquals($u.ThisServer, $Srv)) {
                $u.ThisServer = $null
            }
        }
    }
}

function Get-FsdServer {
    param([string]$Ident)
    foreach ($s in $Script:RootServer) {
        if (Test-StrIEqual $Ident $s.Ident) { return $s }
    }
    return $null
}

function Set-ServerPath {
    param($Srv, $Conn, [int]$Hops)
    $Srv.Path = $Conn
    $Srv.Hops = $Hops
    if ($null -eq $Conn) { $Srv.PCount = -1 }
}

function Set-ServerAlive {
    param($Srv)
    $Srv.Alive = Get-MTime
}

function Receive-ServerPong {
    param($Srv, [string]$Data)
    $parts = $Data -split ' '
    if ($parts.Count -lt 2) { return }
    $t = A2I $parts[1]
    if ($t -le 0) { return }
    $Srv.Lag = Get-MTime - $t
}

function Clear-ServerChecks {
    foreach ($s in $Script:RootServer) { $s.Check = 0 }
}

# ---------------------------------------------------------------------------
# Flightplan
# ---------------------------------------------------------------------------

function New-FlightPlan {
    # flightplan(callsign, type, aircraft, tascruise, depairport, deptime,
    #   actdeptime, alt, destairport, hrsenroute, minenroute, hrsfuel,
    #   minfuel, altairport, remarks, route)
    param(
        [string]$Callsign, $Type, [string]$Aircraft, [int]$TasCruise,
        [string]$DepAirport, [int]$DepTime, [int]$ActDepTime, [string]$Alt,
        [string]$DestAirport, [int]$HrsEnroute, [int]$MinEnroute,
        [int]$HrsFuel, [int]$MinFuel, [string]$AltAirport,
        [string]$Remarks, [string]$Route
    )
    # plan->type is a single character in C
    $typeChar = ''
    if ($Type -is [string] -and $Type.Length -gt 0) { $typeChar = $Type.Substring(0, 1) }
    return @{
        Callsign    = $Callsign
        Revision    = 0
        Type        = $typeChar
        Aircraft    = $Aircraft
        TasCruise   = $TasCruise
        DepAirport  = $DepAirport
        DepTime     = $DepTime
        ActDepTime  = $ActDepTime
        Alt         = $Alt
        DestAirport = $DestAirport
        HrsEnroute  = $HrsEnroute
        MinEnroute  = $MinEnroute
        HrsFuel     = $HrsFuel
        MinFuel     = $MinFuel
        AltAirport  = $AltAirport
        Remarks     = $Remarks
        Route       = $Route
    }
}

# ---------------------------------------------------------------------------
# Client
# ---------------------------------------------------------------------------

function New-FsdClient {
    # client(cid, location, callsign, type, reqrating, protocol, realname, simtype)
    param(
        [string]$Cid, $Location, [string]$Callsign, [int]$Type, [int]$ReqRating,
        [string]$Protocol, [string]$RealName, [int]$SimType
    )
    $c = @{
        Cid          = $Cid
        Callsign     = $Callsign
        Type         = $Type
        Rating       = $ReqRating
        Protocol     = $Protocol
        RealName     = $RealName
        Sector       = $null
        IdentFlag    = $null
        FacilityType = 0
        VisualRange  = 40
        Plan         = $null
        PositionOk   = $false
        Altitude     = 0
        SimType      = $SimType
        Location     = $Location
        StartTime    = Get-MTime
        Alive        = Get-MTime
        Frequency    = 0
        Transponder  = 0
        GroundSpeed  = 0
        Lat          = 0.0
        Lon          = 0.0
        Pbh          = [uint32]0
        Flags        = 0
    }
    $Script:RootClient.Add($c) | Out-Null
    return $c
}

function Remove-FsdClient {
    param($Client)
    # serverinterface->clientdropped(): warn silent (feed-only) servers so they
    # get an explicit RMCLIENT (they would otherwise never receive updates)
    if ($Script:ServerIF) { Invoke-ClientDropped -Client $Client }
    $Script:RootClient.Remove($Client) | Out-Null
}

function Get-FsdClient {
    param([string]$Ident)
    foreach ($c in $Script:RootClient) {
        if (Test-StrIEqual $Ident $c.Callsign) { return $c }
    }
    return $null
}

function Set-ClientPlan {
    # handlefp(): fields start at the plan 'type' field
    param($Client, $Fields)
    $revision = 0
    if ($Client.Plan) { $revision = $Client.Plan.Revision + 1 }
    $Client.Plan = New-FlightPlan `
        -Callsign   $Client.Callsign `
        -Type       $Fields[0] `
        -Aircraft   $Fields[1] `
        -TasCruise  (A2I $Fields[2]) `
        -DepAirport $Fields[3] `
        -DepTime    (A2I $Fields[4]) `
        -ActDepTime (A2I $Fields[5]) `
        -Alt        $Fields[6] `
        -DestAirport $Fields[7] `
        -HrsEnroute (A2I $Fields[8]) `
        -MinEnroute (A2I $Fields[9]) `
        -HrsFuel    (A2I $Fields[10]) `
        -MinFuel    (A2I $Fields[11]) `
        -AltAirport $Fields[12] `
        -Remarks    $Fields[13] `
        -Route      $Fields[14]
    $Client.Plan.Revision = $revision
}

function Update-ClientPilot {
    # updatepilot(): @ packet fields
    param($Client, [string[]]$A)
    $Client.Transponder = A2I $A[2]
    $Client.IdentFlag   = $A[0]
    $Client.Lat = A2F $A[4]
    $Client.Lon = A2F $A[5]
    if ($Client.Lat -gt 90.0 -or $Client.Lat -lt -90.0 -or $Client.Lon -gt 180.0 -or $Client.Lon -lt -180.0) {
        Write-Dolog -Level $Script:L_DEBUG -Message ("POSERR: s=({0},{1}) got({2},{3})" -f $A[4], $A[5], $Client.Lat, $Client.Lon)
    }
    $Client.Altitude    = A2I $A[6]
    $Client.GroundSpeed = A2I $A[7]
    $Client.Pbh         = A2U $A[8]
    $Client.Flags       = A2I $A[9]
    $Client.Alive = Get-MTime
    $Client.PositionOk = $true
}

function Update-ClientAtc {
    # updateatc(): % packet fields (without the callsign)
    param($Client, [string[]]$A)
    $Client.Frequency    = A2I $A[0]
    $Client.FacilityType = A2I $A[1]
    $Client.VisualRange  = A2I $A[2]
    $Client.Lat = A2F $A[4]
    $Client.Lon = A2F $A[5]
    $Client.Altitude = A2I $A[6]
    $Client.Alive = Get-MTime
    $Client.PositionOk = $true
}

function Set-ClientAlive {
    param($Client)
    $Client.Alive = Get-MTime
}

function Get-ClientDistance {
    param($Client, $Other)
    if (-not $Other) { return -1.0 }
    if (-not $Client.PositionOk -or -not $Other.PositionOk) { return -1.0 }
    return (Get-DistanceNM -Lat1 $Client.Lat -Lon1 $Client.Lon -Lat2 $Other.Lat -Lon2 $Other.Lon)
}

function Get-ClientRange {
    param($Client)
    if ($Client.Type -eq $Script:CLIENT_PILOT) {
        if ($Client.Altitude -lt 0) { $Client.Altitude = 0 }
        return [int](10 + 1.414 * [Math]::Sqrt([double]$Client.Altitude))
    }
    switch ($Client.FacilityType) {
        0       { return 40 }     # Unknown
        1       { return 1500 }   # FSS
        2       { return 5 }      # CLR_DEL
        3       { return 5 }      # GROUND
        4       { return 30 }     # TOWER
        5       { return 100 }    # APP/DEP
        6       { return 400 }    # CENTER
        7       { return 1500 }   # MONITOR
        default { return 40 }
    }
}
