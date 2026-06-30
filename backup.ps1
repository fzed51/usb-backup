# backup.ps1 - Sauvegarde USB automatique (PowerShell 5.1)
# Piloté par config.json (PC) et .usb-backup.json (clé). Aucune UI.

$ErrorActionPreference = 'Stop'

$InstallDir = 'C:\ProgramData\UsbBackup'
$ConfigPath = Join-Path $InstallDir 'config.json'

# Code commun (validation de config). Sans la lib, sortie silencieuse.
$libPath = Join-Path $PSScriptRoot 'lib-config.ps1'
if (-not (Test-Path $libPath)) { exit 0 }
. $libPath

# Écrit une ligne horodatée dans le log du jour (best-effort).
function Write-Log {
    param([string]$Message, [string]$LogDir)
    try {
        if ($LogDir -and (Test-Path $LogDir)) {
            $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
            $file  = Join-Path $LogDir ('backup-{0}.log' -f (Get-Date).ToString('yyyyMMdd'))
            Add-Content -Path $file -Value ("$stamp  $Message") -Encoding UTF8
        }
    } catch { }
}

# Mutex global anti double-exécution.
$mutex = New-Object System.Threading.Mutex($false, 'Global\UsbBackupMutex')
if (-not $mutex.WaitOne(0)) { exit 0 }

