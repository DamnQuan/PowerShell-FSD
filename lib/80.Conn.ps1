# ============================================================================
#  PowerShell-FSD - 80.Conn.ps1
#  TCP connection core: listeners, buffers, line handling, timeouts, guards
# ============================================================================

function New-FsdConn {
    param(
        [string]$Kind, [System.Net.Sockets.Socket]$Sock,
        [string]$Peer, [int]$Port, [bool]$Guard
    )
    $now = Get-MTime
    return @{
        Fd              = $Script:ConnFdSeq++
        Kind            = $Kind        # 'client' | 'server' | 'sys'
        Sock            = $Sock
        Peer            = $Peer
        Port            = $Port
        Iface           = $null
        InBuf           = ''
        OutBuf          = ''
        KillFlag        = 0
        Blocked         = $false
        Timeout         = $false
        LastActive      = $now
        LastPing        = $now
        PrevFeedCheck   = 0
        FeedCount       = 0
        Feed            = -1
        OutBufSoftLimit = -1
        Guard           = $Guard
        Prompt          = $null
        # client connection specific
        ThisClient      = $null
        # server link specific
        ThisServer      = $null
        ClientOk        = $false
        StartupTime     = $now
        # system connection specific
        Authorized      = $false
        Lat             = 0.0
        Lon             = 0.0
    }
}

function New-FsdInterface {
    # tcpinterface(): bind + listen + statistics variables
    param([string]$Kind, [int]$Port, [string]$Code, [string]$Description)
    $sock = New-Object System.Net.Sockets.Socket(
        [System.Net.Sockets.AddressFamily]::InterNetwork,
        [System.Net.Sockets.SocketType]::Stream,
        [System.Net.Sockets.ProtocolType]::Tcp)
    $sock.SetSocketOption([System.Net.Sockets.SocketOptionLevel]::Socket,
        [System.Net.Sockets.SocketOptionName]::ReuseAddress, $true)
    $sock.Bind((New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, $Port)))
    $sock.Listen(5)
    $sock.Blocking = $false

    $iface = @{
        Kind         = $Kind
        Port         = $Port
        Code         = $Code
        Description  = $Description
        Sock         = $sock
        Users        = New-Object System.Collections.ArrayList
        Guards       = New-Object System.Collections.ArrayList
        Allows       = @()          # allowed peer IPs for the server port
        Prompt       = $null
        FeedStrategy = 0
        FloodLimit   = -1
        OutBufLimit  = -1
        PrevChecks   = 0
    }
    $iface.VarCurrent = Add-MgrVar -Name "interface.$Code.current" -Type 'int'
    $iface.VarTotal   = Add-MgrVar -Name "interface.$Code.total"   -Type 'int'
    $iface.VarPeak    = Add-MgrVar -Name "interface.$Code.peak"    -Type 'int'
    $iface.VarClosed  = @{}
    $iface.VarClosed[1] = Add-MgrVar -Name "interface.$Code.command"         -Type 'int'
    $iface.VarClosed[2] = Add-MgrVar -Name "interface.$Code.flood"           -Type 'int'
    $iface.VarClosed[3] = Add-MgrVar -Name "interface.$Code.initialtimeout"  -Type 'int'
    $iface.VarClosed[4] = Add-MgrVar -Name "interface.$Code.stalled"         -Type 'int'
    $iface.VarClosed[5] = Add-MgrVar -Name "interface.$Code.closed"          -Type 'int'
    $iface.VarClosed[6] = Add-MgrVar -Name "interface.$Code.writeerr"        -Type 'int'
    $iface.VarClosed[7] = Add-MgrVar -Name "interface.$Code.killed"          -Type 'int'
    $iface.VarClosed[8] = Add-MgrVar -Name "interface.$Code.protocol"        -Type 'int'

    Write-Dolog -Level $Script:L_INFO -Message ("Booting port {0} ({1})" -f $Port, $Description)
    return $iface
}

function Set-IFPrompt {
    param($Iface, [string]$P)
    $Iface.Prompt = $P
    foreach ($u in $Iface.Users) { $u.Prompt = $P }
}

function Set-IFFlood {
    param($Iface, [int]$Limit) $Iface.FloodLimit = $Limit
}

