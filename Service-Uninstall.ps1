# ============================================================================
#  Service-Uninstall.ps1 - remove the PowerShell-FSD Windows service
#  Must be run from an elevated PowerShell prompt.
# ============================================================================

& "$PSScriptRoot\Fsd.ps1" -Uninstall
Read-Host 'Press Enter to continue'
