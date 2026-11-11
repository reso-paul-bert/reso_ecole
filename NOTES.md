# Notes d'exploitation

## Expiration des mots de passe (a faire a la main)

La strategie locale par defaut de Windows fixe l'age maximal d'un mot de passe a **42 jours**.
`net user /add` ne pose pas l'exception, donc tous les comptes crees le meme jour se bloquent
ensemble six semaines plus tard, avec le message « le mot de passe a expire ».

`deployer_utilisateurs.ps1` s'en charge pour les comptes eleves. Restent **le compte
administrateur local** (celui qui sert au pilotage a distance) et **`Enseignant`** : s'ils
expirent, plus aucun script ne fonctionne et il faut se deplacer sur chaque machine.

### Sur un poste, en PowerShell administrateur

```powershell
Set-LocalUser -Name "<NomDuCompteAdmin>" -PasswordNeverExpires $true
Set-LocalUser -Name "Enseignant" -PasswordNeverExpires $true
```

Verification — la colonne `PasswordExpires` doit etre vide pour ces comptes :

```powershell
Get-LocalUser | Select-Object Name, PasswordExpires, Enabled
```

### Sur les 7 postes d'un coup, depuis le PC qui pilote

```powershell
$credential = Get-Credential
$postes = Import-Csv "$env:USERPROFILE\Desktop\reso_ecole\renommage.csv" |
    ForEach-Object { $_.PosteActuel.Trim() }

foreach ($poste in $postes) {
    Write-Host "=== $poste ===" -ForegroundColor Cyan
    Invoke-Command -ComputerName $poste -Credential $credential -ScriptBlock {
        foreach ($compte in @("<NomDuCompteAdmin>", "Enseignant")) {
            if (Get-LocalUser -Name $compte -ErrorAction SilentlyContinue) {
                Set-LocalUser -Name $compte -PasswordNeverExpires $true
                Write-Output "$compte : ok"
            }
        }
    }
}
```

Remplacer `<NomDuCompteAdmin>` par le nom reel, **sans** le `.\` : ce prefixe ne sert que dans
la fenetre d'identifiants, pour forcer la resolution comme compte local sur la machine distante.

## Rappels qui font perdre du temps

- Scripts bloques au demarrage : `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass`.
- `TrustedHosts` n'accepte pas le CIDR : lister les IP exactes, separees par des virgules.
- Le service WinRM doit etre en demarrage `Automatic`, sinon il ne repart pas apres un
  redemarrage du PC qui pilote.
- Le tableau de bord se lance en administrateur (ouverture du port local). S'il refuse de
  demarrer, c'est souvent une instance precedente qui detient encore le port : le message
  d'erreur donne le PID a arreter.
- Un processus lance en administrateur ne peut pas etre arrete depuis une console normale.