function Set-IFFeedStrategy {
    param($Iface, [int]$Strategy) $Iface.FeedStrategy = $Strategy
}

function Set-IFOutBufLimit {
    param($Iface, [int]$Limit) $Iface.OutBufLimit = $Limit
}

# allowfrom(): resolve hostnames to IP addresses
function Add-IFAllow {
    param($Iface, [string]$Name)
    try {
        $addrs = [System.Net.Dns]::GetHostAddresses($Name)
        $v4 = $addrs | Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork } | Select-Object -First 1
        if (-not $v4) { throw 'no ipv4' }
        $Iface.Allows += $v4.IPAddressToString
    } catch {
        Write-Dolog -Level $Script:L_ERR -Message ("Server {0} unknown in allowfrom" -f $Name)
    }
}

# ---------------------------------------------------------------------------
# User insertion / removal
# ---------------------------------------------------------------------------

function Add-IFUser {
    param($Iface, $U)
    $U.Iface = $Iface
    $Iface.Users.Add($U) | Out-Null
    if ($Iface.Prompt) {
        $U.Prompt = $Iface.Prompt
        Write-Prompt $U
    }
    Inc-MgrVar -Num $Iface.VarTotal
    Inc-MgrVar -Num $Iface.VarCurrent
    $peak = (Get-MgrVar -Num $Iface.VarPeak).Value
    $nowc = (Get-MgrVar -Num $Iface.VarCurrent).Value
    if ($nowc -gt $peak) { Set-MgrVar -Num $Iface.VarPeak -Value $nowc }
}

function Write-Prompt {
    param($U)
    if (-not $U.Prompt -or $U.KillFlag -or $U.Blocked) { return }
    Send-UData -U $U -S $U.Prompt
}

function Kill-Conn {
    param($U, [int]$Reason)
    $U.KillFlag = $Reason
}

