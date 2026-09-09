# Supprime les comptes élèves (compte + profil complet) sur chaque poste, via PowerShell Remoting.
# Réutilise renommage.csv (liste des postes) et eleves_paulbert.csv (liste des identifiants à supprimer).
#
# ATTENTION: supprime aussi le dossier de profil (C:\Users\<nom>) -> tout fichier enregistré dedans
# sera perdu. Vérifie qu'aucun élève n'a sauvegardé de travail avant de lancer ce script.

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
$noms = $donnees | ForEach-Object { $_.Identifiant.Trim() } | Where-Object { $_ -ne "" }

$fichierCredential = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "admin_credential.xml"
if (Test-Path $fichierCredential) {
    $credential = Import-Clixml -Path $fichierCredential
} else {
    $credential = Get-Credential -Message "Compte administrateur local (le même sur tous les postes élèves) - saisis .\NomDuCompte"
}

$scriptDistant = {
    param($noms)

    $supprimes = 0
    $absents = 0
    $erreurs = @()

    foreach ($nom in $noms) {
        $null = & net user $nom 2>&1
        if ($LASTEXITCODE -ne 0) {
            $absents++
            continue
        }

        try {
            Get-CimInstance -ClassName Win32_UserProfile -ErrorAction Stop |
                Where-Object { $_.LocalPath -like "*\$nom" } |
                Remove-CimInstance -ErrorAction Stop
        } catch {
            $erreurs += "$nom (profil) : $_"
        }

        $output = & net user $nom /delete 2>&1
        if ($LASTEXITCODE -eq 0) {
            $supprimes++
        } else {
            $erreurs += "$nom (compte) : $output"
        }
    }

    [pscustomobject]@{
        Supprimes = $supprimes
        Absents   = $absents
        Erreurs   = $erreurs
    }
}

foreach ($poste in $postes) {
    Write-Host "=== $poste ===" -ForegroundColor Cyan
    try {
        $resultat = Invoke-Command -ComputerName $poste -Credential $credential -ScriptBlock $scriptDistant -ArgumentList (, $noms) -ErrorAction Stop
        Write-Host "  Supprimés: $($resultat.Supprimes)  Absents: $($resultat.Absents)  Erreurs: $($resultat.Erreurs.Count)" -ForegroundColor Green
        foreach ($e in $resultat.Erreurs) {
            Write-Host "    - $e" -ForegroundColor Red
        }
    } catch {
        Write-Host "  ÉCHEC de connexion à $poste : $_" -ForegroundColor Red
    }
}
