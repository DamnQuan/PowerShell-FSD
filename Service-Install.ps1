# ============================================================================
#  Service-Install.ps1 - install PowerShell-FSD as an auto-start Windows service
#  Must be run from an elevated PowerShell prompt.
# ============================================================================

& "$PSScriptRoot\Fsd.ps1" -Install
Read-Host 'Press Enter to continue'