function Remove-IFUser {
    param($Iface, $U)

    # Derived destructor first (C++ destruction order)
    switch ($U.Kind) {
        'client' { Remove-ClientConn -U $U }
        'server' { Remove-ServerConn -U $U }
        'sys'    { }
    }

    # ~absuser()
    Write-Dolog -Level $Script:L_INFO -Message ("client from {0} removed from {1}:{2}" -f `
        $U.Peer, $Iface.Description, $Script:KillReasons[$U.KillFlag])
    if ($U.KillFlag -ge 1 -and $U.KillFlag -le 8) {
        Inc-MgrVar -Num $Iface.VarClosed[$U.KillFlag]
    }
    if ($U.KillFlag -ne $Script:KILL_CLOSED -and $U.KillFlag -ne $Script:KILL_WRITEERR) {
        # final best effort flush of pending output
        if ($U.OutBuf) {
            try {
                $bytes = $Script:FsdEnc.GetBytes($U.OutBuf)
                [void]$U.Sock.Send($bytes, 0, $bytes.Length, [System.Net.Sockets.SocketFlags]::None)
            } catch { }
        }
    }
    if ($U.KillFlag -ne $Script:KILL_COMMAND -and $U.Guard) {
        Add-IFGuard -Iface $Iface -Host $U.Peer -Port $U.Port
    }
    try { $U.Sock.Close() } catch { }
    $Iface.Users.Remove($U) | Out-Null
    Dec-MgrVar -Num $Iface.VarCurrent
}

# ---------------------------------------------------------------------------
# Low level I/O
# ---------------------------------------------------------------------------

function Read-Conn {
    param($U)
    if (-not $U.Sock.Poll(0, [System.Net.Sockets.SelectMode]::SelectRead)) { return }
    $buf = New-Object byte[] 1024
    $n = 0
    try {
        $n = $U.Sock.Receive($buf, 0, $buf.Length, [System.Net.Sockets.SocketFlags]::None)
    } catch [System.Net.Sockets.SocketException] {
        if ($_.Exception.SocketErrorCode -eq [System.Net.Sockets.SocketError]::WouldBlock) { return }
        Kill-Conn -U $U -Reason $Script:KILL_CLOSED
        return
    } catch {
        Kill-Conn -U $U -Reason $Script:KILL_CLOSED
        return
    }
    if ($n -le 0) {
        Kill-Conn -U $U -Reason $Script:KILL_CLOSED
        return
    }
    if ($U.Iface.FeedStrategy -band $Script:FEED_IN) { $U.FeedCount += $n }
    $U.InBuf += $Script:FsdEnc.GetString($buf, 0, $n)
}

function Write-ConnFlush {
    # output(): write up to 2048 bytes from the output buffer when writable
    param($U)
    if (-not $U.OutBuf) { return }
    if (-not $U.Sock.Poll(0, [System.Net.Sockets.SelectMode]::SelectWrite)) { return }
    $bytes = $Script:FsdEnc.GetBytes($U.OutBuf)
    $max = [Math]::Min(2048, $bytes.Length)
    $n = 0
    try {
        $n = $U.Sock.Send($bytes, 0, $max, [System.Net.Sockets.SocketFlags]::None)
    } catch [System.Net.Sockets.SocketException] {
        if ($_.Exception.SocketErrorCode -eq [System.Net.Sockets.SocketError]::WouldBlock) { return }
        Kill-Conn -U $U -Reason $Script:KILL_WRITEERR
        return
    } catch {
        Kill-Conn -U $U -Reason $Script:KILL_WRITEERR
        return
    }
    if ($n -gt 0) {
        if ($U.Iface.FeedStrategy -band $Script:FEED_OUT) { $U.FeedCount += $n }
        if ($n -ge $U.OutBuf.Length) { $U.OutBuf = '' }
        else { $U.OutBuf = $U.OutBuf.Substring($n) }
    }
}

function Send-UData {
    # absuser::send(): write immediately when the output buffer is empty
    param($U, [string]$S)
    if ($U.KillFlag) { return }
    if ($U.OutBuf) {
        $U.OutBuf += $S
        return
    }
    $bytes = $Script:FsdEnc.GetBytes($S)
    $max = [Math]::Min(2048, $bytes.Length)
    $n = 0
    try {
        $n = $U.Sock.Send($bytes, 0, $max, [System.Net.Sockets.SocketFlags]::None)
    } catch [System.Net.Sockets.SocketException] {
        if ($_.Exception.SocketErrorCode -ne [System.Net.Sockets.SocketError]::WouldBlock) {
            Kill-Conn -U $U -Reason $Script:KILL_WRITEERR
            return
        }
        $n = 0
    } catch {
        Kill-Conn -U $U -Reason $Script:KILL_WRITEERR
        return
    }
    if ($U.Iface.FeedStrategy -band $Script:FEED_OUT) { $U.FeedCount += $n }
    if ($bytes.Length - $n -gt 0) {
        $U.OutBuf += $S.Substring($n)
    }
}

function Send-UsL {
    # uslprintf(): send with the output buffer soft limit check
    param($U, [string]$S, [bool]$Check)
    if ($U.KillFlag) { return }
    if ($Check -and $U.OutBufSoftLimit -ne -1 -and
        (($S.Length + $U.OutBuf.Length) -gt $U.OutBufSoftLimit)) { return }
    Send-UData -U $U -S $S
}

# ---------------------------------------------------------------------------
# Line handling (nextline / absuser::run)
# ---------------------------------------------------------------------------

function Take-Line {
    # Extracts the next complete line from the input buffer.
    # Returns the line, '' for a consumed empty/too long line, $null when the
    # buffer holds no complete line.
    param([ref]$Buf)
    $s = $Buf.Value
    $i = $s.IndexOfAny([char[]]@("`r", "`n"))
    if ($i -lt 0) { return $null }
    $line = $s.Substring(0, $i)
    $j = $i
    while ($j -lt $s.Length -and ($s[$j] -eq "`r" -or $s[$j] -eq "`n")) { $j++ }
    $Buf.Value = $s.Substring($j)
    if ($line.Length -ge $Script:MAXLINELENGTH) { return '' }
    return $line
}

function Invoke-ConnRun {
    param($Iface, $U)
    if ($U.Blocked) { return $false }
    $count = 0
    $ok = $false
    $busy = $true
    $buf = $U.InBuf
    while ($count -lt 60) {
        $line = Take-Line ([ref]$buf)
        if ($null -eq $line -or $line -eq '') { $busy = $false; break }
        $count++
        if ($Iface.FloodLimit -ge 0 -and $U.Feed -gt $Iface.FloodLimit) {
            Kill-Conn -U $U -Reason $Script:KILL_FLOOD
        }
        Invoke-ConnParse -U $U -Line $line
        $ok = $true
        if ($U.Blocked) { break }
    }
    $U.InBuf = $buf
    if ($ok -and -not $busy) { Write-Prompt -U $U }
    return $busy
}

# ---------------------------------------------------------------------------
# Feed calculation (calcfeed)
# ---------------------------------------------------------------------------

function Update-ConnFeed {
    param($U)
    $now = Get-MTime
    $elapsed = $now - $U.PrevFeedCheck
    if ($elapsed -le 0) { $elapsed = 1 }
    $fact1 = $elapsed / 300.0
    $fact2 = 1.0 - $fact1
    $newfeed = [int]($U.FeedCount / $elapsed)
    if ($U.Feed -eq -1) { $U.Feed = $newfeed }
    else { $U.Feed = [int](($newfeed * $fact1) + ($U.Feed * $fact2)) }
    $U.FeedCount = 0
    $U.PrevFeedCheck = $now
    $bandwith = $U.Feed
    if ($U.Iface.FeedStrategy -eq $Script:FEED_BOTH) { $bandwith = [int]($bandwith / 2) }
    if ($bandwith -gt 50) { $U.OutBufSoftLimit = $bandwith * 30 }
}

# ---------------------------------------------------------------------------
# Per second connection checks (tcpinterface::dochecks)
# ---------------------------------------------------------------------------

function Invoke-IFChecks {
    param($Iface)
    $now = Get-MTime
    foreach ($u in $Iface.Users.ToArray()) {
        if ($u.KillFlag) { continue }
        if ($u.Timeout) {
            Kill-Conn -U $u -Reason $Script:KILL_DATATIMEOUT
            continue
        }
        if ($Iface.FeedStrategy -and (($now - $u.PrevFeedCheck) -ge $Script:USERFEEDCHECK)) {
            Update-ConnFeed -U $u
        }
        if (($now - $u.LastPing) -ge $Script:USERPINGTIMEOUT) {
            # sendping(): no-op in the original for all user classes
            $u.LastPing = $now
        } elseif (($now - $u.LastActive) -ge $Script:USERTIMEOUT) {
            Send-UData -U $u -S "# Timeout`r`n"
            $u.Timeout = $true
        }
    }
    foreach ($g in $Iface.Guards.ToArray()) {
        if (($now - $g.PrevTry) -gt $Script:GUARDRETRY) {
            $g.PrevTry = $now
            if ((Add-IFOutgoing -Iface $Iface -Name $g.Host -Port $g.Port -Terminal $null) -ne 0) {
                $Iface.Guards.Remove($g) | Out-Null
            }
        }
    }
}

function Add-IFGuard {
    # NOTE: the parameter must not be named $Host - that is a read only
    # automatic variable in PowerShell.
    param($Iface, [string]$PeerHost, [int]$Port)
    $Iface.Guards.Add(@{ Host = $PeerHost; Port = $Port; PrevTry = (Get-MTime) }) | Out-Null
}

function Clear-IFGuards {
    param($Iface)
    $Iface.Guards.Clear()
}

# ---------------------------------------------------------------------------
# Incoming connections
# ---------------------------------------------------------------------------

function Accept-IFUsers {
    param($Iface)
    while ($true) {
        try { $c = $Iface.Sock.Accept() }
        catch { break }
        $peer = $c.RemoteEndPoint.Address.IPAddressToString
        $rport = $c.RemoteEndPoint.Port
        if ($Iface.Allows.Count -gt 0 -and ($Iface.Allows -notcontains $peer)) {
            try {
                $msg = $Script:FsdEnc.GetBytes("#You are not allowed on this port.`r`n")
                [void]$c.Send($msg)
            } catch { }
            Write-Dolog -Level $Script:L_INFO -Message ("Connection rejected from {0}" -f $peer)
            try { $c.Close() } catch { }
            continue
        }
        Write-Dolog -Level $Script:L_INFO -Message ("Connection accepted from {0} on {1}" -f $peer, $Iface.Description)
        $c.NoDelay = $true
        $c.Blocking = $false
        $u = New-FsdConn -Kind $Iface.Kind -Sock $c -Peer $peer -Port $rport -Guard $false
        switch ($Iface.Kind) {
            'client' { Initialize-ClientConn -U $u }
            'server' { Initialize-ServerConn -U $u }
            'sys'    { Initialize-SysConn -U $u }
        }
        Add-IFUser -Iface $Iface -U $u
    }
}

# ---------------------------------------------------------------------------
# Outgoing connections (tcpinterface::adduser) + guard management
# ---------------------------------------------------------------------------

function Add-IFOutgoing {
    param($Iface, [string]$Name, [int]$Port, $Terminal)
    foreach ($u in $Iface.Users) {
        if ($u.Port -eq $Port -and (Test-StrIEqual $u.Peer $Name)) {
            if ($Terminal) { Send-UData -U $Terminal -S "Already connected to $Name`r`n" }
            return -1
        }
    }
    $addr = $null
    try {
        $addrs = [System.Net.Dns]::GetHostAddresses($Name)
        $addr = $addrs | Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork } | Select-Object -First 1
    } catch { }
    if (-not $addr) {
        if ($Terminal) { Send-UData -U $Terminal -S "Unknown hostname: $Name`r`n" }
        return 0
    }
    if ($Terminal) { Send-UData -U $Terminal -S "Connecting to $Name port $Port.`r`n" }

    $sock = New-Object System.Net.Sockets.Socket(
        [System.Net.Sockets.AddressFamily]::InterNetwork,
        [System.Net.Sockets.SocketType]::Stream,
        [System.Net.Sockets.ProtocolType]::Tcp)
    $ep = New-Object System.Net.IPEndPoint($addr, $Port)
    $connected = $false
    $errText = ''
    try {
        $iar = $sock.BeginConnect($ep, $null, $null)
        if ($iar.AsyncWaitHandle.WaitOne(3000)) { $sock.EndConnect($iar); $connected = $true }
        else { $errText = 'Connection timed out' }
    } catch { $errText = $_.Exception.Message }
    if (-not $connected) {
        if ($Terminal) { Send-UData -U $Terminal -S "Could not connect to server: $errText`r`n" }
        try { $sock.Close() } catch { }
        return 0
    }
    if ($Terminal) { Send-UData -U $Terminal -S "Connection established.`r`n" }
    $sock.NoDelay = $true
    $sock.Blocking = $false
    $u = New-FsdConn -Kind $Iface.Kind -Sock $sock -Peer $Name -Port $Port -Guard $true
    switch ($Iface.Kind) {
        'client' { Initialize-ClientConn -U $u }
        'server' { Initialize-ServerConn -U $u }
        'sys'    { Initialize-SysConn -U $u }
    }
    Add-IFUser -Iface $Iface -U $u
    return 1
}

# ---------------------------------------------------------------------------
# Interface run (tcpinterface::run)
# ---------------------------------------------------------------------------

function Invoke-IFRunCore {
    param($Iface)
    if ($Iface.Sock.Poll(0, [System.Net.Sockets.SelectMode]::SelectRead)) {
        Accept-IFUsers -Iface $Iface
    }
    $busy = $false
    foreach ($u in $Iface.Users.ToArray()) {
        if ($u.KillFlag -ne 0) {
            Remove-IFUser -Iface $Iface -U $u
            continue
        }
        Write-ConnFlush -U $u
        if ($u.KillFlag -ne 0) { continue }
        Read-Conn -U $u
        if ($u.KillFlag -ne 0) { continue }
        if (Invoke-ConnRun -Iface $Iface -U $u) { $busy = $true }
    }
    $now = Get-MTime
    if ($Iface.PrevChecks -ne $now) {
        $Iface.PrevChecks = $now
        Invoke-IFChecks -Iface $Iface
    }
    return $busy
}

# Parse dispatch, implemented by the interface modules
function Invoke-ConnParse {
    param($U, [string]$Line)
    switch ($U.Kind) {
        'client' { Invoke-ClientParse -U $U -Line $Line }
        'server' { Invoke-ServerParse -U $U -Line $Line }
        'sys'    { Invoke-SysParse -U $U -Line $Line }
    }
}
