# install-watcher.ps1 - Abonnement WMI permanent lançant backup.ps1 à l'arrivée d'un volume,
# plus une tâche planifiée de mise à jour automatique (git pull). À lancer en administrateur.

$ErrorActionPreference = 'Stop'

# Vérification des droits admin.
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
if (-not $admin) { Write-Error 'À lancer en administrateur.'; exit 1 }

# Code commun (logging, résolution de git, validation de config).
$libPath = Join-Path $PSScriptRoot 'lib-config.ps1'
if (-not (Test-Path $libPath)) { Write-Error "Lib absente : $libPath."; exit 1 }
. $libPath

# Garde : refuser l'installation si le script ou sa config ne sont pas en place.
$installDir = 'C:\ProgramData\UsbBackup'
$scriptPath = Join-Path $installDir 'backup.ps1'
$configPath = Join-Path $installDir 'config.json'
$updatePath = Join-Path $installDir 'update.ps1'

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

# Résoudre git et persister le chemin dans config.json. L'installateur tourne en admin
# (PATH/registre riches) alors que update.ps1 tourne en SYSTEM (PATH Machine seulement) :
# on fige donc ici un chemin absolu réutilisable au runtime.
$gitPath = Resolve-Git -Configured $result.Config.gitPath
if ($gitPath) {
    if (-not $result.Config.gitPath -or -not (Test-Path $result.Config.gitPath)) {
        try {
            if ($result.Config.PSObject.Properties['gitPath']) { $result.Config.gitPath = $gitPath }
            else { $result.Config | Add-Member -NotePropertyName gitPath -NotePropertyValue $gitPath }
            ($result.Config | ConvertTo-Json -Depth 10) | Set-Content -Path $configPath -Encoding UTF8
            Write-Host "git détecté : $gitPath (écrit dans config.json)."
        } catch {
            Write-Warning "Impossible d'écrire gitPath dans config.json : $($_.Exception.Message)"
        }
    } else {
        Write-Host "git : $($result.Config.gitPath) (déjà configuré)."
    }
} else {
    Write-Warning "git introuvable : la mise à jour automatique restera inactive tant que git n'est pas installé (ou gitPath renseigné dans config.json)."
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

# Tâche planifiée de mise à jour automatique (git pull quotidien, en SYSTEM). Idempotente.
if (Test-Path $updatePath) {
    Unregister-ScheduledTask -TaskName 'UsbBackupUpdate' -Confirm:$false -ErrorAction SilentlyContinue
    $taskAction    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -File "C:\ProgramData\UsbBackup\update.ps1"'
    $taskTrigger   = New-ScheduledTaskTrigger -Daily -At '12:00'
    $taskPrincipal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $taskSettings  = New-ScheduledTaskSettingsSet -StartWhenAvailable
    Register-ScheduledTask -TaskName 'UsbBackupUpdate' -Action $taskAction -Trigger $taskTrigger -Principal $taskPrincipal -Settings $taskSettings -Description 'Mise a jour automatique de USB Backup (git pull).' | Out-Null
    Write-Host 'Tâche planifiée UsbBackupUpdate installée.'
} else {
    Write-Warning "update.ps1 absent : tâche de mise à jour non installée."
}

Write-Host 'Abonnement WMI + tâche de mise à jour installés.'
