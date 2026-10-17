# ============================================================================
#  PowerShell-FSD - 70.Metar.ps1
#  METAR manager
#
#  Sources:
#    network  - relay requests to the nearest METAR capable server
#    file     - serve requests from the local metar.txt
#    download - like file, but refresh metar.txt over FTP every hour
# ============================================================================

function New-MetarManager {
    $mm = @{
        Source       = $Script:SOURCE_NETWORK
        MetarHost    = $null
        MetarDir     = $null
        FtpEmail     = $null
        PassiveMode  = $true
        Downloading  = $false
        NewFileReady = $false
        PrevDownload = [long]0
        Metarsize    = 0
        PrevHour     = -1
        StationList  = @()      # sorted list of @{ Name; LineIndex }
        MetarLines   = @()      # cached file content
        MetarFileTime = -1
        Queue        = New-Object System.Collections.ArrayList   # @{ Destination; MetarId; Fd; Parsed }
        Variation    = @(0) * $Script:VAR_AMOUNT
        Download     = $null   # synchronized state for the background FTP job
    }

    $wgroup = Get-ConfigGroup -Name 'weather'
    if ($wgroup) {
        $e = Get-ConfigEntry -Group $wgroup -Name 'source'
        if ($e) {
            if (Test-StrIEqual $e.Data 'network')      { $mm.Source = $Script:SOURCE_NETWORK }
            elseif (Test-StrIEqual $e.Data 'file')     { $mm.Source = $Script:SOURCE_FILE }
            elseif (Test-StrIEqual $e.Data 'download') { $mm.Source = $Script:SOURCE_DOWNLOAD }
            else { Write-Dolog -Level $Script:L_ERR -Message ("Unknown METAR source '{0}' in config file" -f $e.Data) }
        }
        $e = Get-ConfigEntry -Group $wgroup -Name 'server'
        if ($e) { $mm.MetarHost = $e.Data }
        $e = Get-ConfigEntry -Group $wgroup -Name 'dir'
        if ($e) { $mm.MetarDir = $e.Data }
        $e = Get-ConfigEntry -Group $wgroup -Name 'ftpmode'
        if ($e) {
            if (Test-StrIEqual $e.Data 'passive') { $mm.PassiveMode = $true }
            elseif (Test-StrIEqual $e.Data 'active') { $mm.PassiveMode = $false }
        }
    }
    $sgroup = Get-ConfigGroup -Name 'system'
    if ($sgroup) {
        $e = Get-ConfigEntry -Group $sgroup -Name 'email'
        if ($e) { $mm.FtpEmail = $e.Data }
    }
    if ($mm.Source -eq $Script:SOURCE_DOWNLOAD) {
        if (-not $mm.MetarHost) { $mm.MetarHost = 'weather.noaa.gov' }
        if (-not $mm.MetarDir)  { $mm.MetarDir  = 'data/observations/metar/cycles/' }
    }

    $var = Add-MgrVar -Name 'metar.method' -Type 'varchar'
    $method = if ($mm.Source -eq $Script:SOURCE_NETWORK) { 'network' }
              elseif ($mm.Source -eq $Script:SOURCE_FILE) { 'file' } else { 'download' }
    Set-MgrVar -Num $var -Value $method
    $Script:MetarCurrentVar  = Add-MgrVar -Name 'metar.current'  -Type 'date'
    $Script:MetarRequestsVar = Add-MgrVar -Name 'metar.requests' -Type 'int'
    $Script:MetarStationsVar = Add-MgrVar -Name 'metar.stations' -Type 'int'
    Set-MgrVar -Num $Script:MetarCurrentVar -Value ([DateTimeOffset]::Now.ToUnixTimeSeconds())

    $Script:MetarMgr = $mm

    if ($mm.Source -eq $Script:SOURCE_FILE) { Build-MetarStationList }
    return $mm
}

# ---------------------------------------------------------------------------
# Station index (buildlist): name -> line number in metar.txt
# ---------------------------------------------------------------------------

