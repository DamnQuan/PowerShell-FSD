# ============================================================================
#  PowerShell-FSD  -  a Flight Server Daemon implemented in pure PowerShell
#  00.Const.ps1 - Global constants, protocol tables and shared state
# ============================================================================

# --- Product identity -------------------------------------------------------
$Script:PRODUCT        = 'PowerShell-FSD V1.0'
$Script:VERSION        = 'V1.0'
$Script:NEEDREVISION   = 9

# --- File locations (from fsdpaths.h) ---------------------------------------
$Script:PATH_FSD_CONF  = 'fsd.conf'
$Script:PATH_FSD_HELP  = 'help.txt'
$Script:PATH_FSD_MOTD  = 'motd.txt'
$Script:LOGFILE        = 'log.txt'
$Script:METARFILE      = 'metar.txt'
$Script:METARFILENEW   = 'metarnew.txt'

# --- Timeouts and limits (from global.h) ------------------------------------
$Script:USERTIMEOUT          = 500
$Script:SERVERTIMEOUT        = 800
$Script:CLIENTTIMEOUT        = 800
$Script:SILENTCLIENTTIMEOUT  = 36000
$Script:WINDDELTATIMEOUT     = 70

$Script:USERPINGTIMEOUT      = 200
$Script:USERFEEDCHECK        = 3
$Script:LAGCHECK             = 60
$Script:NOTIFYCHECK          = 300
$Script:SYNCTIMEOUT          = 120
$Script:SERVERMAXTOOK        = 240
$Script:MAXHOPS              = 10
$Script:GUARDRETRY           = 120
$Script:CALLSIGNBYTES        = 12
$Script:MAXLINELENGTH        = 512
$Script:MAXMETARDOWNLOADTIME = 900
$Script:CERTFILECHECK        = 120
$Script:WHAZZUPCHECK         = 30
$Script:CONFIGINTERVAL       = 10
$Script:MAXSPACE             = 1000000
$Script:MAXLOG               = 50

# --- Pilot / controller rating levels ---------------------------------------
$Script:LEV_SUSPENDED     = 0
$Script:LEV_OBSPILOT      = 1
$Script:LEV_STUDENT1      = 2
$Script:LEV_STUDENT2      = 3
$Script:LEV_STUDENT3      = 4
$Script:LEV_CONTROLLER1   = 5
$Script:LEV_CONTROLLER2   = 6
$Script:LEV_CONTROLLER3   = 7
$Script:LEV_INSTRUCTOR1   = 8
$Script:LEV_INSTRUCTOR2   = 9
$Script:LEV_INSTRUCTOR3   = 10
$Script:LEV_SUPERVISOR    = 11
$Script:LEV_ADMINISTRATOR = 12
$Script:LEV_MAX           = 12

$Script:CertLevels = @(
    'SUSPENDED','OBSPILOT','STUDENT1','STUDENT2','STUDENT3',
    'CONTROLLER1','CONTROLLER2','CONTROLLER3','INSTRUCTOR1',
    'INSTRUCTOR2','INSTRUCTOR3','SUPERVISOR','ADMINISTRATOR'
)

# --- Log levels (syslog style, from support.h) ------------------------------
$Script:L_EMERG   = 0
$Script:L_ALERT   = 1
$Script:L_CRIT    = 2
$Script:L_ERR     = 3
$Script:L_WARNING = 4
$Script:L_INFO    = 5
$Script:L_DEBUG   = 6
$Script:L_MAX     = 7

# --- Kill reasons (from interface.cpp) --------------------------------------
$Script:KILL_NONE         = 0
$Script:KILL_COMMAND      = 1
$Script:KILL_FLOOD        = 2
$Script:KILL_INITTIMEOUT  = 3
$Script:KILL_DATATIMEOUT  = 4
$Script:KILL_CLOSED       = 5
$Script:KILL_WRITEERR     = 6
$Script:KILL_KILL         = 7
$Script:KILL_PROTOCOL     = 8

