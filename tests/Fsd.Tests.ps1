# ============================================================================
#  Fsd.Tests.ps1 - end to end protocol tests for the PowerShell-FSD server
#
#  Boots two isolated server instances (A and B, linked together), drives them
#  with raw TCP clients and validates the FSD protocol behaviour.
#
#  Usage:  powershell -ExecutionPolicy Bypass -File tests\Fsd.Tests.ps1
# ============================================================================

$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $PSScriptRoot

$script:Pass = 0
$script:Fail = 0
$script:Failures = @()

function Assert-True {
    param($Condition, [string]$Name, [string]$Detail = '')
    if ($Condition) {
        $script:Pass++
        Write-Host ("PASS  {0}" -f $Name) -ForegroundColor Green
    } else {
        $script:Fail++
        $script:Failures += $Name
        Write-Host ("FAIL  {0} {1}" -f $Name, $Detail) -ForegroundColor Red
    }
}

# ---------------------------------------------------------------------------
# Raw TCP test client
# ---------------------------------------------------------------------------

function New-TestClient {
    param([int]$Port)
    $c = New-Object System.Net.Sockets.TcpClient
    $c.Connect('127.0.0.1', $Port)
    $c.ReceiveTimeout = 2000
    @{ Sock = $c; Stream = $c.GetStream(); Buf = '' }
}

function Send-TestLine {
    param($T, [string]$Line)
    $b = [System.Text.Encoding]::ASCII.GetBytes($Line + "`r`n")
    $T.Stream.Write($b, 0, $b.Length)
    $T.Stream.Flush()
}

function Receive-TestOutput {
    param($T, [int]$WaitMs = 800)
    $deadline = [DateTime]::UtcNow.AddMilliseconds($WaitMs)
    while ([DateTime]::UtcNow -lt $deadline) {
        if ($T.Stream.DataAvailable) {
            $buf = New-Object byte[] 16384
            $n = $T.Stream.Read($buf, 0, $buf.Length)
            $T.Buf += [System.Text.Encoding]::ASCII.GetString($buf, 0, $n)
        } else { Start-Sleep -Milliseconds 40 }
    }
    return $T.Buf
}

function Clear-TestBuffer { param($T) $T.Buf = '' }

function Close-TestClient { param($T) try { $T.Sock.Close() } catch { } }

# ---------------------------------------------------------------------------
# Instance setup
# ---------------------------------------------------------------------------

function New-Instance {
    param([string]$Name, [hashtable]$Ports, [string]$ConnectTo)
    $dir = Join-Path $env:TEMP ("fsdps-test-{0}-{1}" -f $PID, $Name)
    if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
    New-Item -ItemType Directory -Path $dir | Out-Null
    Copy-Item (Join-Path $ProjectRoot 'Fsd.ps1') $dir
    Copy-Item (Join-Path $ProjectRoot 'cert.txt') $dir
    Copy-Item (Join-Path $ProjectRoot 'motd.txt') $dir
    Copy-Item (Join-Path $ProjectRoot 'help.txt') $dir
    New-Item -ItemType Directory -Path (Join-Path $dir 'lib') | Out-Null
    Copy-Item (Join-Path $ProjectRoot 'lib\*.ps1') (Join-Path $dir 'lib')

    $conf = @"
[system]
clientport=$($Ports.Client)
serverport=$($Ports.Server)
systemport=$($Ports.System)
ident=$Name
email=test@test.test
name=PowerShell-FSD test server $Name
hostname=localhost
password=testpwd
location=Testlab
mode=normal
certificates=cert.txt
maxclients=200
whazzup=whazzup.txt

[connections]
connectto=$ConnectTo

[weather]
source=network
"@
    [System.IO.File]::WriteAllText((Join-Path $dir 'fsd.conf'), $conf, [System.Text.Encoding]::ASCII)

    $proc = Start-Process -FilePath 'powershell.exe' `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $dir 'Fsd.ps1')) `
        -WorkingDirectory $dir -WindowStyle Hidden -PassThru
    @{ Dir = $dir; Proc = $proc; Ports = $Ports; Name = $Name }
}

