# ============================================================================
#  PowerShell-FSD - 90.Fsd.ps1
#  Server orchestration: boot sequence, periodic checks, main loop
# ============================================================================

$Script:ClientPort = 6809
$Script:ServerPort = 3011
$Script:SystemPort = 3012
$Script:CertFile   = $null
$Script:WhazzupFile = $null
$Script:CertFileStat = 0
$Script:PrevNotify = 0
$Script:PrevLagCheck = 0
$Script:PrevCertCheck = 0
$Script:PrevWhazzup = 0
$Script:WhazzupOpen = 0

function Initialize-Fsd {
    param([string]$ConfigFile)

    Initialize-Manager
    Write-Dolog -Level $Script:L_INFO -Message 'Booting server'

    [void](New-ConfigManager -FileName $ConfigFile)
    [void](New-MetarManager)

    Invoke-FsdConfigure
    New-FsdManageVars
    New-FsdInterfaces
    Invoke-MakeConnections

    Write-Dolog -Level $Script:L_INFO -Message 'We are up'
    $Script:PrevNotify = Get-MTime
    $Script:PrevLagCheck = Get-MTime
    $Script:PrevCertCheck = Get-MTime
    $Script:PrevWhazzup = Get-MTime
    $Script:FsdTimer = Get-MTime
    $Script:WhazzupOpen = 0
}

function New-FsdManageVars {
    $v = Add-MgrVar -Name 'system.boottime' -Type 'date'
    Set-MgrVar -Num $v -Value ([DateTimeOffset]::Now.ToUnixTimeSeconds())
    $v = Add-MgrVar -Name 'version.system' -Type 'varchar'
    Set-MgrVar -Num $v -Value $Script:VERSION
}

function Invoke-FsdConfigure {
    $Script:ClientPort = 6809
    $Script:ServerPort = 3011
    $Script:SystemPort = 3012
    $sysgroup = Get-ConfigGroup -Name 'system'
    if ($sysgroup) {
        $e = Get-ConfigEntry -Group $sysgroup -Name 'clientport'
        if ($e) { $Script:ClientPort = A2I $e.Data }
        $e = Get-ConfigEntry -Group $sysgroup -Name 'serverport'
        if ($e) { $Script:ServerPort = A2I $e.Data }
        $e = Get-ConfigEntry -Group $sysgroup -Name 'systemport'
        if ($e) { $Script:SystemPort = A2I $e.Data }
        $e = Get-ConfigEntry -Group $sysgroup -Name 'certificates'
        if ($e) { $Script:CertFile = $e.Data }
        $e = Get-ConfigEntry -Group $sysgroup -Name 'whazzup'
        if ($e) { $Script:WhazzupFile = $e.Data }
    }
    Invoke-ConfigMyServer
    Invoke-ReadCert
}

function Invoke-ConfigMyServer {
    $mode = 0
    $serverident = $null; $servername = $null
    $servermail = $null; $serverhostname = $null; $serverlocation = $null
    $sysgroup = Get-ConfigGroup -Name 'system'
    if ($sysgroup) {
        $sysgroup.Changed = $false
        $e = Get-ConfigEntry -Group $sysgroup -Name 'ident'
        if ($e) { $serverident = $e.Data }
        $e = Get-ConfigEntry -Group $sysgroup -Name 'name'
        if ($e) { $servername = $e.Data }
        $e = Get-ConfigEntry -Group $sysgroup -Name 'email'
        if ($e) { $servermail = $e.Data }
        $e = Get-ConfigEntry -Group $sysgroup -Name 'hostname'
        if ($e) { $serverhostname = $e.Data }
        $e = Get-ConfigEntry -Group $sysgroup -Name 'location'
        if ($e) { $serverlocation = $e.Data }
        $e = Get-ConfigEntry -Group $sysgroup -Name 'mode'
        if ($e -and (Test-StrIEqual $e.Data 'silent')) { $mode = $Script:SERVER_SILENT }
    }
    if (-not $serverident) {
        $serverident = "$PID"
        Write-Dolog -Level $Script:L_ERR -Message 'No serverident specified'
    }
    if (-not $servermail) {
        $servermail = ''
        Write-Dolog -Level $Script:L_ERR -Message 'No server mail address specified'
    }
    if (-not $serverhostname) {
        $serverhostname = Get-LocalHostName
        Write-Dolog -Level $Script:L_ERR -Message 'No server host name specified'
    }
    if (-not $servername) {
        Write-Dolog -Level $Script:L_ERR -Message 'No servername specified'
        $servername = $serverhostname
    }
    if (-not $serverlocation) {
        Write-Dolog -Level $Script:L_ERR -Message 'No serverlocation specified'
        $serverlocation = ''
    }
    $flags = $mode
    if ($Script:MetarMgr.Source -ne $Script:SOURCE_NETWORK) { $flags = $flags -bor $Script:SERVER_METAR }
    if ($Script:MyServer) {
        Set-FsdServerConfig -Srv $Script:MyServer -Name $servername -Email $servermail `
            -Hostname $serverhostname -SVersion $Script:VERSION -Location $serverlocation
    } else {
        $Script:MyServer = New-FsdServer -Ident $serverident -Name $servername -Email $servermail `
            -Hostname $serverhostname -SVersion $Script:VERSION -Flags $flags -Location $serverlocation
    }
}

