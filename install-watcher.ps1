# install-watcher.ps1 - Abonnement WMI permanent lançant backup.ps1 à l'arrivée d'un volume.
# À lancer en administrateur.

$ErrorActionPreference = 'Stop'

# Vérification des droits admin.
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
if (-not $admin) { Write-Error 'À lancer en administrateur.'; exit 1 }

# Code commun (validation de config).
$libPath = Join-Path $PSScriptRoot 'lib-config.ps1'
if (-not (Test-Path $libPath)) { Write-Error "Lib absente : $libPath."; exit 1 }
. $libPath

# Garde : refuser l'installation si le script ou sa config ne sont pas en place.
$installDir = 'C:\ProgramData\UsbBackup'
$scriptPath = Join-Path $installDir 'backup.ps1'
$configPath = Join-Path $installDir 'config.json'

if (-not (Test-Path $scriptPath)) {
    Write-Error "Script absent : $scriptPath. Déposez backup.ps1 avant d'installer le watcher."
    exit 1
}

# Valider la config PC via la lib commune.
$result = Read-UsbBackupConfig -Path $configPath
if (-not $result.Ok) {
    Write-Error ("config.json : " + $result.Error)
    exit 1
}

# Idempotence : supprimer les objets existants avant de recréer.
Get-WmiObject -Namespace root\subscription -Class __FilterToConsumerBinding -ErrorAction SilentlyContinue |
    Where-Object { $_.Consumer -match 'USBBackupConsumer' } |
    ForEach-Object { $_.Delete() }
Get-WmiObject -Namespace root\subscription -Class CommandLineEventConsumer -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -eq 'USBBackupConsumer' } |
    ForEach-Object { $_.Delete() }
Get-WmiObject -Namespace root\subscription -Class __EventFilter -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -eq 'USBVolumeArrival' } |
    ForEach-Object { $_.Delete() }

# Créer le filtre (arrivée de volume : EventType = 2).
$filter = Set-WmiInstance -Namespace root\subscription -Class __EventFilter -Arguments @{
    Name           = 'USBVolumeArrival'
    EventNamespace = 'root\cimv2'
    QueryLanguage  = 'WQL'
    Query          = "SELECT * FROM Win32_VolumeChangeEvent WHERE EventType = 2"
}

# Créer le consommateur (lance backup.ps1).
$consumer = Set-WmiInstance -Namespace root\subscription -Class CommandLineEventConsumer -Arguments @{
    Name                = 'USBBackupConsumer'
    CommandLineTemplate = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\ProgramData\UsbBackup\backup.ps1"'
}

# Lier filtre et consommateur.
Set-WmiInstance -Namespace root\subscription -Class __FilterToConsumerBinding -Arguments @{
    Filter   = $filter
    Consumer = $consumer
} | Out-Null

Write-Host 'Abonnement WMI installé.'
