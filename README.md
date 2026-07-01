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
| `update.ps1` | Mise à jour automatique (`git pull`), lancée par tâche planifiée |
| `lib-config.ps1` | Code commun : logging, résolution de git, lecture/validation de `config.json` |
| `install-watcher.ps1` | Installe l'abonnement WMI + la tâche de mise à jour (admin) |
| `uninstall-watcher.ps1` | Retire l'abonnement WMI + la tâche de mise à jour (admin) |
| `config.example.json` | Modèle de config côté PC |
| `usb-backup.example.json` | Modèle de config côté clé |

---

## Installation sur un poste

### 1. Cloner le dépôt dans le dossier d'installation

Le watcher WMI lance le script depuis un chemin **fixe** : `C:\ProgramData\UsbBackup\`. Les scripts dépendent les uns des autres (`backup.ps1` et `install-watcher.ps1` chargent `lib-config.ps1`) : il faut donc cloner le dépôt **directement** à cet emplacement.

Le dossier doit être inexistant ou vide ; `git clone` le crée :

```powershell
git clone https://github.com/fzed51/usb-backup.git "C:\ProgramData\UsbBackup"
```

Un `git pull` suffit pour mettre à jour ; il est d'ailleurs automatisé (voir [Mise à jour automatique](#mise-à-jour-automatique)). `config.json` (créé à l'étape 2) n'étant pas suivi par git, il n'est pas écrasé aux mises à jour.

> **Cloner en HTTPS** (comme ci-dessus), pas en SSH : la mise à jour automatique tourne en compte `SYSTEM`, qui n'a pas accès aux clés SSH de l'utilisateur. Un dépôt public en HTTPS ne demande aucune authentification.

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
| `autoUpdate` | `true` (défaut si absent) pour activer la mise à jour automatique (`git pull`) |
| `updateIntervalHours` | Délai minimal (heures) entre deux `git pull`. Défaut `20` |

### 3. Installer la détection des clés (abonnement WMI)

Ouvrir **PowerShell en administrateur**, puis :

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\install-watcher.ps1
```

Le script crée trois objets WMI dans `root\subscription` (`USBVolumeArrival`, `USBBackupConsumer`, et leur liaison), **puis** la tâche planifiée `UsbBackupUpdate` (mise à jour automatique). Il est **idempotent** : relançable sans créer de doublons.

À cette étape, l'installateur détecte aussi `git.exe` (registre / emplacements connus / PATH) et écrit son chemin dans `config.json` (clé `gitPath`), pour que `update.ps1` — qui tourne en compte `SYSTEM` — le retrouve.

Confirmation attendue : `Abonnement WMI + tâche de mise à jour installés.`

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

## Mise à jour automatique

Une tâche planifiée `UsbBackupUpdate` (installée par `install-watcher.ps1`) lance
`update.ps1` une fois par jour, en compte `SYSTEM`. Le script fait un
`git pull --ff-only` du dépôt `C:\ProgramData\UsbBackup` — best-effort : il ne
touche jamais aux sauvegardes et ne fait jamais échouer la tâche.

- **Activation** : clé `autoUpdate` de `config.json` (`true` par défaut si absente).
  Mettre `false` pour désactiver.
- **Fréquence** : `updateIntervalHours` (défaut `20`) impose un délai minimal entre
  deux `git pull`, même si la tâche est déclenchée plusieurs fois. L'horodatage du
  dernier essai est stocké dans `state\.last-update`.
- **Détection de git** : `install-watcher.ps1` résout `git.exe` (registre
  `GitForWindows`, `C:\Program Files\Git\cmd\git.exe`, puis PATH) et écrit son
  chemin dans `config.json` (`gitPath`). En cas d'échec de détection, renseigner
  `gitPath` manuellement, par ex. `"gitPath": "C:\\Program Files\\Git\\cmd\\git.exe"`.
  `update.ps1` re-tente une détection si `gitPath` est absent ou périmé.
- **Prérequis** : Git installé sur le poste et dépôt cloné en **HTTPS** (voir note
  ci-dessus). Le `pull` utilise `-c safe.directory=…` pour être accepté en `SYSTEM`
  bien que le dépôt ait été cloné par l'administrateur.
- **Test manuel** : `powershell.exe -ExecutionPolicy Bypass -File C:\ProgramData\UsbBackup\update.ps1`
  puis consulter les logs (mêmes fichiers que la sauvegarde) — lignes préfixées `update:`.

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

Retire les trois objets WMI **et** la tâche planifiée `UsbBackupUpdate`. Les sauvegardes déjà copiées et les configs ne sont pas touchées.

## Garanties / limites

- Jamais de `robocopy /MIR`, jamais de suppression hors `deletionGraceDays` (sauf `0` = miroir strict).
- N'écrit/supprime rien hors de `destinationRoot`, `stateDir` et `logPath`.
- Aucune lettre de lecteur codée en dur, aucune UI, aucune saisie interactive.
- Un fichier réapparu sur la clé avant la purge n'est pas supprimé.