$Script:KillReasons = @(
    '',
    'closed on command',
    'flooding',
    'initial timeout',
    'socket stalled',
    'connection closed',
    'write error',
    'killed on command',
    'protocol revision error'
)

# --- Feed strategies --------------------------------------------------------
$Script:FEED_IN   = 1
$Script:FEED_OUT  = 2
$Script:FEED_BOTH = 3

# --- Server flags -----------------------------------------------------------
$Script:SERVER_METAR  = 1
$Script:SERVER_SILENT = 2

# --- Client types -----------------------------------------------------------
$Script:CLIENT_PILOT = 1
$Script:CLIENT_ATC   = 2
$Script:CLIENT_ALL   = 3

# --- Inter-server commands (protocol.h / servuser.cpp) ----------------------
$Script:CMD_NOTIFY    = 0
$Script:CMD_REQMETAR  = 1
$Script:CMD_PING      = 2
$Script:CMD_PONG      = 3
$Script:CMD_SYNC      = 4
$Script:CMD_LINKDOWN  = 5
$Script:CMD_NOWX      = 6
$Script:CMD_ADDCLIENT = 7
$Script:CMD_RMCLIENT  = 8
$Script:CMD_PLAN      = 9
$Script:CMD_PD        = 10
$Script:CMD_AD        = 11
$Script:CMD_CERT      = 12
$Script:CMD_MULTIC    = 13
$Script:CMD_WEATHER   = 14
$Script:CMD_METAR     = 15
$Script:CMD_ADDWPROF  = 16
$Script:CMD_DELWPROF  = 17
$Script:CMD_KILL      = 18
$Script:CMD_RESET     = 19

# NOTE: the ADDCERT spelling of the CMD_CERT packet name is part of the
# classic FSD wire protocol and must stay as-is for interoperability.
$Script:CmdNames = @(
    'NOTIFY','REQMETAR','PING','PONG','SYNC','LINKDOWN','NOWX',
    'ADDCLIENT','RMCLIENT','PLAN','PD','AD','ADDCERT','MC','WX','METAR',
    'AWPROF','DWPROF','KILL','RESET'
)

# Commands that may be relayed to SILENT (feed-only) servers.
# Index aligns with $Script:CmdNames. 0 = never sent to a silent link.
$Script:SilentOk = @(
    1,  # notify
    1,  # reqmetar
    1,  # ping
    1,  # pong
    1,  # sync
    1,  # linkdown
    1,  # nowx
    1,  # addclient
    1,  # rmclient
    1,  # plan
    0,  # pd
    0,  # ad
    1,  # addcert
    0,  # mc
    1,  # wx
    1,  # metar
    1,  # add w profile
    1,  # del w profile
    1,  # kill client
    1   # reset
)

# --- Client <-> server commands (cluser.cpp) --------------------------------
$Script:CL_ADDATC     = 0
$Script:CL_RMATC      = 1
$Script:CL_ADDPILOT   = 2
$Script:CL_RMPILOT    = 3
$Script:CL_REQHANDOFF = 4
$Script:CL_MESSAGE    = 5
$Script:CL_REQWEATHER = 6
$Script:CL_PILOTPOS   = 7
$Script:CL_ATCPOS     = 8
$Script:CL_PING       = 9
$Script:CL_PONG       = 10
$Script:CL_ACHANDOFF  = 11
$Script:CL_PLAN       = 12
$Script:CL_SB         = 13
$Script:CL_PC         = 14
$Script:CL_WEATHER    = 15
$Script:CL_CLOUDDATA  = 16
$Script:CL_WINDDATA   = 17
$Script:CL_TEMPDATA   = 18
$Script:CL_REQCOM     = 19
$Script:CL_REPCOM     = 20
$Script:CL_REQACARS   = 21
$Script:CL_REPACARS   = 22
$Script:CL_ERROR      = 23
$Script:CL_CQ         = 24
$Script:CL_CR         = 25
$Script:CL_KILL       = 26
$Script:CL_WDELTA     = 27
$Script:CL_MAX        = 27

