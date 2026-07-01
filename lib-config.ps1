# lib-config.ps1 - Code commun : logging, resolution de git, lecture/validation de config.json.
# Dot-sourcé par backup.ps1, update.ps1 et install-watcher.ps1.

# Horodatage unique du run pour nommer le log (date + heure + minute).
$script:LogStamp = (Get-Date).ToString('yyyyMMdd-HHmm')

# Écrit une ligne horodatée dans le log du jour (best-effort).
function Write-Log {
    param([string]$Message, [string]$LogDir)
    try {
        if ($LogDir -and (Test-Path $LogDir)) {
            $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
            $file  = Join-Path $LogDir ('backup-{0}.log' -f $script:LogStamp)
            Add-Content -Path $file -Value ("$stamp  $Message") -Encoding UTF8
        }
    } catch { }
}

# Résout le chemin de git.exe. SYSTEM n'hérite que du PATH Machine : on sonde donc
# d'abord un chemin configuré, puis le registre GitForWindows, puis les emplacements
# connus, enfin le PATH. Retourne le chemin ou $null.
function Resolve-Git {
    param([string]$Configured)
    if ($Configured -and (Test-Path $Configured)) { return $Configured }
    foreach ($k in 'HKLM:\SOFTWARE\GitForWindows','HKLM:\SOFTWARE\Wow6432Node\GitForWindows') {
        try {
            $ip  = (Get-ItemProperty -Path $k -Name InstallPath -ErrorAction Stop).InstallPath
            $exe = Join-Path $ip 'cmd\git.exe'
            if (Test-Path $exe) { return $exe }
        } catch { }
    }
    foreach ($p in 'C:\Program Files\Git\cmd\git.exe','C:\Program Files (x86)\Git\cmd\git.exe') {
        if (Test-Path $p) { return $p }
    }
    $cmd = Get-Command git -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

# Lit et valide la config PC.
# Retourne un objet : @{ Ok = [bool]; Config = [psobject|null]; Error = [string] }
#   - Config est l'objet JSON parsé dès que le JSON est lisible (même si invalide),
#     pour permettre au caller de récupérer logPath afin de journaliser l'erreur.
#   - Sur Ok, deletionGraceDays est normalisé en double dans Config.
function Read-UsbBackupConfig {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path $Path)) {
        return @{ Ok = $false; Config = $null; Error = "config absente : $Path" }
    }

    $cfg = $null
    try { $cfg = Get-Content -Path $Path -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { return @{ Ok = $false; Config = $null; Error = "config illisible (JSON invalide) : $Path" } }
    if (-not $cfg) {
        return @{ Ok = $false; Config = $null; Error = "config vide : $Path" }
    }

    # Champs obligatoires.
    $missing = @()
    if (-not $cfg.destinationRoot)        { $missing += 'destinationRoot' }
    if (-not $cfg.stateDir)               { $missing += 'stateDir' }
    if (-not $cfg.logPath)                { $missing += 'logPath' }
    if ($null -eq $cfg.deletionGraceDays) { $missing += 'deletionGraceDays' }
    if ($missing.Count -gt 0) {
        return @{ Ok = $false; Config = $cfg; Error = ("champ(s) manquant(s) : " + ($missing -join ', ')) }
    }

    # deletionGraceDays : nombre >= 0.
    $grace = 0
    if (-not [double]::TryParse([string]$cfg.deletionGraceDays, [ref]$grace) -or $grace -lt 0) {
        return @{ Ok = $false; Config = $cfg; Error = "deletionGraceDays doit etre un nombre >= 0" }
    }
    $cfg.deletionGraceDays = $grace

    return @{ Ok = $true; Config = $cfg; Error = $null }
}