$logDir = $null
$exitCode = 0
try {
    # Lire et valider la config PC via la lib commune.
    $result = Read-UsbBackupConfig -Path $ConfigPath

    # logPath best-effort pour journaliser, même en cas de config invalide.
    if ($result.Config -and $result.Config.logPath) {
        $logDir = $result.Config.logPath
        if (-not (Test-Path $logDir)) { try { New-Item -ItemType Directory -Path $logDir -Force | Out-Null } catch { } }
    }

    if (-not $result.Ok) {
        Write-Log ("config.json invalide : " + $result.Error) $logDir
        exit 0
    }

    $config            = $result.Config
    $destinationRoot   = $config.destinationRoot
    $deletionGraceDays = [double]$config.deletionGraceDays
    $stateDir          = $config.stateDir
    $logDir            = $config.logPath
    $ejectAfter        = [bool]$config.ejectAfter

    if ($stateDir -and -not (Test-Path $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }

    # Trouver la clé : premier volume amovible contenant .usb-backup.json.
    $key = Get-Volume |
        Where-Object { $_.DriveType -eq 'Removable' -and $_.DriveLetter } |
        ForEach-Object { "$($_.DriveLetter):\" } |
        Where-Object { Test-Path (Join-Path $_ '.usb-backup.json') } |
        Select-Object -First 1

    if (-not $key) {
        Write-Log 'aucune clé cible' $logDir
        exit 0
    }

    # Lire la config de la clé.
    $keyConfigPath = Join-Path $key '.usb-backup.json'
    $usb = Get-Content -Path $keyConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json

    if (-not $usb.backupSetName -or -not $usb.sources -or -not $usb.includeExtensions) {
        Write-Log 'config clé invalide (backupSetName/sources/includeExtensions manquant)' $logDir
        exit 0
    }

    $backupSetName    = $usb.backupSetName
    $sources          = @($usb.sources)
    $includeExt       = @($usb.includeExtensions) | ForEach-Object { $_.TrimStart('.').ToLower() }
    $excludePatterns  = @()
    if ($usb.excludePatterns) { $excludePatterns = @($usb.excludePatterns) }

    # Destination = racine\backupSetName, reproduit l'arborescence de la clé.
    $destination = Join-Path $destinationRoot $backupSetName
    if (-not (Test-Path $destination)) { New-Item -ItemType Directory -Path $destination -Force | Out-Null }

    # Motifs d'extensions pour robocopy.
    $extPatterns = $includeExt | ForEach-Object { "*.$_" }

    # Copie (ajouts/modifs, jamais de purge) pour chaque source.
    $robocopyExit = 0
    $logFile = Join-Path $logDir ('backup-{0}.log' -f (Get-Date).ToString('yyyyMMdd'))
    foreach ($src in $sources) {
        if ($src -eq '.') {
            # Garder le backslash : robocopy avec une lettre nue ("E:") cible le
            # répertoire courant du lecteur, pas sa racine -> ne récurse pas.
            $srcPath = $key
            $dstPath = $destination
        } else {
            $srcPath = Join-Path $key $src
            $dstPath = Join-Path $destination $src
        }
        if (-not (Test-Path $srcPath)) { continue }

        $args = @($srcPath, $dstPath) + $extPatterns + @('/E', '/COPY:DAT', '/R:2', '/W:5')
        if ($excludePatterns.Count -gt 0) { $args += @('/XF') + $excludePatterns }
        $args += @('/NP', '/NFL', '/NDL', "/LOG+:$logFile")

        & robocopy @args | Out-Null
        if ($LASTEXITCODE -gt $robocopyExit) { $robocopyExit = $LASTEXITCODE }
    }

    # Construit l'ensemble des chemins relatifs valides d'une racine sous les sources.
    function Get-RelativeSet {
        param([string]$Base, [string[]]$Sources, [string[]]$Extensions, [string[]]$Excludes, [bool]$ApplyExcludes)
        $set = @{}
        foreach ($src in $Sources) {
            if ($src -eq '.') { $scanRoot = $Base } else { $scanRoot = Join-Path $Base $src }
            if (-not (Test-Path $scanRoot)) { continue }
            Get-ChildItem -Path $scanRoot -Recurse -File -Force -ErrorAction SilentlyContinue | ForEach-Object {
                $f = $_
                $ext = $f.Extension.TrimStart('.').ToLower()
                if ($Extensions -notcontains $ext) { return }
                if ($ApplyExcludes) {
                    foreach ($pat in $Excludes) { if ($f.Name -like $pat) { return } }
                }
                $rel = $f.FullName.Substring($Base.Length).TrimStart('\')
                $set[$rel.ToLower()] = $rel
            }
        }
        return $set
    }

    # Ensemble "clé" : fichiers présents sur la clé (avec excludes), relatifs à la clé.
    $keyBase = $key.TrimEnd('\')
    $cleSet  = Get-RelativeSet -Base $keyBase -Sources $sources -Extensions $includeExt -Excludes $excludePatterns -ApplyExcludes $true

    # Ensemble "dest" : tous les fichiers de destination avec extension incluse, relatifs à destination.
    $destSet = @{}
    if (Test-Path $destination) {
        Get-ChildItem -Path $destination -Recurse -File -Force -ErrorAction SilentlyContinue | ForEach-Object {
            $f = $_
            $ext = $f.Extension.TrimStart('.').ToLower()
            if ($includeExt -notcontains $ext) { return }
            $rel = $f.FullName.Substring($destination.Length).TrimStart('\')
            $destSet[$rel.ToLower()] = $rel
        }
    }

    # extras = dest privé de clé (comparaison insensible à la casse).
    $extras = @()
    foreach ($k in $destSet.Keys) {
        if (-not $cleSet.ContainsKey($k)) { $extras += $destSet[$k] }
    }

    # Mettre à jour le journal de suppression.
    $deletionsPath = Join-Path $stateDir ("$backupSetName.deletions.json")
    $oldJournal = @{}
    if (Test-Path $deletionsPath) {
        try {
            $parsed = Get-Content -Path $deletionsPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($parsed) { $parsed.PSObject.Properties | ForEach-Object { $oldJournal[$_.Name] = $_.Value } }
        } catch { $oldJournal = @{} }
    }

    $nowIso = (Get-Date).ToString('o')
    $newJournal = @{}
    foreach ($rel in $extras) {
        if ($oldJournal.ContainsKey($rel)) { $newJournal[$rel] = $oldJournal[$rel] }
        else { $newJournal[$rel] = $nowIso }
    }

    # Purge différée.
    $purged = 0
    $now = Get-Date
    $toRemove = @()
    foreach ($rel in @($newJournal.Keys)) {
        $entryDate = $null
        try { $entryDate = [datetime]::Parse($newJournal[$rel]) } catch { $entryDate = $now }
        if (($now - $entryDate).TotalDays -ge $deletionGraceDays) {
            $target = Join-Path $destination $rel
            try {
                if (Test-Path $target) { Remove-Item -Path $target -Force }
                $purged++
            } catch {
                Write-Log "echec purge: $rel - $($_.Exception.Message)" $logDir
            }
            $toRemove += $rel
        }
    }
    foreach ($rel in $toRemove) { $newJournal.Remove($rel) }

    # Supprimer les dossiers vides sous destination après purge.
    if ($purged -gt 0) {
        Get-ChildItem -Path $destination -Recurse -Directory -Force -ErrorAction SilentlyContinue |
            Sort-Object { $_.FullName.Length } -Descending |
            ForEach-Object {
                try {
                    if (-not (Get-ChildItem -Path $_.FullName -Force -ErrorAction SilentlyContinue)) {
                        Remove-Item -Path $_.FullName -Force
                    }
                } catch { }
            }
    }

    # Sauvegarder le nouveau journal.
    $obj = New-Object PSObject
    foreach ($rel in $newJournal.Keys) { $obj | Add-Member -NotePropertyName $rel -NotePropertyValue $newJournal[$rel] }
    ($obj | ConvertTo-Json -Depth 5) | Set-Content -Path $deletionsPath -Encoding UTF8

    # Récapitulatif.
    if ($robocopyExit -lt 8) { $rcStatus = "succes/avertissement ($robocopyExit)" }
    else { $rcStatus = "erreur ($robocopyExit)" }
    Write-Log "recap: robocopy=$rcStatus, extras=$($extras.Count), purges=$purged" $logDir

    # Éjection best-effort.
    if ($ejectAfter) {
        try {
            $letter = $key.Substring(0, 1)
            $eject = New-Object -ComObject Shell.Application
            $eject.Namespace(17).ParseName("$letter`:").InvokeVerb('Eject')
        } catch { }
    }

    $exitCode = 0
}
catch {
    Write-Log "ERREUR FATALE: $($_.Exception.Message)" $logDir
    $exitCode = 1
}
finally {
    $mutex.ReleaseMutex(); $mutex.Dispose()
}

exit $exitCode
