# Renomme chaque PC élève via PowerShell Remoting (WinRM), puis redémarre automatiquement.
# Prérequis identiques à deployer_utilisateurs.ps1 : WinRM activé sur chaque poste
# (Enable-PSRemoting -SkipNetworkProfileCheck -Force, puis
# Set-NetFirewallRule -Group "@FirewallAPI.dll,-30267" -RemoteAddress 100.64.0.0/10)
# + TrustedHosts configuré côté PC admin si groupe de travail (IP exactes, PAS de CIDR ici :
# Set-Item WSMan:\localhost\Client\TrustedHosts -Value "100.1.2.3,100.4.5.6,..." -Force).
#
# 1) Remplis renommage.csv : colonne PosteActuel = hostname ou IP Tailscale actuel du poste
#    (visible via `tailscale status` sur le PC admin), colonne NouveauNom = nom cible.
# 2) Lance ce script en tant qu'administrateur.

$fichierMapping = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "renommage.csv"

if (-not (Test-Path $fichierMapping)) {
    Write-Host "ERREUR: '$fichierMapping' introuvable." -ForegroundColor Red
    exit 1
}

$mapping = Import-Csv -Path $fichierMapping -Encoding UTF8

$trustedHosts = (Get-Item WSMan:\localhost\Client\TrustedHosts -ErrorAction SilentlyContinue).Value
$postesManquants = @($mapping | ForEach-Object { $_.PosteActuel.Trim() } | Where-Object { $_ -notlike "<*>*" -and $_ -ne "" -and $trustedHosts -ne "*" -and $trustedHosts -notmatch [regex]::Escape($_) })
if ($postesManquants.Count -gt 0) {
    Write-Host "ATTENTION: ces postes ne sont pas dans TrustedHosts (côté PC admin) : $($postesManquants -join ', ')" -ForegroundColor Yellow
    Write-Host "Exécute d'abord: Set-Item WSMan:\localhost\Client\TrustedHosts -Value `"$($postesManquants -join ',')`" -Force" -ForegroundColor Yellow
    Write-Host "(TrustedHosts n'accepte pas le CIDR : liste les IP exactes, séparées par des virgules)" -ForegroundColor Yellow
    Write-Host ""
}

$regexNomValide = '^[A-Za-z0-9-]{1,15}$'

foreach ($ligne in $mapping) {
    $posteActuel = $ligne.PosteActuel.Trim()
    $nouveauNom = $ligne.NouveauNom.Trim()

    if ($posteActuel -like "<*>*" -or $posteActuel -eq "") {
        Write-Host "Ligne ignorée (PosteActuel non renseigné): '$posteActuel'" -ForegroundColor Yellow
        continue
    }

    if ($nouveauNom -notmatch $regexNomValide) {
        Write-Host "Nom invalide pour '$posteActuel': '$nouveauNom' (lettres/chiffres/tirets, 15 caractères max)" -ForegroundColor Red
        continue
    }

    if (-not $credential) {
        $fichierCredential = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "admin_credential.xml"
        if (Test-Path $fichierCredential) {
            $credential = Import-Clixml -Path $fichierCredential
        } else {
            # Saisis le nom d'utilisateur sous la forme ".\NomDuCompte" (pas juste "NomDuCompte")
            # pour que NTLM le résolve sur CHAQUE poste distant, en groupe de travail.
            $credential = Get-Credential -Message "Compte administrateur local (le même sur tous les postes élèves) - saisis .\NomDuCompte"
        }
    }

    Write-Host "=== $posteActuel -> $nouveauNom ===" -ForegroundColor Cyan
    try {
        Invoke-Command -ComputerName $posteActuel -Credential $credential -ErrorAction Stop -ScriptBlock {
            param($nom)
            Rename-Computer -NewName $nom -Force -Restart
        } -ArgumentList $nouveauNom
        Write-Host "  Renommage envoyé, le poste redémarre." -ForegroundColor Green
    } catch {
        Write-Host "  ÉCHEC sur $posteActuel : $_" -ForegroundColor Red
    }
}

Write-Host ""
Write-Host "Terminé. Les postes renommés seront injoignables quelques instants pendant le redémarrage." -ForegroundColor Cyan
