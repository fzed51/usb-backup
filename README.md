# USB Backup

Outil de sauvegarde automatique de clés USB pour Windows 10/11 (PowerShell 5.1, sans module tiers).

Quand une clé USB marquée est branchée, son contenu est copié vers un dossier de sauvegarde sur le PC. Les fichiers supprimés de la clé sont conservés un certain temps avant purge (corbeille différée), ce qui protège contre une suppression accidentelle.

## Principe

- Un abonnement **WMI permanent** surveille l'arrivée des volumes.
- À chaque branchement, `backup.ps1` cherche la **première clé amovible** contenant un fichier `.usb-backup.json` à sa racine.
- Il copie les fichiers (extensions filtrées) vers `destinationRoot\backupSetName`.
- La copie utilise `robocopy` en mode ajout/mise à jour — **jamais de miroir destructif**.
- Les fichiers présents en destination mais absents de la clé (« extras ») sont datés dans un journal de suppression, puis purgés après `deletionGraceDays` jours.

## Contenu du dépôt

| Fichier | Rôle |
|---|---|
| `backup.ps1` | Script de sauvegarde (lancé par WMI à chaque branchement) |
| `install-watcher.ps1` | Installe l'abonnement WMI (admin) |
| `uninstall-watcher.ps1` | Retire l'abonnement WMI (admin) |
| `config.example.json` | Modèle de config côté PC |
| `usb-backup.example.json` | Modèle de config côté clé |

---

## Installation sur un poste

### 1. Déposer les fichiers dans le dossier d'installation

Le watcher WMI lance le script depuis un chemin **fixe** : `C:\ProgramData\UsbBackup\`. Seul `backup.ps1` doit obligatoirement résider à cet emplacement. Deux méthodes au choix.

**Méthode A — cloner le dépôt directement au bon endroit (recommandé)**

Le dossier doit être inexistant ou vide ; `git clone` le crée :

```powershell
git clone <URL_DU_DEPOT> "C:\ProgramData\UsbBackup"
```

Avantage : `backup.ps1` est déjà au bon chemin, et un `git pull` suffit pour mettre à jour. `config.json` (créé à l'étape 2) n'étant pas suivi par git, il n'est pas écrasé aux mises à jour.

**Méthode B — copier seulement le script**

Si le dépôt est déjà cloné ailleurs, copier uniquement `backup.ps1` :

```powershell
$dest = 'C:\ProgramData\UsbBackup'
New-Item -ItemType Directory -Path $dest -Force | Out-Null
Copy-Item '.\backup.ps1' -Destination $dest -Force
```

> Dans ce cas, le clone du dépôt peut rester où vous voulez ; il ne sert que de source.

### 2. Créer la config du PC

Copier `config.example.json` en `C:\ProgramData\UsbBackup\config.json` et adapter les valeurs :

```powershell
Copy-Item '.\config.example.json' -Destination 'C:\ProgramData\UsbBackup\config.json'
```

```json
{
  "destinationRoot": "D:\\Sauvegardes\\USB",
  "deletionGraceDays": 60,
  "stateDir": "C:\\ProgramData\\UsbBackup\\state",
  "logPath": "C:\\ProgramData\\UsbBackup\\logs",
  "ejectAfter": false
}
```

| Clé | Description |
|---|---|
| `destinationRoot` | Dossier racine des sauvegardes sur le PC |
| `deletionGraceDays` | Délai (jours) avant purge d'un fichier disparu de la clé. `0` = miroir strict (purge immédiate) |
| `stateDir` | Dossier des journaux de suppression |
| `logPath` | Dossier des logs quotidiens |
| `ejectAfter` | `true` pour éjecter la clé après sauvegarde (best-effort) |

### 3. Installer la détection des clés (abonnement WMI)

Ouvrir **PowerShell en administrateur**, puis :

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\install-watcher.ps1
```

Le script crée trois objets WMI dans `root\subscription` (`USBVolumeArrival`, `USBBackupConsumer`, et leur liaison). Il est **idempotent** : relançable sans créer de doublons.

Confirmation attendue : `Abonnement WMI installé.`

---

## Initialiser la détection d'une clé

Une clé n'est sauvegardée que si elle contient un fichier `.usb-backup.json` à sa **racine**.

1. Copier `usb-backup.example.json` à la racine de la clé **en le renommant** `.usb-backup.json` (point devant).

```powershell
# Exemple : clé montée sur E:
Copy-Item '.\usb-backup.example.json' -Destination 'E:\.usb-backup.json'
```

2. Adapter son contenu :

```json
{
  "backupSetName": "cle-fabien",
  "sources": ["."],
  "includeExtensions": ["docx", "doc", "pdf", "pptx", "ppt", "xlsx", "xls"],
  "excludePatterns": ["~$*", "*.tmp", "Thumbs.db", ".usb-backup.json"]
}
```

| Clé | Description |
|---|---|
| `backupSetName` | Nom du jeu de sauvegarde (= sous-dossier sous `destinationRoot`) |
| `sources` | Dossiers de premier niveau à inclure, relatifs à la racine. `["."]` = toute la clé |
| `includeExtensions` | Extensions à copier, **sans le point** |
| `excludePatterns` | Motifs de fichiers à ignorer |

3. Débrancher / rebrancher la clé pour déclencher la première sauvegarde.

> Plusieurs clés peuvent utiliser le même PC : chacune avec son propre `backupSetName` est sauvegardée dans un sous-dossier distinct.

---

## Vérification / dépannage

- **Logs** : `C:\ProgramData\UsbBackup\logs\backup-AAAAMMJJ.log` (un fichier par jour).
- **Test manuel** sans rebrancher : `powershell.exe -ExecutionPolicy Bypass -File C:\ProgramData\UsbBackup\backup.ps1`
- Clé non branchée → log `aucune clé cible`, sortie propre (code 0).
- **Journal de suppression** : `C:\ProgramData\UsbBackup\state\<backupSetName>.deletions.json` liste les fichiers en attente de purge avec leur date de détection.

## Désinstallation

PowerShell en administrateur :

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\uninstall-watcher.ps1
```

Retire les trois objets WMI. Les sauvegardes déjà copiées et les configs ne sont pas touchées.

## Garanties / limites

- Jamais de `robocopy /MIR`, jamais de suppression hors `deletionGraceDays` (sauf `0` = miroir strict).
- N'écrit/supprime rien hors de `destinationRoot`, `stateDir` et `logPath`.
- Aucune lettre de lecteur codée en dur, aucune UI, aucune saisie interactive.
- Un fichier réapparu sur la clé avant la purge n'est pas supprimé.