$Script:ClCmdNames = @(
    '#AA','#DA','#AP','#DP','$HO','#TM','#RW','@','%','$PI','$PO','$HA',
    '$FP','#SB','#PC','#WX','#CD','#WD','#TD','$C?','$CI','$AX','$AR','$ER',
    '$CQ','$CR','$!!','#DL'
)

$Script:ErrStr = @(
    'No error',
    'Callsign in use',
    'Invalid callsign',
    'Already registerd',
    'Syntax error',
    'Invalid source callsign',
    'Invalid CID/password',
    'No such callsign',
    'No flightplan',
    'No such weather profile',
    'Invalid protocol revision',
    'Requested level too high',
    'Too many clients connected',
    'CID/PID was suspended'
)

$Script:ERR_OK         = 0
$Script:ERR_CSINUSE    = 1
$Script:ERR_CSINVALID  = 2
$Script:ERR_REGISTERED = 3
$Script:ERR_SYNTAX     = 4
$Script:ERR_SRCINVALID = 5
$Script:ERR_CIDINVALID = 6
$Script:ERR_NOSUCHCS   = 7
$Script:ERR_NOFP       = 8
$Script:ERR_NOWEATHER  = 9
$Script:ERR_REVISION   = 10
$Script:ERR_LEVEL      = 11
$Script:ERR_SERVFULL   = 12
$Script:ERR_CSSUSPEND  = 13

$Script:CERT_ADD    = 0
$Script:CERT_DELETE = 1
$Script:CERT_MODIFY = 2

# --- METAR sources (mm.h) ---------------------------------------------------
$Script:SOURCE_NETWORK  = 0
$Script:SOURCE_FILE     = 1
$Script:SOURCE_DOWNLOAD = 2

$Script:VAR_AMOUNT = 10

# --- Weather variation indexes (wprofile.cpp) --------------------------------
$Script:VAR_UPDIRECTION  = 0
$Script:VAR_MIDCOR       = 1
$Script:VAR_LOWCOR       = 2
$Script:VAR_MIDDIRECTION = 3
$Script:VAR_MIDSPEED     = 4
$Script:VAR_LOWDIRECTION = 5
$Script:VAR_LOWSPEED     = 6
$Script:VAR_UPTEMP       = 7
$Script:VAR_MIDTEMP      = 8
$Script:VAR_LOWTEMP      = 9

# ============================================================================
#  Shared runtime state (equivalent of the C globals)
# ============================================================================
$Script:RootServer   = New-Object System.Collections.ArrayList   # all known servers
$Script:MyServer     = $null                                     # this server's object
$Script:RootClient   = New-Object System.Collections.ArrayList   # all known clients
$Script:RootCert     = New-Object System.Collections.ArrayList   # certificate table
$Script:RootProfile  = New-Object System.Collections.ArrayList   # weather profiles

$Script:ClientIF     = $null   # client  (pilot/ATC) listener
$Script:ServerIF     = $null   # server-to-server listener
$Script:SysIF        = $null   # system management listener
$Script:ConfigMan    = $null
$Script:MetarMgr     = $null

$Script:ConnFdSeq    = 1       # emulates file descriptors for admin commands
$Script:FsdTimer     = 0       # last "second tick"
$Script:StopRequested = $false

$Script:LogHistory   = New-Object System.Collections.ArrayList
$Script:LogP         = 0

$Script:MRandSeed    = 0

# Invariant culture for all number formatting (C printf never localises)
$Script:Inv          = [System.Globalization.CultureInfo]::InvariantCulture

# Latin-1 gives a strict 1:1 byte<->char mapping, like the C string handling
$Script:FsdEnc       = [System.Text.Encoding]::GetEncoding(28591)
