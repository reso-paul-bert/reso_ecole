# Barre des tâches : épingle Firefox, Scratch, LibreOffice, Adobe Reader (et seulement ceux-là)
# pour TOUT NOUVEAU compte, via le LayoutModification.xml du profil Default. Ne concerne pas les
# comptes déjà créés (comme pour regler_barre_des_taches.ps1, dont ce script réécrit le même fichier).

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
    $recherches = [ordered]@{
        Firefox     = "firefox"
        Scratch     = "scratch"
        LibreOffice = "libreoffice"
        AdobeReader = "acrobat"
    }

    # $env:APPDATA pointerait vers le profil du compte admin utilisé pour la connexion à distance,
    # pas vers celui d'Enseignant - il faut scanner le Start Menu de TOUS les profils.
    $dossiersRaccourcis = @("$env:ProgramData\Microsoft\Windows\Start Menu\Programs") +
        (Get-ChildItem "C:\Users\*\AppData\Roaming\Microsoft\Windows\Start Menu\Programs" -Directory -ErrorAction SilentlyContinue).FullName |
        Where-Object { Test-Path $_ }

    $tousLesLnk = Get-ChildItem -Path $dossiersRaccourcis -Recurse -Filter "*.lnk" -ErrorAction SilentlyContinue

    $trouves = [ordered]@{}
    foreach ($cle in $recherches.Keys) {
        $terme = $recherches[$cle]
        $exact = $tousLesLnk | Where-Object { $_.BaseName -ieq $cle -or $_.BaseName -ieq $terme } | Select-Object -First 1
        $trouves[$cle] = if ($exact) { $exact } else { $tousLesLnk | Where-Object { $_.BaseName -match $terme } | Select-Object -First 1 }
    }

    $entrees = foreach ($cle in $trouves.Keys) {
        if ($trouves[$cle]) {
            $chemin = $trouves[$cle].FullName -replace [regex]::Escape($env:ProgramData), "%ALLUSERSPROFILE%"
            # Raccourci trouvé dans le profil d'un utilisateur précis (ex: Enseignant) plutôt que
            # ProgramData : remplace par %APPDATA%, résolu par Windows pour le compte concerné -
            # un chemin absolu vers le profil d'Enseignant ne fonctionnerait pas pour un autre compte.
            $chemin = $chemin -replace "^C:\\Users\\[^\\]+\\AppData\\Roaming", "%APPDATA%"
            "        <taskbar:DesktopApp DesktopApplicationLinkPath=`"$chemin`" />"
        }
    }

    $shellDir = "C:\Users\Default\AppData\Local\Microsoft\Windows\Shell"
    New-Item -Path $shellDir -ItemType Directory -Force | Out-Null

    $xml = @"
<?xml version="1.0" encoding="utf-8"?>
<LayoutModificationTemplate
    xmlns="http://schemas.microsoft.com/Start/2014/LayoutModification"
    xmlns:defaultlayout="http://schemas.microsoft.com/Start/2014/FullDefaultLayout"
    xmlns:start="http://schemas.microsoft.com/Start/2014/StartLayout"
    xmlns:taskbar="http://schemas.microsoft.com/Start/2014/TaskbarLayout"
    Version="1">
  <CustomTaskbarLayoutCollection PinListPlacement="Replace">
    <defaultlayout:TaskbarLayout>
      <taskbar:TaskbarPinList>
$($entrees -join "`n")
      </taskbar:TaskbarPinList>
    </defaultlayout:TaskbarLayout>
  </CustomTaskbarLayoutCollection>
</LayoutModificationTemplate>
"@
    Set-Content -Path (Join-Path $shellDir "LayoutModification.xml") -Value $xml -Encoding UTF8

    [pscustomobject]@{
        Trouves = ($trouves.GetEnumerator() | ForEach-Object { "$($_.Key): $(if ($_.Value) { 'OK' } else { 'INTROUVABLE' })" }) -join ", "
    }
}

foreach ($poste in $postes) {
    Write-Host "=== $poste ===" -ForegroundColor Cyan
    try {
        $resultat = Invoke-Command -ComputerName $poste -Credential $credential -ScriptBlock $scriptDistant -ErrorAction Stop
        Write-Host "  $($resultat.Trouves)" -ForegroundColor Green
    } catch {
        Write-Host "  ÉCHEC sur $poste : $_" -ForegroundColor Red
    }
}
