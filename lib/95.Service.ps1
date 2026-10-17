# ============================================================================
#  PowerShell-FSD - 95.Service.ps1
#  Windows service support
#
#  The service host is a tiny ServiceBase implementation compiled at runtime.
#  OnStart spawns a worker runspace that loads the server and runs the main
#  loop; OnStop signals it through a static .NET flag.
# ============================================================================

$Script:ServiceCs = @'
using System;
using System.ServiceProcess;
using System.Management.Automation;

namespace FsdService
{
    public static class FsdServiceBridge
    {
        public static bool StopRequested;
        public static PowerShell Worker;
    }

    public class FsdServiceHost : ServiceBase
    {
        public Action OnStartAction;
        public Action OnStopAction;

        public FsdServiceHost(string name)
        {
            ServiceName = name;
            CanStop = true;
        }

        protected override void OnStart(string[] args)
        {
            if (OnStartAction != null) OnStartAction();
        }

        protected override void OnStop()
        {
            if (OnStopAction != null) OnStopAction();
        }

        public static void Run(string name, Action onStart, Action onStop)
        {
            ServiceBase.Run(new FsdServiceHost(name) { OnStartAction = onStart, OnStopAction = onStop });
        }
    }
}
'@

function Start-FsdServiceMode {
    param([string]$ServiceName, [string]$ScriptDir, [string]$ConfigFile)

    Add-Type -TypeDefinition $Script:ServiceCs -ReferencedAssemblies @('System.ServiceProcess', 'System.Management.Automation')

    $workerText = @'
param($Dir, $Cfg)
Set-Location -LiteralPath $Dir
& (Join-Path $Dir 'Fsd.ps1') -WorkerRun -ConfigFile $Cfg
'@

    $onStart = [action]{
        try {
            $ps = [powershell]::Create()
            [void]$ps.AddScript($workerText).AddArgument($ScriptDir).AddArgument($ConfigFile)
            [void]$ps.BeginInvoke()
            [FsdService.FsdServiceBridge]::Worker = $ps
        } catch {
            Write-Dolog -Level $Script:L_ERR -Message ("Service worker failed to start: {0}" -f $_.Exception.Message)
        }
    }

    $onStop = [action]{
        [FsdService.FsdServiceBridge]::StopRequested = $true
        try {
            if ([FsdService.FsdServiceBridge]::Worker) { [FsdService.FsdServiceBridge]::Worker.Stop() }
        } catch { }
    }

    [FsdService.FsdServiceHost]::Run($ServiceName, $onStart, $onStop)
}
