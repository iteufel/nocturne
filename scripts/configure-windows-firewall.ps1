# Run explicitly in an elevated PowerShell from the extracted server folder.
# The app never elevates itself or changes the firewall during startup.
param([switch]$Remove)
#Requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'
$root = if (Test-Path (Join-Path $PSScriptRoot 'Nocturne Server.exe')) { $PSScriptRoot } else { throw 'Run the copy of this script beside Nocturne Server.exe in the extracted download.' }
$rules = @(
    @{ Name = 'Nocturne-Workspace'; Program = (Join-Path $root 'Nocturne Server.exe'); Protocol = 'TCP'; LocalPort = '48555' },
    @{ Name = 'Nocturne-Stream-TCP'; Program = (Join-Path $root 'engine/sunshine.exe'); Protocol = 'TCP'; LocalPort = @('47984', '47989', '48010') },
    @{ Name = 'Nocturne-Stream-UDP'; Program = (Join-Path $root 'engine/sunshine.exe'); Protocol = 'UDP'; LocalPort = @('47998', '47999', '48000', '48002', '48010', '5353') }
)
foreach ($rule in $rules) {
    Get-NetFirewallRule -Name $rule.Name -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    if (-not $Remove) { New-NetFirewallRule @rule -DisplayName $rule.Name -Direction Inbound -Action Allow -Profile Private -RemoteAddress LocalSubnet | Out-Null }
}
