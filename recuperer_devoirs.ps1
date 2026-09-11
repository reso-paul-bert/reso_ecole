# Récupère les dépôts (C:\Depots) des 7 postes vers un dossier local unique sur CE PC, organisé
# par prénom de poste (Naruto, Luffy, ...). Nettoie ensuite le dossier source une fois la copie
# vérifiée (postes avec disques mécaniques limités - pas question de laisser les dépôts s'accumuler).
#
# À lancer depuis le PC admin, quand tu veux relever les devoirs.

$fichierMapping = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "renommage.csv"
$dossierDestination = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "Devoirs_Recuperes"

if (-not (Test-Path $fichierMapping)) {
    Write-Host "ERREUR: '$fichierMapping' introuvable." -ForegroundColor Red
    exit 1
}

$postes = Import-Csv -Path $fichierMapping -Encoding UTF8 | Where-Object { $_.PosteActuel.Trim() -ne "" -and $_.PosteActuel -notlike "<*>*" }

$fichierCredential = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "admin_credential.xml"
if (Test-Path $fichierCredential) {
    $credential = Import-Clixml -Path $fichierCredential
} else {
    $credential = Get-Credential -Message "Compte administrateur local (le même sur tous les postes élèves) - saisis .\NomDuCompte"
}

New-Item -Path $dossierDestination -ItemType Directory -Force | Out-Null

foreach ($ligne in $postes) {
    $poste = $ligne.PosteActuel.Trim()
    $nomPoste = $ligne.NouveauNom.Trim()
    Write-Host "=== $nomPoste ($poste) ===" -ForegroundColor Cyan

    $destinationPoste = Join-Path $dossierDestination $nomPoste
    New-Item -Path $destinationPoste -ItemType Directory -Force | Out-Null

    try {
        $session = New-PSSession -ComputerName $poste -Credential $credential -ErrorAction Stop
        $fichiers = Invoke-Command -Session $session -ScriptBlock { Get-ChildItem "C:\Depots" -File -Recurse -ErrorAction SilentlyContinue }

        if (-not $fichiers -or $fichiers.Count -eq 0) {
            Write-Host "  Rien à récupérer." -ForegroundColor Yellow
            Remove-PSSession $session
            continue
        }

        $copies = 0
        $aSupprimer = @()
        foreach ($fichier in $fichiers) {
            try {
                # Le dossier parent du fichier dans C:\Depots porte le nom du compte élève
                $nomEleve = Split-Path (Split-Path $fichier.FullName -Parent) -Leaf
                $destination = Join-Path $destinationPoste $nomEleve
                New-Item -Path $destination -ItemType Directory -Force | Out-Null

                Copy-Item -FromSession $session -Path $fichier.FullName -Destination $destination -Force -ErrorAction Stop
                $chemin = Join-Path $destination $fichier.Name
                if ((Test-Path $chemin) -and (Get-Item $chemin).Length -eq $fichier.Length) {
                    $copies++
                    $aSupprimer += $fichier.FullName
                }
            } catch {
                Write-Host "  Échec copie $($fichier.Name) : $_" -ForegroundColor Red
            }
        }

        if ($aSupprimer.Count -gt 0) {
            Invoke-Command -Session $session -ScriptBlock {
                param($liste)
                foreach ($chemin in $liste) { Remove-Item -Path $chemin -Force -ErrorAction SilentlyContinue }
            } -ArgumentList (, $aSupprimer)
        }

        Write-Host "  $copies fichier(s) récupéré(s) et nettoyé(s) côté poste." -ForegroundColor Green
        Remove-PSSession $session
    } catch {
        Write-Host "  ÉCHEC de connexion à $poste : $_" -ForegroundColor Red
    }
}

Write-Host ""
Write-Host "Dépôts récupérés dans : $dossierDestination" -ForegroundColor Cyan