function Build-MetarStationList {
    $path = Join-Path $Script:FsdDir $Script:METARFILE
    if (-not (Test-Path -LiteralPath $path)) { return }
    $item = Get-Item -LiteralPath $path
    $Script:MetarMgr.MetarFileTime = ([DateTimeOffset]$item.LastWriteTimeUtc).ToUnixTimeSeconds()
    $Script:MetarMgr.MetarLines = [System.IO.File]::ReadAllLines($path, $Script:FsdEnc)

    $list = New-Object System.Collections.Generic.List[object]
    $lines = $Script:MetarMgr.MetarLines
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line.Length -lt 30) { continue }
        $tokens = Break-Args -S $line -Max 3
        if ($tokens.Count -lt 3) { continue }
        if ($line.Length -ge 5 -and $line.Substring(0, 5) -eq '     ') { continue }
        $statname = $null
        if ($tokens[0].Length -eq 4) { $statname = $tokens[0] }
        elseif ($tokens[1].Length -eq 4) { $statname = $tokens[1] }
        if (-not $statname) { continue }
        $list.Add(@{ Name = $statname.ToUpper($Script:Inv); LineIndex = $i })
    }
    $sorted = $list.ToArray() | Sort-Object -Property Name
    $Script:MetarMgr.StationList = @($sorted)
    Set-MgrVar -Num $Script:MetarStationsVar -Value $Script:MetarMgr.StationList.Count
}

function Test-MetarFileChanged {
    $path = Join-Path $Script:FsdDir $Script:METARFILE
    if (-not (Test-Path -LiteralPath $path)) { return }
    $item = Get-Item -LiteralPath $path
    if (([DateTimeOffset]$item.LastWriteTimeUtc).ToUnixTimeSeconds() -ne $Script:MetarMgr.MetarFileTime) {
        Build-MetarStationList
    }
}

# ---------------------------------------------------------------------------
# Queue processing (doparse)
# ---------------------------------------------------------------------------

function Find-MetarStation {
    param([string]$MetarId)
    if ($MetarId.Length -gt 4) { $MetarId = $MetarId.Substring(0, 4) }
    $key = $MetarId.ToUpper($Script:Inv)
    foreach ($s in $Script:MetarMgr.StationList) {
        if ($s.Name -ceq $key) { return $s }
    }
    return $null
}

function Read-MetarBlock {
    # read the station line plus its continuation lines
    param([int]$LineIndex)
    $lines = $Script:MetarMgr.MetarLines
    if ($LineIndex -ge $lines.Count) { return '' }
    $first = $true
    $sb = New-Object System.Text.StringBuilder
    $i = $LineIndex
    while ($i -lt $lines.Count) {
        $piece = $lines[$i].TrimEnd("`r", "`n", '=')
        $addition = ($piece.Length -ge 5 -and $piece.Substring(0, 5) -eq '     ')
        if ($addition -and $first) { break }
        if (-not $addition -and -not $first) { break }
        $first = $false
        if ($addition -and $piece.Length -ge 4) { [void]$sb.Append($piece.Substring(4)) }
        else { [void]$sb.Append($piece) }
        $i++
    }
    return $sb.ToString()
}

function Invoke-MetarQueueRun {
    while ($Script:MetarMgr.Queue.Count -gt 0) {
        $q = $Script:MetarMgr.Queue[0]
        if (-not (Invoke-MetarParse -Q $q)) { break }
    }
}

# returns $true when the request was handled (or dropped), $false to retry later
function Invoke-MetarParse {
    param($Q)
    Test-MetarFileChanged
    $station = Find-MetarStation -MetarId $Q.MetarId
    if (-not $station) {
        Invoke-SendNowx -Dest $Q.Destination -Fd $Q.Fd -Station $Q.MetarId
        $Script:MetarMgr.Queue.Remove($Q) | Out-Null
        return $true
    }
    $line = Read-MetarBlock -LineIndex $station.LineIndex
    if ($null -eq $line) { return $false }
    if ($Q.Parsed) {
        $tokens = Break-Args -S $line -Max 100
        $pr = New-WProfile -Name $station.Name -Creation 0 -Origin $null
        Import-WProfileMetar -Wp $pr -Array $tokens
        Invoke-SendWeather -Dest $Q.Destination -Fd $Q.Fd -Wp $pr
    } else {
        Invoke-SendMetar -Dest $Q.Destination -Fd $Q.Fd -Station $station.Name -Data $line
    }
    Inc-MgrVar -Num $Script:MetarRequestsVar
    $Script:MetarMgr.Queue.Remove($Q) | Out-Null
    return $true
}

# ---------------------------------------------------------------------------
# Public request entry point (requestmetar)
# ---------------------------------------------------------------------------

