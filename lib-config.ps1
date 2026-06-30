# lib-config.ps1 - Code commun : lecture et validation de config.json (config PC).
# Dot-sourcé par backup.ps1 et install-watcher.ps1.

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
