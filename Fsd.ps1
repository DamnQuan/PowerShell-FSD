# ============================================================================
#  PowerShell-FSD - Fsd.ps1  (main entry point)
#
#  A Flight Server Daemon implemented in pure PowerShell.
#
#  USAGE:
#     Fsd.ps1                  Run interactive
#     Fsd.ps1 -ConfigFile x    Use an alternative configuration file
#     Fsd.ps1 -Install         Install as an auto-start Windows service
#     Fsd.ps1 -Uninstall       Remove the Windows service
#     Fsd.ps1 -ServiceMode     Internal: service entry (called by the SCM)
#     Fsd.ps1 -WorkerRun       Internal: service worker main loop
# ============================================================================

[CmdletBinding()]
param(
    [string]$ConfigFile = 'fsd.conf',
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$ServiceMode,
    [switch]$WorkerRun
)

$ErrorActionPreference = 'Stop'

# Resolve the server root directory and chdir into it (like the Windows main)
$Script:FsdDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Script:FsdDir = (Resolve-Path -LiteralPath $Script:FsdDir).Path
Set-Location -LiteralPath $Script:FsdDir

# Load the server modules into the script scope.
# NOTE: this deliberately happens at the top level of the script; dot-sourcing
# inside a function would scope the definitions to that function only.
. (Join-Path $Script:FsdDir 'lib\00.Const.ps1')
. (Join-Path $Script:FsdDir 'lib\10.Support.ps1')
. (Join-Path $Script:FsdDir 'lib\20.Manage.ps1')
. (Join-Path $Script:FsdDir 'lib\30.Config.ps1')
. (Join-Path $Script:FsdDir 'lib\40.Cert.ps1')
. (Join-Path $Script:FsdDir 'lib\50.Model.ps1')
. (Join-Path $Script:FsdDir 'lib\60.WProfile.ps1')
. (Join-Path $Script:FsdDir 'lib\70.Metar.ps1')
. (Join-Path $Script:FsdDir 'lib\80.Conn.ps1')
. (Join-Path $Script:FsdDir 'lib\81.ClientIF.ps1')
. (Join-Path $Script:FsdDir 'lib\82.ServerIF.ps1')
. (Join-Path $Script:FsdDir 'lib\83.SysIF.ps1')
. (Join-Path $Script:FsdDir 'lib\90.Fsd.ps1')
. (Join-Path $Script:FsdDir 'lib\95.Service.ps1')

# ---------------------------------------------------------------------------
# Windows service management (main.cpp /INSTALL and /UNINSTALL)
# ---------------------------------------------------------------------------
$Script:ServiceName = 'FSD'
$Script:ServiceDesc = 'FSD Server'

function Invoke-ServiceInstall {
    if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
            ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Host 'Error : Couldnt open Service Manager, make sure you are administrator'
        exit -1
    }
    $binPath = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}" -ServiceMode' -f (Join-Path $Script:FsdDir 'Fsd.ps1')
    $existing = Get-Service -Name $Script:ServiceName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host 'Error : Couldnt create Service, make sure the service doesnt already exist'
        exit -1
    }
    New-Service -Name $Script:ServiceName -BinaryPathName $binPath `
        -DisplayName $Script:ServiceDesc -Description "$Script:ServiceDesc" `
        -StartupType Automatic | Out-Null
    try {
        Start-Service -Name $Script:ServiceName -ErrorAction Stop
    } catch {
        Write-Host 'Error : Couldnt start Service'
        exit -1
    }
    Write-Host 'Info : Service installed'
    exit 0
}

function Invoke-ServiceUninstall {
    if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
            ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Host 'Error : Couldnt open Service Manager, make sure you are administrator'
        exit -1
    }
    $existing = Get-Service -Name $Script:ServiceName -ErrorAction SilentlyContinue
    if (-not $existing) {
        Write-Host 'Error : Couldnt find Service, make sure the service exists'
        exit -1
    }
    & sc.exe stop $Script:ServiceName | Out-Null
    & sc.exe delete $Script:ServiceName | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host 'Error : Couldnt delete Service'
        exit -1
    }
    Write-Host 'Info : Service uninstalled'
    exit 0
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

if ($Install)   { Invoke-ServiceInstall }
if ($Uninstall) { Invoke-ServiceUninstall }

if ($ServiceMode) {
    # Started by the Windows service controller
    Start-FsdServiceMode -ServiceName $Script:ServiceName -ScriptDir $Script:FsdDir -ConfigFile $ConfigFile
    exit 0
}

if ($WorkerRun) {
    # Running inside the service worker runspace
    Initialize-Fsd -ConfigFile $ConfigFile
    while (-not [FsdService.FsdServiceBridge]::StopRequested) {
        $busy = Invoke-FsdIteration
        if (-not $busy) { Start-Sleep -Milliseconds 25 }
    }
    exit 0
}

# Interactive run
try {
    Initialize-Fsd -ConfigFile $ConfigFile
    Invoke-FsdRun
} catch {
    Write-Host ("FATAL: {0}" -f $_.Exception.Message) -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    try {
        Write-Dolog -Level $Script:L_CRIT -Message ("FATAL: {0}" -f $_.Exception.Message)
        Write-Dolog -Level $Script:L_CRIT -Message ("STACK: {0}" -f ($_.ScriptStackTrace -replace "`r`n", ' | '))
    } catch { }
    exit 1
}