function New-FsdInterfaces {
    $prompt = '{0}> ' -f $Script:MyServer.Ident
    [void](New-ClientInterface -Port $Script:ClientPort)
    [void](New-ServerInterface -Port $Script:ServerPort)
    [void](New-SysInterfaceStub -Port $Script:SystemPort)
    Set-IFPrompt -Iface $Script:SysIF -P $prompt

    Set-IFFeedStrategy -Iface $Script:ServerIF -Strategy $Script:FEED_BOTH
    # Clients may send a maximum of 100000 bytes/second
    Set-IFFlood -Iface $Script:ClientIF -Limit 100000
    Set-IFFeedStrategy -Iface $Script:ClientIF -Strategy $Script:FEED_IN
    # Clients may have a buffer of 100000 bytes
    Set-IFOutBufLimit -Iface $Script:ClientIF -Limit 100000
}

function New-SysInterfaceStub {
    param([int]$Port)
    $iface = New-FsdInterface -Kind 'sys' -Port $Port -Code 'sys' -Description 'system management interface'
    $Script:SysIF = $iface
    return $iface
}

function Invoke-MakeConnections {
    $cgroup = Get-ConfigGroup -Name 'connections'
    if (-not $cgroup) { return }
    $centry = Get-ConfigEntry -Group $cgroup -Name 'connectto'
    if ($centry) {
        foreach ($part in (Get-ConfigParts -Entry $centry)) {
            if (-not $part) { continue }
            $portnum = 3011
            $hostpart = $part
            $colon = $part.IndexOf(':')
            if ($colon -ge 0) {
                $port = Try-A2I $part.Substring($colon + 1)
                if ($null -ne $port) { $portnum = $port }
                $hostpart = $part.Substring(0, $colon)
            }
            if ((Add-IFOutgoing -Iface $Script:ServerIF -Name $hostpart -Port $portnum -Terminal $null) -eq 1) {
                Write-Dolog -Level $Script:L_INFO -Message ("Connected to {0} port {1}" -f $hostpart, $portnum)
            } else {
                Write-Dolog -Level $Script:L_ERR -Message ("Connection to {0} port {1} failed!" -f $hostpart, $portnum)
            }
        }
    }
    $centry = Get-ConfigEntry -Group $cgroup -Name 'allowfrom'
    if ($centry) {
        foreach ($part in (Get-ConfigParts -Entry $centry)) {
            if ($part) { Add-IFAllow -Iface $Script:ServerIF -Name $part }
        }
    } else {
        Write-Dolog -Level $Script:L_WARNING -Message "No 'allowfrom' found, allowing everybody on the server port"
    }
    Invoke-SendReset
}

# ---------------------------------------------------------------------------
# Certificate file handling
# ---------------------------------------------------------------------------

function Invoke-HandleCidLine {
    param([string]$Line)
    if ($Line.Length -gt 0 -and ($Line[0] -eq ';' -or $Line[0] -eq '#')) { return }
    $array = Break-Args -S $Line -Max 4
    if ($array.Count -lt 3) { return }
    $cid = $array[0]
    $pwd = $array[1]
    $level = A2I $array[2]
    $tempcert = Get-Cert -Cid $cid
    if (-not $tempcert) {
        $tempcert = New-Certificate -Cid $cid -Password $pwd -Level $level -Creation (Get-MGMTime) -Origin $Script:MyServer.Ident
        $mode = $Script:CERT_ADD
    } else {
        $tempcert.LiveCheck = $true
        if ((Test-StrIEqual $tempcert.Password $pwd) -and ($level -eq $tempcert.Level)) { return }
        Set-CertificateConfig -Cert $tempcert -Password $pwd -Level $level -Creation (Get-MGMTime) -Origin $Script:MyServer.Ident
        $mode = $Script:CERT_MODIFY
    }
    if ($Script:ServerIF) { Invoke-SendCert -Dest '*' -Cmd $mode -Cert $tempcert -Direction $null }
}

