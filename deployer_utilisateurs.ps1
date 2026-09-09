# Déploie la création des comptes élèves sur plusieurs PC via PowerShell Remoting (WinRM),
# en utilisant les adresses/hostnames Tailscale comme transport.
#
# Prérequis à faire UNE FOIS sur chaque poste élève (avant de lancer ce script), en admin :
#   Enable-PSRemoting -SkipNetworkProfileCheck -Force
#   Set-NetFirewallRule -Group "@FirewallAPI.dll,-30267" -RemoteAddress 100.64.0.0/10
# (le -Group utilise l'identifiant interne, indépendant de la langue du système ; sur un Windows
# en français, -DisplayGroup "Windows Remote Management" ne matche rien car il faut le nom localisé)
# (-SkipNetworkProfileCheck est nécessaire si la carte réseau est classée "Public" ; la règle
# pare-feu est ensuite restreinte à la plage d'IP Tailscale pour ne pas exposer WinRM ailleurs)
#
# Sur CE PC (le PC admin), si les postes sont en groupe de travail (pas de domaine AD),
# il faut déclarer les postes comme "de confiance" pour l'authentification NTLM. Attention :
# contrairement à la règle de pare-feu, TrustedHosts N'ACCEPTE PAS le CIDR (ex: /10) — seulement
# des noms/IP exactes ou des jokers "*". Liste donc les IP Tailscale exactes des postes :
#   Set-Item WSMan:\localhost\Client\TrustedHosts -Value "100.1.2.3,100.4.5.6,..." -Force
# (remplace par les IP réelles de tes postes, visibles via `tailscale status`)

# Liste des postes cibles : réutilise la colonne PosteActuel de renommage.csv (même fichier
# que renommer_pcs.ps1), pour n'avoir qu'une seule liste d'IP Tailscale à tenir à jour.
$fichierMapping = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "renommage.csv"
$fichierCSV = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "eleves_paulbert.csv"

if (-not (Test-Path $fichierMapping)) {
    Write-Host "ERREUR: '$fichierMapping' introuvable." -ForegroundColor Red
    exit 1
}
if (-not (Test-Path $fichierCSV)) {
    Write-Host "ERREUR: '$fichierCSV' introuvable." -ForegroundColor Red
    exit 1
}

$postes = Import-Csv -Path $fichierMapping -Encoding UTF8 | ForEach-Object { $_.PosteActuel.Trim() } | Where-Object { $_ -ne "" -and $_ -notlike "<*>*" }
$donnees = Import-Csv -Path $fichierCSV -Encoding UTF8

