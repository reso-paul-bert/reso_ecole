# reso_ecole

Scripts d'administration d'une salle informatique (7 postes Windows 10, comptes locaux,
pas de domaine Active Directory). Tout est pilote a distance depuis un PC administrateur
via PowerShell Remoting (WinRM), le transport reseau etant assure par Tailscale.

## Configuration locale (non versionnee)

Deux fichiers doivent etre crees a partir des exemples fournis :

| Fichier a creer | Modele | Contenu |
|---|---|---|
| `renommage.csv` | `renommage.exemple.csv` | IP Tailscale de chaque poste + nom cible. Sert de liste des postes a **tous** les scripts. |
| `eleves_paulbert.csv` | `eleves_paulbert.exemple.csv` | Identifiants et mots de passe des comptes eleves. |

Ces deux fichiers sont dans `.gitignore` : le CSV eleves contient des mots de passe en clair
et ne doit jamais etre pousse.

## Prerequis

Une fois par poste eleve, en administrateur local :

```powershell
Enable-PSRemoting -SkipNetworkProfileCheck -Force
Set-NetFirewallRule -Group "@FirewallAPI.dll,-30267" -RemoteAddress 100.64.0.0/10
```

`-SkipNetworkProfileCheck` est necessaire quand la carte reseau est classee « Public ».
La regle de pare-feu est ensuite restreinte a la plage Tailscale pour ne pas exposer WinRM
au reste du reseau. Le `-Group` utilise l'identifiant interne, independant de la langue de
Windows (sur un systeme francais, le nom affiche est « Gestion a distance de Windows »).

Sur le PC administrateur, declarer les postes comme hotes de confiance (authentification NTLM
en groupe de travail). Attention : `TrustedHosts` n'accepte **pas** la notation CIDR, il faut
lister les IP exactes :

```powershell
Set-Item WSMan:\localhost\Client\TrustedHosts -Value "100.x.x.1,100.x.x.2,..." -Force
```

A chaque invite d'identifiants, saisir le compte sous la forme `.\NomDuCompte` (le `.\` force
la resolution comme compte local sur la machine distante).

## Ordre d'installation

| # | Script | Role |
|---|---|---|
| 1 | `renommer_pcs.ps1` | Renomme les postes puis redemarre. |
| 2 | `regler_policies_machine.ps1` | Policies machine : Cortana, Copilot, notifications, ecran de confidentialite a la premiere connexion, Windows Spotlight. Force aussi le retrait des paquets Xbox provisionnes. |
| 3 | `corriger_scratch.ps1` | Scratch s'installe par utilisateur (`AppData\Local\Programs`) : copie l'installation vers le profil Default pour que les nouveaux comptes l'aient. |
| 4 | `regler_barre_des_taches.ps1` | Vide la barre des taches (icones epinglees, bouton Affichage des taches, barre de recherche). |
| 5 | `barre_des_taches_raccourcis.ps1` | Y epingle Firefox, Scratch, LibreOffice, Acrobat. A lancer **apres** le 4, qui vide tout. |
| 6 | `bureau_raccourcis.ps1` | Nettoie les bureaux, pose les 4 icones, fond d'ecran noir, icones alignees. |
| 7 | `configurer_dossier_depot.ps1` | Cree `C:\Depots` et l'icone « Deposer mon devoir ». |
| 8 | `deployer_utilisateurs.ps1` | Cree les comptes eleves (acces RDP, groupe `Eleves`, dossier de depot prive). **En dernier**, pour que chaque compte herite de tout ce qui precede. |

La plupart des reglages passent par le profil `Default` (`C:\Users\Default\NTUSER.DAT`), applique
automatiquement par Windows a **tout nouveau compte** des sa premiere connexion. C'est pourquoi
la creation des comptes vient en dernier : un profil deja cree n'herite pas retroactivement.

## Usage courant

| Script | Role |
|---|---|
| `dashboard_classe.ps1` | Tableau de bord HTML auto-actualise : qui est connecte, logiciels ouverts, devoirs rendus. Cree aussi des raccourcis de prise de controle (shadow RDP, sans deconnecter l'eleve). |
| `recuperer_devoirs.ps1` | Rapatrie les depots des postes vers `Devoirs_Recuperes/<Poste>/` et nettoie la source. |
| `redemarrer_pcs.ps1` | Redemarre tous les postes. |
| `supprimer_utilisateurs.ps1` | Supprime comptes et profils (remise a zero). Detruit les fichiers des profils. |

## Dossier de depot des devoirs

`C:\Depots` accorde aux eleves la seule traversee : ils ne peuvent pas en lister le contenu,
donc pas voir qui a rendu quoi. Chaque eleve a un sous-dossier `C:\Depots\<identifiant>` ou il
peut **uniquement deposer** : lecture, modification et suppression lui sont refusees, y compris
sur ses propres depots.

Consequence importante : l'Explorateur Windows ne peut pas ouvrir un dossier dont la lecture est
refusee. Le depot passe donc par l'icone « Deposer mon devoir », qui ouvre un selecteur de
fichier (elle accepte aussi le glisser-deposer). Chaque depot est horodate dans le nom du
fichier, ce qui evite qu'un eleve ecrase un travail deja rendu.

Les droits `WA`/`WEA` (ecriture des attributs) doivent etre accordes explicitement : Explorateur
et LibreOffice les exigent pour creer un fichier, et ce qui n'est pas accorde reste refuse.

## Diagnostics

`diagnostiquer_depot.ps1`, `diagnostiquer_recherche.ps1`, `diagnostiquer_fond_ecran.ps1`,
`diagnostiquer_scratch.ps1` inspectent l'etat reel d'un poste (ACL, registre, emplacements
d'installation) plutot que de supposer. Ils lisent les ruches hors ligne via `reg load`, ce qui
impose que le compte cible soit deconnecte.

## Reseau Tailscale

`tailscale-acl.json` restreint le reseau : le poste administrateur peut joindre les postes
eleves, l'inverse est impossible (Tailscale refuse tout par defaut, seul le sens declare est
autorise). A n'appliquer **qu'une fois le PC administrateur definitif tague** `tag:admin`,
sinon la machine qui pilote perd son propre acces.

Cette regle ne couvre que le trafic passant par Tailscale. Si les postes partagent aussi un
reseau local physique, l'isolation doit etre traitee au niveau du LAN.
