# update.ps1 - Mise à jour automatique du dépôt (git pull). Lancé par une tâche planifiée SYSTEM.
# Best-effort : ne fait jamais échouer la tâche. Piloté par config.json
# (autoUpdate, updateIntervalHours, gitPath). Aucune UI.

$ErrorActionPreference = 'Stop'

$InstallDir = 'C:\ProgramData\UsbBackup'
$ConfigPath = Join-Path $InstallDir 'config.json'

# Code commun (logging, résolution de git, validation config). Sans la lib, sortie silencieuse.
$libPath = Join-Path $PSScriptRoot 'lib-config.ps1'
if (-not (Test-Path $libPath)) { exit 0 }
try { . $libPath } catch { exit 0 }

$mutex = $null
try {
    # Lire la config PC.
    $result = Read-UsbBackupConfig -Path $ConfigPath

    # logPath best-effort pour journaliser même config invalide.
    $logDir = $null
    if ($result.Config -and $result.Config.logPath) {
        $logDir = $result.Config.logPath
        if (-not (Test-Path $logDir)) { try { New-Item -ItemType Directory -Path $logDir -Force | Out-Null } catch { } }
    }

    if (-not $result.Ok) {
        Write-Log ("update: config.json invalide : " + $result.Error) $logDir
        exit 0
    }
    $config   = $result.Config
    $logDir   = $config.logPath
    $stateDir = $config.stateDir

    # Activation : autoUpdate absent => activé ; explicitement $false => stop.
    if ($config.autoUpdate -eq $false) {
        Write-Log 'update: auto-update desactive (autoUpdate=false)' $logDir
        exit 0
    }

    # Throttle : ne pas repull avant updateIntervalHours (défaut 20h).
    $intervalHours = 20
    if ($null -ne $config.updateIntervalHours) {
        $tmp = 0
        if ([double]::TryParse([string]$config.updateIntervalHours, [ref]$tmp) -and $tmp -ge 0) { $intervalHours = $tmp }
    }
    if ($stateDir -and -not (Test-Path $stateDir)) { try { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null } catch { } }
    $stampPath = $null
    if ($stateDir) { $stampPath = Join-Path $stateDir '.last-update' }
    if ($stampPath -and (Test-Path $stampPath)) {
        try {
            $last = [datetime]::Parse((Get-Content -Path $stampPath -Raw -Encoding UTF8).Trim())
            if (((Get-Date) - $last).TotalHours -lt $intervalHours) { exit 0 }
        } catch { }
    }

    # Mutex dédié (distinct du mutex de backup : le tenir ferait sauter une sauvegarde).
    $mutex = New-Object System.Threading.Mutex($false, 'Global\UsbBackupUpdateMutex')
    if (-not $mutex.WaitOne(0)) { $mutex.Dispose(); $mutex = $null; exit 0 }

    # Dépôt git présent ?
    if (-not (Test-Path (Join-Path $InstallDir '.git'))) {
        Write-Log 'update: pas de depot git (.git absent) : mise a jour ignoree' $logDir
        exit 0
    }

    # Résoudre git (config.gitPath, sinon re-scan registre/chemins/PATH).
    $git = Resolve-Git -Configured $config.gitPath
    if (-not $git) {
        Write-Log 'update: git introuvable (ni gitPath, ni registre, ni PATH)' $logDir
        exit 0
    }

    # git pull --ff-only avec safe.directory (repo cloné par l'admin, exécuté en SYSTEM).
    $outFile  = Join-Path $env:TEMP ("usb-backup-pull-out-{0}.txt" -f $PID)
    $errFile  = Join-Path $env:TEMP ("usb-backup-pull-err-{0}.txt" -f $PID)
    $gitArgs  = @('-c', 'safe.directory=C:/ProgramData/UsbBackup', '-C', $InstallDir, 'pull', '--ff-only')
    $proc = Start-Process -FilePath $git -ArgumentList $gitArgs -NoNewWindow -PassThru -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    if (-not $proc.WaitForExit(60000)) {
        try { $proc.Kill() } catch { }
        Write-Log 'update: git pull expire (timeout 60s), interrompu' $logDir
        exit 0
    }
    $code = $proc.ExitCode
    $out = ''; $err = ''
    try { if (Test-Path $outFile) { $out = (Get-Content -Path $outFile -Raw) } } catch { }
    try { if (Test-Path $errFile) { $err = (Get-Content -Path $errFile -Raw) } } catch { }
    try { Remove-Item $outFile, $errFile -Force -ErrorAction SilentlyContinue } catch { }

    if ($code -eq 0) {
        $summary = ($out -replace '\r?\n', ' ').Trim()
        if (-not $summary) { $summary = 'a jour' }
        Write-Log ("update: git pull ok - " + $summary) $logDir
    } else {
        $emsg = ($err -replace '\r?\n', ' ').Trim()
        Write-Log ("update: echec git pull (code $code) - " + $emsg) $logDir
    }

    # Horodater la tentative (succès comme échec) pour respecter l'intervalle.
    if ($stampPath) {
        try { Set-Content -Path $stampPath -Value ((Get-Date).ToString('o')) -Encoding UTF8 } catch { }
    }
}
catch {
    # Best-effort : ne jamais faire échouer la tâche planifiée.
}
finally {
    if ($mutex) { try { $mutex.ReleaseMutex() } catch { }; $mutex.Dispose() }
}

exit 0
