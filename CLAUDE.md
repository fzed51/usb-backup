# Instructions projet — usb-backup

## Encodage des fichiers

### Scripts `.ps1` — UTF-16 avec BOM (obligatoire)

PowerShell 5.1 lit correctement les accents français **uniquement** si le fichier
porte un BOM (UTF-16 ou UTF-8 BOM). Sans BOM, il retombe sur la page de codes ANSI
et casse les accents.

Configuration en place (`.gitattributes`) :

```
*.ps1 working-tree-encoding=UTF-16 eol=CRLF
```

Conséquences à connaître :

- **Blob git = UTF-8** → les `git diff` restent lisibles.
- **Copie de travail = UTF-16 + BOM** au checkout. `iconv` (utilisé par git) émet
  du **big-endian** (`FE FF`) par défaut : `file *.ps1` rapportera donc
  « UTF-16, big-endian ». **C'est normal, pas un bug** — le BOM est présent, donc
  PowerShell 5.1 le lit sans problème.

### Règles

- **Ne pas** passer à `working-tree-encoding=UTF-16LE` : git interdit alors le BOM
  dans la copie de travail, et sans BOM PowerShell 5.1 casse les accents.
- `UTF-16LE-BOM` n'existe pas côté git/iconv (il n'y a pas de variante LE-avec-BOM).
- **Ne pas « corriger »** le big-endian en little-endian : les deux fonctionnent
  tant que le BOM est là.
- Les fichiers **`.json` restent en UTF-8** (`*.json text eol=lf`). Ne jamais les
  encoder en UTF-16.

### Éditer un `.ps1` par script

Lire/écrire en tenant compte du BOM UTF-16. Pour un utilitaire d'édition, préférer
Node (`fs.readFileSync(path, 'utf16le')`, réécriture avec `'﻿' + contenu`) —
git réencodera vers le blob UTF-8 au commit.