function Invoke-ReadCert {
    if (-not $Script:CertFile) { return }
    $path = Join-Path $Script:FsdDir $Script:CertFile
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Dolog -Level $Script:L_ERR -Message ("Could not open certificate file '{0}'" -f $Script:CertFile)
        return
    }
    foreach ($c in $Script:RootCert) { $c.LiveCheck = $false }
    Write-Dolog -Level $Script:L_INFO -Message ("Reading certificates from '{0}'" -f $Script:CertFile)
    foreach ($line in [System.IO.File]::ReadAllLines($path, $Script:FsdEnc)) {
        Invoke-HandleCidLine -Line $line
    }
    foreach ($c in $Script:RootCert.ToArray()) {
        if (-not $c.LiveCheck) {
            if ($Script:ServerIF) { Invoke-SendCert -Dest '*' -Cmd $Script:CERT_DELETE -Cert $c -Direction $null }
            Remove-Certificate -Cert $c
        }
    }
}

# ---------------------------------------------------------------------------
# Periodic checks (fsd::dochecks)
# ---------------------------------------------------------------------------

function Invoke-FsdChecks {
    $now = Get-MTime
    if (($now - $Script:PrevNotify) -gt $Script:NOTIFYCHECK) {
        $sgroup = Get-ConfigGroup -Name 'system'
        if ($sgroup -and $sgroup.Changed) { Invoke-ConfigMyServer }
        Invoke-SendServerNotify -Dest '*' -Subject $Script:MyServer -ToWho $null
        $Script:PrevNotify = $now
    }
    if (($now - $Script:PrevLagCheck) -gt $Script:LAGCHECK) {
        $data = '-1 {0}' -f $now
        Invoke-SendPing -Dest '*' -Data $data
        $Script:PrevLagCheck = $now
    }
    if (($now - $Script:PrevCertCheck) -gt $Script:CERTFILECHECK) {
        $sysgroup = Get-ConfigGroup -Name 'system'
        if ($sysgroup) {
            $entry = Get-ConfigEntry -Group $sysgroup -Name 'certificates'
            if ($entry) {
                $Script:CertFile = $entry.Data
                $Script:PrevCertCheck = $now
                $path = Join-Path $Script:FsdDir $Script:CertFile
                if (Test-Path -LiteralPath $path) {
                    $mtime = ([DateTimeOffset](Get-Item -LiteralPath $path).LastWriteTimeUtc).ToUnixTimeSeconds()
                    if ($mtime -ne $Script:CertFileStat) {
                        $Script:CertFileStat = $mtime
                        Invoke-ReadCert
                    }
                }
            }
        }
    }
    if (($now - $Script:PrevWhazzup) -ge $Script:WHAZZUPCHECK) {
        $sysgroup = Get-ConfigGroup -Name 'system'
        if ($sysgroup) {
            $entry = Get-ConfigEntry -Group $sysgroup -Name 'whazzup'
            if ($entry) {
                $Script:WhazzupFile = $entry.Data
                $Script:PrevWhazzup = $now
                Invoke-UpdateWhazzup
            }
        }
    }

    # Drop servers that have gone silent
    foreach ($s in $Script:RootServer.ToArray()) {
        if ((($now - $s.Alive) -gt $Script:SERVERTIMEOUT) -and
            (-not [object]::ReferenceEquals($s, $Script:MyServer))) {
            Remove-FsdServer -Srv $s
        }
    }

    # Client timeout: in silent mode we receive no updates, so use the long limit
    $limit = $Script:CLIENTTIMEOUT
    if ($Script:MyServer.Flags -band $Script:SERVER_SILENT) { $limit = $Script:SILENTCLIENTTIMEOUT }
    foreach ($c in $Script:RootClient.ToArray()) {
        if ([object]::ReferenceEquals($c.Location, $Script:MyServer)) { continue }
        if (($now - $c.Alive) -gt $limit) {
            Remove-FsdClient -Client $c
        }
    }
}

# ---------------------------------------------------------------------------
# WhazzUp output
# ---------------------------------------------------------------------------

