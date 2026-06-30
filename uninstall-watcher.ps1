# uninstall-watcher.ps1 - Retire l'abonnement WMI installé par install-watcher.ps1.
# À lancer en administrateur.

$ErrorActionPreference = 'Stop'

# Vérification des droits admin.
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
if (-not $admin) { Write-Error 'À lancer en administrateur.'; exit 1 }

# Supprimer la liaison, puis le consommateur, puis le filtre (sans erreur si absents).
Get-WmiObject -Namespace root\subscription -Class __FilterToConsumerBinding -ErrorAction SilentlyContinue |
    Where-Object { $_.Consumer -match 'USBBackupConsumer' } |
    ForEach-Object { $_.Delete() }

Get-WmiObject -Namespace root\subscription -Class CommandLineEventConsumer -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -eq 'USBBackupConsumer' } |
    ForEach-Object { $_.Delete() }

Get-WmiObject -Namespace root\subscription -Class __EventFilter -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -eq 'USBVolumeArrival' } |
    ForEach-Object { $_.Delete() }

Write-Host 'Abonnement WMI désinstallé.'