function Invoke-RequestMetar {
    # returns the server the request was sent to, or $null
    param([string]$Client, [string]$Metar, [int]$Parsed, [int]$Fd)

    if ($Script:MetarMgr.Source -eq $Script:SOURCE_NETWORK) {
        $best = $null; $hops = -1
        foreach ($s in $Script:RootServer) {
            if ([object]::ReferenceEquals($s, $Script:MyServer)) { continue }
            if (($s.Flags -band $Script:SERVER_METAR) -eq 0) { continue }
            if ($hops -eq -1 -or ($s.Hops -lt $hops -and $s.Hops -ne -1)) {
                $best = $s; $hops = $s.Hops
            }
        }
        if (-not $best) { return $null }
        Invoke-SendReqMetar -Client $Client -Metar $Metar -Fd $Fd -Parsed $Parsed -Dest $best
        return $best
    }
    Add-MetarQueue -Dest $Client -Metar $Metar -Parsed $Parsed -Fd $Fd
    return $Script:MyServer
}

function Add-MetarQueue {
    param([string]$Dest, [string]$Metar, [int]$Parsed, [int]$Fd)
    # an active weather profile overrides the METAR file
    $prof = Get-WProfile -Name $Metar
    if ($prof -and $prof.Active) {
        if ($Parsed) { Invoke-SendWeather -Dest $Dest -Fd $Fd -Wp $prof }
        else         { Invoke-SendMetar -Dest $Dest -Fd $Fd -Station $Metar -Data $prof.RawCode }
        return
    }
    $Script:MetarMgr.Queue.Insert(0, @{ Destination = $Dest; MetarId = $Metar; Fd = $Fd; Parsed = $Parsed })
}

# ---------------------------------------------------------------------------
# Periodic checks (check): variation reseeding + FTP download scheduling
# ---------------------------------------------------------------------------

function Invoke-MetarCheck {
    $now = [DateTimeOffset]::UtcNow
    if ($Script:MetarMgr.PrevHour -eq -1 -or
        ($Script:MetarMgr.PrevHour -ne $now.Hour -and ($now.Hour -eq 12 -or $now.Hour -eq 0))) {
        $Script:MetarMgr.PrevHour = $now.Hour
        Reset-MRand -Seed ($now.Hour * ($now.Year - 1900) * $now.Month)
        for ($x = 0; $x -lt $Script:VAR_AMOUNT; $x++) {
            $Script:MetarMgr.Variation[$x] = Get-MRand
        }
    }
    if ($Script:MetarMgr.Source -eq $Script:SOURCE_DOWNLOAD) {
        $mnow = Get-MTime
        $elapsed = $mnow - $Script:MetarMgr.PrevDownload
        if (($now.Minute -eq 10 -and $elapsed -gt 60) -or ($elapsed -gt 3600) -or $Script:MetarMgr.PrevDownload -eq 0) {
            Start-MetarDownload
        }
    }
}

function Get-MetarVariation {
    param([int]$Num, [int]$Min, [int]$Max)
    $val = $Script:MetarMgr.Variation[$Num]
    $range = $Max - $Min + 1
    $a = [Math]::Abs($val)
    return (($a % $range) + $Min)
}

# ---------------------------------------------------------------------------
# FTP download (startdownload/dodownload), executed in a background runspace
# ---------------------------------------------------------------------------