function Invoke-UpdateWhazzup {
    if (-not $Script:WhazzupFile) { return }
    if ($Script:WhazzupOpen -ne 0) { return }
    $Script:WhazzupOpen = 1
    try {
        $now = Get-MTime
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.Append('![DateStamp]' + (Format-GmtDate -Now $now) + "`n")
        [void]$sb.Append("!GENERAL`n")
        [void]$sb.Append("VERSION = 1`n")
        [void]$sb.Append("RELOAD = 1`n")
        [void]$sb.Append('UPDATE = ' + (Format-Gmt -Now $now) + "`n")
        [void]$sb.Append('CONNECTED CLIENTS = ' + $Script:RootClient.Count + "`n")
        [void]$sb.Append('CONNECTED SERVERS = ' + $Script:RootServer.Count + "`n")
        [void]$sb.Append("!CLIENTS`n")
        foreach ($c in $Script:RootClient) {
            $seg1 = '{0}:{1}:{2}:{3}' -f $c.Callsign, $c.Cid, $c.RealName,
                $(if ($c.Type -eq $Script:CLIENT_ATC) { 'ATC' } else { 'PILOT' })
            $seg2 = ''
            if ($c.Frequency -ne 0 -and $c.Frequency -lt 100000) {
                $seg2 = '1{0:00}.{1:000}' -f ([int]($c.Frequency / 1000)), ($c.Frequency % 1000)
            }
            $seg3 = ':::'
            if ($c.Lat -ne 0 -and $c.Altitude -lt 100000 -and $c.Lon -ne 0) {
                $seg3 = '{0}:{1}:{2}:{3}' -f (F6 $c.Lat), (F6 $c.Lon), $c.Altitude, $c.GroundSpeed
            }
            $seg4 = '::::'
            if ($c.Plan) {
                $p = $c.Plan
                $seg4 = '{0}:{1}:{2}:{3}:{4}' -f $p.Aircraft, $p.TasCruise, $p.DepAirport, $p.Alt, $p.DestAirport
            }
            $seg5 = '{0}:{1}:{2}:{3}:{4}:{5}' -f `
                $c.Location.Ident, $c.Protocol, $c.Rating, $c.Transponder, $c.FacilityType, $c.VisualRange
            $seg6 = '::::::::::'
            if ($c.Plan) {
                $p = $c.Plan
                $seg6 = '{0}:{1}:{2}:{3}:{4}:{5}:{6}:{7}:{8}:{9}:{10}' -f `
                    $p.Revision, $p.Type, $p.DepTime, $p.ActDepTime, $p.HrsEnroute, $p.MinEnroute,
                    $p.HrsFuel, $p.MinFuel, $p.AltAirport, $p.Remarks, $p.Route
            }
            $seg7 = '::::::' + (Format-Gmt -Now $c.StartTime)
            [void]$sb.Append($seg1 + ':' + $seg2 + ':' + $seg3 + ':' + $seg4 + ':' + $seg5 + ':' + $seg6 + ':' + $seg7 + "`n")
        }
        [void]$sb.Append("!SERVERS`n")
        foreach ($s in $Script:RootServer) {
            if ($s.Hostname -ceq 'n/a') { continue }
            $silent = if ($s.Flags -band $Script:SERVER_SILENT) { 0 } else { 1 }
            [void]$sb.Append(('{0}:{1}:{2}:{3}:{4}' -f $s.Ident, $s.Hostname, $s.Location, $s.Name, $silent) + "`n")
        }
        $target = Join-Path $Script:FsdDir $Script:WhazzupFile
        $temp = $target + '.tmp'
        [System.IO.File]::WriteAllText($temp, $sb.ToString(), $Script:FsdEnc)
        if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Force }
        Move-Item -LiteralPath $temp -Destination $target -Force
    } catch {
        Write-Dolog -Level $Script:L_ERR -Message ("WhazzUp write failed: {0}" -f $_.Exception.Message)
    } finally {
        $Script:WhazzupOpen = 0
    }
}

# ---------------------------------------------------------------------------
# Main loop (fsd::run / pman::run)
# ---------------------------------------------------------------------------

function Invoke-FsdIteration {
    # one iteration of the select() loop (pman::run + fsd::run)
    $busy = $false

    # Config hot reload
    Invoke-ConfigRun

    # Interfaces
    if (Invoke-ClientIFRun) { $busy = $true }
    if (Invoke-ServerIFRun -Iface $Script:ServerIF) { $busy = $true }
    if (Invoke-IFRunCore -Iface $Script:SysIF) { $busy = $true }

    # METAR manager
    Invoke-MetarRun

    # Once per second checks
    $now = Get-MTime
    if ($Script:FsdTimer -ne $now) {
        $Script:FsdTimer = $now
        Invoke-FsdChecks
    }

    return $busy
}

function Invoke-FsdRun {
    while (-not $Script:StopRequested) {
        $busy = Invoke-FsdIteration
        if (-not $busy) { Start-Sleep -Milliseconds 25 }
    }
}

function Stop-FsdServer {
    $Script:StopRequested = $true
}
