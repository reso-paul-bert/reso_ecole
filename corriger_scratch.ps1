# Corrige Scratch : copie l'installation per-user d'Enseignant vers le profil Default, pour que
# Scratch soit physiquement présent (pas juste raccourci) chez tout NOUVEAU compte élève.
# Ne corrige pas les comptes déjà créés (il faudra les supprimer/recréer, ou les corriger un par un).

$fichierMapping = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "renommage.csv"

if (-not (Test-Path $fichierMapping)) {
    Write-Host "ERREUR: '$fichierMapping' introuvable." -ForegroundColor Red
    exit 1
}

$postes = Import-Csv -Path $fichierMapping -Encoding UTF8 | ForEach-Object { $_.PosteActuel.Trim() } | Where-Object { $_ -ne "" -and $_ -notlike "<*>*" }

$fichierCredential = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "admin_credential.xml"
if (Test-Path $fichierCredential) {
    $credential = Import-Clixml -Path $fichierCredential
} else {
    $credential = Get-Credential -Message "Compte administrateur local (le même sur tous les postes élèves) - saisis .\NomDuCompte"
}

$scriptDistant = {
    $source = "C:\Users\Enseignant\AppData\Local\Programs\Scratch 3"
    $destination = "C:\Users\Default\AppData\Local\Programs\Scratch 3"

    if (-not (Test-Path $source)) {
        return [pscustomobject]@{ Resultat = "Introuvable chez Enseignant : $source" }
    }

    New-Item -Path (Split-Path $destination -Parent) -ItemType Directory -Force | Out-Null
    robocopy $source $destination /E /NFL /NDL /NJH /NJS | Out-Null

    # Raccourci Start Menu d'Enseignant (si présent), copié vers celui de Default
    $raccourciSource = Get-ChildItem "C:\Users\Enseignant\AppData\Roaming\Microsoft\Windows\Start Menu\Programs" -Recurse -Filter "*.lnk" -ErrorAction SilentlyContinue |
        Where-Object { $_.BaseName -match "scratch" } | Select-Object -First 1

    if ($raccourciSource) {
        $dossierDest = "C:\Users\Default\AppData\Roaming\Microsoft\Windows\Start Menu\Programs"
        New-Item -Path $dossierDest -ItemType Directory -Force | Out-Null
        Copy-Item -Path $raccourciSource.FullName -Destination (Join-Path $dossierDest $raccourciSource.Name) -Force
    }

    [pscustomobject]@{
        Resultat = "Copié : $((Get-ChildItem $destination -Recurse -File | Measure-Object).Count) fichiers. Raccourci: $(if ($raccourciSource) { 'OK' } else { 'introuvable chez Enseignant' })"
    }
}

foreach ($poste in $postes) {
    Write-Host "=== $poste ===" -ForegroundColor Cyan
    try {
        $resultat = Invoke-Command -ComputerName $poste -Credential $credential -ScriptBlock $scriptDistant -ErrorAction Stop
        Write-Host "  $($resultat.Resultat)" -ForegroundColor Green
    } catch {
        Write-Host "  ÉCHEC sur $poste : $_" -ForegroundColor Red
    }
}