$Script:MetarDownloadScript = {
    param($Url, $TargetFile)
    try {
        $req = [System.Net.FtpWebRequest]::Create($Url)
        $req.Method = [System.Net.WebRequestMethods+Ftp]::DownloadFile
        $req.UseBinary = $true
        $req.UsePassive = $true
        $req.Timeout = 300000
        $req.ReadWriteTimeout = 300000
        $resp = $req.GetResponse()
        $stream = $resp.GetResponseStream()
        $out = New-Object System.IO.FileStream($TargetFile, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
        $buf = New-Object byte[] 65536
        while (($n = $stream.Read($buf, 0, $buf.Length)) -gt 0) { $out.Write($buf, 0, $n) }
        $out.Close(); $stream.Close(); $resp.Close()
        return @{ Ok = $true; Size = (Get-Item -LiteralPath $TargetFile).Length }
    } catch {
        return @{ Ok = $false; Error = $_.Exception.Message }
    }
}

function Start-MetarDownload {
    if ($Script:MetarMgr.Downloading) {
        Write-Dolog -Level $Script:L_ERR -Message 'METAR: server seems to be still loading'
        return
    }
    $Script:MetarMgr.PrevDownload = Get-MTime
    $hour = ([DateTimeOffset]::UtcNow.Hour + 21) % 24
    $dir = $Script:MetarMgr.MetarDir
    if ($dir) { $dir = $dir.TrimStart('/') } else { $dir = '' }
    if (-not $dir.EndsWith('/')) { $dir += '/' }
    $url = 'ftp://{0}/{1}{2:D2}Z.TXT' -f $Script:MetarMgr.MetarHost, $dir, $hour
    $target = Join-Path $Script:FsdDir $Script:METARFILENEW

    Write-Dolog -Level $Script:L_INFO -Message 'METAR: Starting download of METAR data'
    $Script:MetarMgr.Downloading = $true
    $Script:MetarMgr.NewFileReady = $false
    $Script:MetarMgr.Metarsize = 0
    $Script:MetarMgr.DownloadError = ''
    $ps = [powershell]::Create()
    $Script:MetarMgr.DownloadHandle = $ps.AddScript($Script:MetarDownloadScript).AddArgument($url).AddArgument($target).BeginInvoke()
    $Script:MetarMgr.DownloadPs = $ps
}

function Invoke-MetarDownloadPoll {
    if (-not $Script:MetarMgr.Downloading) { return }

    # timeout guard (MAXMETARDOWNLOADTIME)
    if (((Get-MTime) - $Script:MetarMgr.PrevDownload) -gt $Script:MAXMETARDOWNLOADTIME) {
        Write-Dolog -Level $Script:L_WARNING -Message 'METAR download interrupted due to timeout'
        try { if ($Script:MetarMgr.DownloadPs) { $Script:MetarMgr.DownloadPs.Stop() } } catch { }
        $Script:MetarMgr.Downloading = $false
        Start-MetarDownload
        return
    }

    if ($Script:MetarMgr.DownloadPs -and
        $Script:MetarMgr.DownloadPs.InvocationStateInfo.State -eq [System.Management.Automation.PSState]::Completed) {
        $result = $null
        try { $result = $Script:MetarMgr.DownloadPs.EndInvoke($Script:MetarMgr.DownloadHandle) } catch { }
        try { $Script:MetarMgr.DownloadPs.Dispose() } catch { }
        $Script:MetarMgr.DownloadPs = $null
        $Script:MetarMgr.Downloading = $false
        if ($result -and $result.Count -gt 0 -and $result[0].Ok) {
            $Script:MetarMgr.Metarsize = $result[0].Size
            $Script:MetarMgr.NewFileReady = $true
        } else {
            $err = if ($result -and $result.Count -gt 0) { $result[0].Error } else { 'no result' }
            Write-Dolog -Level $Script:L_ERR -Message ("METAR: Download failed: {0}" -f $err)
        }
    }
}

function Install-NewMetarFile {
    # setupnewfile()
    $Script:MetarMgr.NewFileReady = $false
    if ($Script:MetarMgr.Metarsize -lt 100000) {
        $p = Join-Path $Script:FsdDir $Script:METARFILENEW
        if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }
        Write-Dolog -Level $Script:L_WARNING -Message ("METAR: Size of new METAR file ({0}) is too small, dropping." -f $Script:MetarMgr.Metarsize)
        return
    }
    $old = Join-Path $Script:FsdDir $Script:METARFILE
    $new = Join-Path $Script:FsdDir $Script:METARFILENEW
    try {
        if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old -Force }
        Move-Item -LiteralPath $new -Destination $old -Force
        Write-Dolog -Level $Script:L_INFO -Message 'METAR: Installed new METAR data.'
    } catch {
        Write-Dolog -Level $Script:L_ERR -Message ("METAR: Can't move {0} to {1}: {2}" -f $Script:METARFILENEW, $Script:METARFILE, $_.Exception.Message)
    }
    Build-MetarStationList
    Set-MgrVar -Num $Script:MetarCurrentVar -Value ([DateTimeOffset]::Now.ToUnixTimeSeconds())
}

# run(): called from the main loop (metar manager process)
function Invoke-MetarRun {
    if ($Script:MetarMgr.Source -eq $Script:SOURCE_NETWORK) { return }
    if ($Script:MetarMgr.Downloading) { Invoke-MetarDownloadPoll }
    Invoke-MetarQueueRun
    if (-not $Script:MetarMgr.Downloading -and $Script:MetarMgr.NewFileReady) { Install-NewMetarFile }
    Invoke-MetarCheck
}