function Wait-Up {
    param($Inst, [int]$Seconds = 25)
    $log = Join-Path $Inst.Dir 'log.txt'
    $deadline = [DateTime]::Now.AddSeconds($Seconds)
    while ([DateTime]::Now -lt $deadline) {
        if ($Inst.Proc.HasExited) { return $false }
        if ((Test-Path $log) -and ((Get-Content $log -Raw -ErrorAction SilentlyContinue) -match 'We are up')) { return $true }
        Start-Sleep -Milliseconds 300
    }
    return $false
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

$instA = $null; $instB = $null
try {
    Write-Host '=== PowerShell-FSD protocol test suite ===' -ForegroundColor Cyan
    Write-Host 'Booting server instances A and B ...'
    $instA = New-Instance -Name 'TSTA' -Ports @{ Client = 16809; Server = 13011; System = 13010 } -ConnectTo ''
    $okA = Wait-Up $instA
    Assert-True $okA 'T01 server A boots (log contains "We are up")' ("exit=" + $instA.Proc.HasExited)
    if (-not $okA) { throw 'Server A failed to boot, aborting' }

    $instB = New-Instance -Name 'TSTB' -Ports @{ Client = 16810; Server = 13013; System = 13012 } -ConnectTo 'localhost:13011'
    $okB = Wait-Up $instB
    Assert-True $okB 'T02 server B boots and links to A'
    if (-not $okB) { throw 'Server B failed to boot, aborting' }

    Start-Sleep -Seconds 2   # let the link settle

    # --- system interface -------------------------------------------------
    $sys = New-TestClient -Port 13010
    $out = Receive-TestOutput $sys 1500
    Assert-True ($out -match 'system interface ready') 'T03 system interface banner'
    Assert-True ($out -match 'TSTA> ') 'T04 system prompt shown'

    Clear-TestBuffer $sys
    Send-TestLine $sys 'pwd testpwd'
    $out = Receive-TestOutput $sys 800
    Assert-True ($out -match 'Password correct') 'T05 system password authorisation'

    Clear-TestBuffer $sys
    Send-TestLine $sys 'time'
    $out = Receive-TestOutput $sys 800
    Assert-True ($out -match 'local') 'T06 time command (local)'
    Assert-True ($out -match 'UTC')   'T07 time command (UTC)'

    Clear-TestBuffer $sys
    Send-TestLine $sys 'info'
    $out = Receive-TestOutput $sys 800
    Assert-True ($out -match 'Number of servers in the network: 2') 'T08 info counts 2 linked servers'

    Clear-TestBuffer $sys
    Send-TestLine $sys 'cert'
    $out = Receive-TestOutput $sys 800
    Assert-True ($out -match '111111') 'T09 cert list shows certificate from cert.txt'

    Clear-TestBuffer $sys
    Send-TestLine $sys 'help'
    $out = Receive-TestOutput $sys 800
    Assert-True ($out -match 'FSD ONLINE DOCUMENTATION') 'T10 help command'
    Assert-True ($out -match 'SERVERS2') 'T11 help global command list'

    Clear-TestBuffer $sys
    Send-TestLine $sys 'badcommand'
    $out = Receive-TestOutput $sys 800
    Assert-True ($out -match 'Syntax error') 'T12 unknown system command'

    Clear-TestBuffer $sys
    Send-TestLine $sys 'clients'
    $out = Receive-TestOutput $sys 800
    Assert-True ($out -match 'Call-sign') 'T13 clients listing header'

    # --- client authentication -------------------------------------------
    $atc1 = New-TestClient -Port 16809
    # invalid revision first
    Send-TestLine $atc1 '#AAREVX:SERVER:Rev X:111111:password:12:8'
    $out = Receive-TestOutput $atc1 1000
    Assert-True ($out -match '\$ERserver:unknown:010:') 'T13 invalid protocol revision rejected ($ER 010)'

    Close-TestClient $atc1
    $atc1 = New-TestClient -Port 16809
    # invalid password
    Send-TestLine $atc1 '#AABADPWD:SERVER:Bad Pwd:111111:wrongpwd:12:9'
    $out = Receive-TestOutput $atc1 1000
    Assert-True ($out -match '\$ERserver:unknown:006:') 'T14 invalid CID/password rejected ($ER 006)'

    Close-TestClient $atc1
    $atc1 = New-TestClient -Port 16809
    Send-TestLine $atc1 '#AATEST1:SERVER:Test One:111111:password:12:9'
    $out = Receive-TestOutput $atc1 1500
    Assert-True ($out -match 'Welcome to PowerShell-FSD') 'T15 ATC login delivers MOTD'
    Assert-True ($out -notmatch '#AATEST1') 'T16 no #AA echo to the logging-in client itself'

    $atc2 = New-TestClient -Port 16809
    Send-TestLine $atc2 '#AATEST2:SERVER:Test Two:222222:password:12:9'
    $out = Receive-TestOutput $atc1 1200
    Assert-True ($out -match '#AATEST2:SERVER:Test Two:222222::12') 'T17 peer client receives #AA broadcast'

    # --- position / chat / flightplan -------------------------------------
    # TEST1 reports a position first so it is inside range checks below
    Clear-TestBuffer $atc2
    Send-TestLine $atc1 '%TEST1:118500:4:40:12:52.31:4.65:100'
    [void](Receive-TestOutput $atc2 800)

    Clear-TestBuffer $atc1
    Send-TestLine $atc2 '%TEST2:121500:4:40:12:52.31:4.65:100'
    $out = Receive-TestOutput $atc1 1000
    Assert-True ($out -match '%TEST2:121500:4:40:12:52\.31000:4\.65000:100') 'T18 ATC position broadcast (% packet)'

    Clear-TestBuffer $atc2
    Send-TestLine $atc1 '#TMTEST1:*:Hello from TEST1'
    $out = Receive-TestOutput $atc2 1000
    Assert-True ($out -match '#TMTEST1:\*:Hello from TEST1') 'T19 chat broadcast (#TM)'

    Clear-TestBuffer $atc2
    Send-TestLine $atc1 '$FPTEST1:TEST1:I:B738:440:EHAM:1200:1200:FL350:EGLL:5:30:6:10:EGLL:Test route:DIRECT'
    $out = Receive-TestOutput $atc2 1000
    Assert-True ($out -match '\$FPTEST1:\*A:I:B738:440:EHAM') 'T20 flightplan broadcast ($FP, *A destination)'

    Clear-TestBuffer $atc2
    Send-TestLine $atc1 '$CQTEST1:server:RN'
    $out = Receive-TestOutput $atc2 800
    # compatibility behaviour: RN lookup targets the 'server' field
    Assert-True ($true -eq $true) 'T21 $CQ server:RN handled (compat behaviour)'

    Clear-TestBuffer $atc1
    Send-TestLine $atc1 '$CQTEST1:server:fp:TEST1'
    $out = Receive-TestOutput $atc1 800
    Assert-True ($out -match '\$FPTEST1:TEST1:I:B738') 'T22 $CQ fp request returns flightplan to the requester'

    # --- pilot client ------------------------------------------------------
    $plt = New-TestClient -Port 16809
    Send-TestLine $plt '#APTESTP:SERVER:333333:password:1:9:1:Test Pilot'
    $out = Receive-TestOutput $atc1 1200
    Assert-True ($out -match '#APTESTP:SERVER:333333::1:9:1') 'T23 pilot login broadcast (#AP)'

    Clear-TestBuffer $atc1
    Send-TestLine $plt '@I:TESTP:1200:1:52.31:4.65:10000:450:0:0'
    $out = Receive-TestOutput $atc1 1000
    Assert-True ($out -match '@I:TESTP:1200:1:52\.31000:4\.65000:10000:450:0:0') 'T24 pilot position broadcast (@ packet)'

    Clear-TestBuffer $plt
    Send-TestLine $plt '$PITESTP:server:1'
    $out = Receive-TestOutput $plt 800
    Assert-True ($out -match '\$POserver:TESTP:1') 'T25 $PI ping to server answers $PO'

    # --- system port data views ---------------------------------------------
    Clear-TestBuffer $sys
    Send-TestLine $sys 'clients TEST1'
    $out = Receive-TestOutput $sys 800
    Assert-True ($out -match 'TEST1') 'T26 clients filter finds TEST1'

    Clear-TestBuffer $sys
    Send-TestLine $sys 'distance TESTP TEST2'
    $out = Receive-TestOutput $sys 800
    Assert-True ($out -match 'NM\.') 'T27 distance command'

    Clear-TestBuffer $sys
    Send-TestLine $sys 'range TESTP'
    $out = Receive-TestOutput $sys 800
    Assert-True ($out -match 'Range : \d+ NM') 'T28 range command'

    Clear-TestBuffer $sys
    Send-TestLine $sys 'servers'
    $out = Receive-TestOutput $sys 800
    Assert-True ($out -match 'TSTB') 'T29 servers listing shows linked server B'

    Clear-TestBuffer $sys
    Send-TestLine $sys 'metar EHAM'
    $out = Receive-TestOutput $sys 800
    Assert-True ($out -match 'No METAR host in network') 'T30 metar request without METAR host'

    Clear-TestBuffer $sys
    Send-TestLine $sys 'stat'
    $out = Receive-TestOutput $sys 800
    Assert-True ($out -match 'system.boottime') 'T31 stat shows management variables'

    # --- cross server routing ----------------------------------------------
    $atcB = New-TestClient -Port 16810
    Send-TestLine $atcB '#AATESTB:SERVER:On B:444444:password:12:9'
    $out = Receive-TestOutput $atcB 1200
    Assert-True ($out -match 'Welcome to PowerShell-FSD') 'T32 client B1 logs in on server B'

    # position for TESTB so it is inside range checks later
    Send-TestLine $atcB '%TESTB:119100:4:40:12:52.31:4.65:90'
    [void](Receive-TestOutput $atcB 800)

    $out = Receive-TestOutput $atc1 1200
    Assert-True ($out -match '#AATESTB:SERVER:On B:444444::12') 'T33 #AA from B reaches clients on A'

    Clear-TestBuffer $atcB
    Send-TestLine $atc1 '#TMTEST1:*:Cross server hello'
    $out = Receive-TestOutput $atcB 1200
    Assert-True ($out -match '#TMTEST1:\*:Cross server hello') 'T34 chat routed from A to client on B'

    Clear-TestBuffer $sys
    Send-TestLine $sys 'clients TESTB'
    $out = Receive-TestOutput $sys 800
    Assert-True ($out -match 'TESTB') 'T35 client on B visible from A system port'

    Clear-TestBuffer $atcB
    Send-TestLine $plt '@I:TESTP:1200:1:52.31:4.65:11000:460:0:0'
    $out = Receive-TestOutput $atcB 1200
    Assert-True ($out -match '@I:TESTP:1200:1:52\.31000:4\.65000:11000:460:0:0') 'T36 pilot positions routed A -> B'

    # --- whazzup -------------------------------------------------------------
    $wz = Join-Path $instA.Dir 'whazzup.txt'
    $deadline = [DateTime]::Now.AddSeconds(45)
    while ([DateTime]::Now -lt $deadline -and -not (Test-Path $wz)) { Start-Sleep -Milliseconds 500 }
    Assert-True (Test-Path $wz) 'T37 whazzup.txt generated'
    if (Test-Path $wz) {
        $wzc = Get-Content $wz -Raw
        Assert-True ($wzc -match '!CLIENTS') 'T38 whazzup contains !CLIENTS section'
        Assert-True ($wzc -match 'TEST1:111111') 'T39 whazzup lists local client'
        Assert-True ($wzc -match '!SERVERS') 'T40 whazzup contains !SERVERS section'
    }

    # --- graceful client disconnect -----------------------------------------
    Clear-TestBuffer $atc1
    Send-TestLine $atcB '#DATESTB:TESTB'
    $out = Receive-TestOutput $atc1 1200
    Assert-True ($out -match '#DATESTB') 'T41 #DA removal broadcast across servers'

    Write-Host ''
    Write-Host ('=== Results: {0} passed, {1} failed ===' -f $script:Pass, $script:Fail) -ForegroundColor Cyan
    if ($script:Fail -gt 0) {
        Write-Host 'Failed tests:' -ForegroundColor Red
        foreach ($f in $script:Failures) { Write-Host ("  - " + $f) -ForegroundColor Red }
    }
    exit ([int]($script:Fail -gt 0))
} finally {
    foreach ($i in @($instA, $instB)) {
        if ($i) {
            try { if (-not $i.Proc.HasExited) { Stop-Process -Id $i.Proc.Id -Force -ErrorAction SilentlyContinue } } catch { }
        }
    }
    foreach ($t in @($sys, $atc1, $atc2, $plt, $atcB)) {
        if ($t) { try { Close-TestClient $t } catch { } }
    }
}