$trustedHosts = (Get-Item WSMan:\localhost\Client\TrustedHosts -ErrorAction SilentlyContinue).Value
$postesManquants = @($postes | Where-Object { $trustedHosts -ne "*" -and $trustedHosts -notmatch [regex]::Escape($_.Trim()) })
if ($postesManquants.Count -gt 0) {
    Write-Host "ATTENTION: ces postes ne sont pas dans TrustedHosts (côté PC admin) : $($postesManquants -join ', ')" -ForegroundColor Yellow
    Write-Host "Exécute d'abord: Set-Item WSMan:\localhost\Client\TrustedHosts -Value `"$($postesManquants -join ',')`" -Force" -ForegroundColor Yellow
    Write-Host "(TrustedHosts n'accepte pas le CIDR : liste les IP exactes, séparées par des virgules)" -ForegroundColor Yellow
    Write-Host ""
}

$fichierCredential = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "admin_credential.xml"
if (Test-Path $fichierCredential) {
    $credential = Import-Clixml -Path $fichierCredential
} else {
    # Rappel: sur un compte local en groupe de travail, saisis le nom d'utilisateur sous la forme
    # ".\NomDuCompte" (et pas juste "NomDuCompte") pour que NTLM le résolve sur CHAQUE poste distant.
    $credential = Get-Credential -Message "Compte administrateur local (le même sur tous les postes élèves) - saisis .\NomDuCompte"
}

# Ce bloc s'exécute À DISTANCE sur chaque poste : il reçoit directement les données du CSV,
# pas besoin de copier le fichier CSV sur chaque machine.
$scriptDistant = {
    param($donnees)

    $compteurCrees = 0
    $compteurExistants = 0
    $erreurs = @()

    # Groupe local pour gérer les permissions (ex: dossier de dépôt) par groupe plutôt que par compte
    if (-not (Get-LocalGroup -Name "Eleves" -ErrorAction SilentlyContinue)) {
        New-LocalGroup -Name "Eleves" -Description "Comptes élèves" | Out-Null
    }

    # Sous-dossier de dépôt privé : l'élève peut UNIQUEMENT y déposer (créer des fichiers) - aucun
    # droit de lire/lister/modifier/supprimer, même ce qu'il vient de déposer lui-même. Enseignant/
    # admin ont accès complet. C:\Depots lui-même doit déjà exister (configurer_dossier_depot.ps1).
    function New-DossierDepotPrive($nom) {
        $chemin = "C:\Depots\$nom"
        if (-not (Test-Path "C:\Depots")) { return }
        New-Item -Path $chemin -ItemType Directory -Force | Out-Null
        icacls $chemin /inheritance:r | Out-Null
        icacls $chemin /grant:r "*S-1-5-18:(OI)(CI)(F)" | Out-Null
        icacls $chemin /grant:r "*S-1-5-32-544:(OI)(CI)(F)" | Out-Null
        icacls $chemin /grant:r "Enseignant:(OI)(CI)(F)" | Out-Null
        # Purge d'abord toute entree existante pour ce compte : /grant et /deny sont additifs, donc
        # sans ca les passages successifs empilent des ACE (et laissent des SID orphelins apres
        # suppression/recreation des comptes).
        icacls $chemin /remove:g $nom | Out-Null
        icacls $chemin /remove:d $nom | Out-Null
        # WA/WEA doivent etre ACCORDES explicitement : Explorer et LibreOffice ecrivent les attributs
        # (horodatage) du fichier qu'ils creent. Sans eux, le depot echoue - ce qui n'est pas
        # explicitement accorde reste refuse.
        icacls $chemin /grant "${nom}:(OI)(CI)(WD,AD,X,WA,WEA)" | Out-Null
        # RD = ne peut pas lister/relire, D+DC = ne peut pas supprimer (ni son propre depot).
        icacls $chemin /deny "${nom}:(OI)(CI)(RD,D,DC)" | Out-Null
    }

    foreach ($utilisateur in $donnees) {
        $nomUtilisateur = $utilisateur.Identifiant.Trim()
        $motDePasse = $utilisateur.MotDePasse.Trim()
        if ($nomUtilisateur -eq "") { continue }

        $null = & net user $nomUtilisateur 2>&1
        if ($LASTEXITCODE -eq 0) {
            $compteurExistants++
            # SID universel du groupe "Remote Desktop Users", indépendant de la langue (le nom
            # affiché est "Utilisateurs du Bureau à distance" sur un Windows FR)
            try {
                Add-LocalGroupMember -SID "S-1-5-32-555" -Member $nomUtilisateur -ErrorAction Stop
            } catch {
                if ($_ -notmatch "already a member|est déjà membre") {
                    $erreurs += "$nomUtilisateur (RDP) : $_"
                }
            }
            try {
                Add-LocalGroupMember -Group "Eleves" -Member $nomUtilisateur -ErrorAction Stop
            } catch {
                if ($_ -notmatch "already a member|est déjà membre") {
                    $erreurs += "$nomUtilisateur (Eleves) : $_"
                }
            }
            New-DossierDepotPrive $nomUtilisateur
            continue
        }

        $output = & net user $nomUtilisateur $motDePasse /add 2>&1
        if ($LASTEXITCODE -eq 0) {
            $compteurCrees++
            # Autorise le compte à se connecter en RDP (sinon désactivé par défaut pour un compte non-admin)
            try {
                Add-LocalGroupMember -SID "S-1-5-32-555" -Member $nomUtilisateur -ErrorAction Stop
            } catch {
                if ($_ -notmatch "already a member|est déjà membre") {
                    $erreurs += "$nomUtilisateur (RDP) : $_"
                }
            }
            try {
                Add-LocalGroupMember -Group "Eleves" -Member $nomUtilisateur -ErrorAction Stop
            } catch {
                if ($_ -notmatch "already a member|est déjà membre") {
                    $erreurs += "$nomUtilisateur (Eleves) : $_"
                }
            }
            New-DossierDepotPrive $nomUtilisateur
        } else {
            $erreurs += "$nomUtilisateur : $output"
        }
    }

    [pscustomobject]@{
        Crees     = $compteurCrees
        Existants = $compteurExistants
        Erreurs   = $erreurs
    }
}

foreach ($poste in $postes) {
    Write-Host "=== $poste ===" -ForegroundColor Cyan
    try {
        $resultat = Invoke-Command -ComputerName $poste -Credential $credential -ScriptBlock $scriptDistant -ArgumentList (, $donnees) -ErrorAction Stop
        Write-Host "  Créés: $($resultat.Crees)  Existants: $($resultat.Existants)  Erreurs: $($resultat.Erreurs.Count)" -ForegroundColor Green
        foreach ($e in $resultat.Erreurs) {
            Write-Host "    - $e" -ForegroundColor Red
        }
    } catch {
        Write-Host "  ÉCHEC de connexion à $poste : $_" -ForegroundColor Red
    }
}
