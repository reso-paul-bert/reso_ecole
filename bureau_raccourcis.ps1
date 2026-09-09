# Bureau : supprime tous les raccourcis existants (la Corbeille n'est pas un raccourci .lnk, donc
# jamais touchée) - à la fois dans le Public Desktop (partagé, futurs comptes inclus) ET dans le
# dossier Desktop propre à CHAQUE profil déjà présent sur la machine (Enseignant, comptes élèves
# déjà créés...) - puis ajoute Firefox, Scratch, LibreOffice, Adobe Reader dans le Public Desktop.
# Pose aussi un fond d'écran noir uni + icônes rangées (auto-arrangées, alignées sur la grille),
# sur le profil Default (futurs comptes) ET sur chaque profil existant (hors ceux actuellement
# connectés - leur hive est verrouillé, ça s'appliquera à leur prochaine connexion).

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

    $bureauxExistants = Get-ChildItem -Path "C:\Users" -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { Join-Path $_.FullName "Desktop" } |
        Where-Object { Test-Path $_ }

    Get-ChildItem -Path $bureauxExistants -Include "*.lnk", "*.url" -File -Recurse -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue

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

    foreach ($cle in $trouves.Keys) {
        if ($trouves[$cle]) {
            Copy-Item -Path $trouves[$cle].FullName -Destination "C:\Users\Public\Desktop\$cle.lnk" -Force
        }
    }

    # Génère une image noire une fois sur la machine (la policy Wallpaper a besoin d'un vrai
    # fichier image, une valeur vide ne suffit pas pour cette clé-là)
    $imageNoire = "C:\Windows\Web\Wallpaper\fond_noir.bmp"
    if (-not (Test-Path $imageNoire)) {
        Add-Type -AssemblyName System.Drawing
        $bmp = New-Object System.Drawing.Bitmap 64, 64
        $graphics = [System.Drawing.Graphics]::FromImage($bmp)
        $graphics.Clear([System.Drawing.Color]::Black)
        $bmp.Save($imageNoire, [System.Drawing.Imaging.ImageFormat]::Bmp)
        $graphics.Dispose()
        $bmp.Dispose()
    }

    # Fond d'écran noir uni (via la policy Wallpaper, prioritaire sur ce que le thème réimpose)
    # + icônes auto-arrangées/alignées sur la grille
    function Set-ReglagesBureau($hiveRoot) {
        $bagsPath = "$hiveRoot\Software\Microsoft\Windows\Shell\Bags\1\Desktop"
        New-Item -Path $bagsPath -Force | Out-Null
        New-ItemProperty -Path $bagsPath -Name "FFlags" -Value 1075839525 -PropertyType DWord -Force | Out-Null

        $desktopPath = "$hiveRoot\Control Panel\Desktop"
        New-Item -Path $desktopPath -Force | Out-Null
        New-ItemProperty -Path $desktopPath -Name "WallPaper" -Value "" -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $desktopPath -Name "WallpaperStyle" -Value "0" -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $desktopPath -Name "TileWallpaper" -Value "0" -PropertyType String -Force | Out-Null

        $colorsPath = "$hiveRoot\Control Panel\Colors"
        New-Item -Path $colorsPath -Force | Out-Null
        New-ItemProperty -Path $colorsPath -Name "Background" -Value "0 0 0" -PropertyType String -Force | Out-Null

        $policyPath = "$hiveRoot\Software\Microsoft\Windows\CurrentVersion\Policies\System"
        New-Item -Path $policyPath -Force | Out-Null
        New-ItemProperty -Path $policyPath -Name "Wallpaper" -Value $imageNoire -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $policyPath -Name "WallpaperStyle" -Value "10" -PropertyType String -Force | Out-Null

        $themesPath = "$hiveRoot\Software\Microsoft\Windows\CurrentVersion\Themes"
        New-Item -Path $themesPath -Force | Out-Null
        New-ItemProperty -Path $themesPath -Name "WallpaperSetFromTheme" -Value 0 -PropertyType DWord -Force | Out-Null
    }

    # Profil Default (tout futur compte)
    reg load HKU\BureauDefault "C:\Users\Default\NTUSER.DAT" 2>&1 | Out-Null
    Set-ReglagesBureau "Registry::HKEY_USERS\BureauDefault"
    [gc]::Collect()
    reg unload HKU\BureauDefault 2>&1 | Out-Null

    # Chaque profil déjà présent sur la machine
    $resultatsProfils = Get-ChildItem "C:\Users" -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notin @("Default", "Public") -and (Test-Path (Join-Path $_.FullName "NTUSER.DAT")) } |
        ForEach-Object {
            $nomTemp = "Bureau_" + ($_.Name -replace '[^A-Za-z0-9]', '')
            $chargement = reg load "HKU\$nomTemp" (Join-Path $_.FullName "NTUSER.DAT") 2>&1
            if ($LASTEXITCODE -eq 0) {
                Set-ReglagesBureau "Registry::HKEY_USERS\$nomTemp"
                [gc]::Collect()
                reg unload "HKU\$nomTemp" 2>&1 | Out-Null
                "$($_.Name): OK"
            } else {
                "$($_.Name): ignoré (probablement connecté - s'appliquera à la prochaine connexion)"
            }
        }

    [pscustomobject]@{
        Trouves = ($trouves.GetEnumerator() | ForEach-Object { "$($_.Key): $(if ($_.Value) { 'OK' } else { 'INTROUVABLE' })" }) -join ", "
        Profils = $resultatsProfils -join "; "
    }
}

foreach ($poste in $postes) {
    Write-Host "=== $poste ===" -ForegroundColor Cyan
    try {
        $resultat = Invoke-Command -ComputerName $poste -Credential $credential -ScriptBlock $scriptDistant -ErrorAction Stop
        Write-Host "  Raccourcis: $($resultat.Trouves)" -ForegroundColor Green
        Write-Host "  Fond d'écran/icônes par profil: $($resultat.Profils)" -ForegroundColor Green
    } catch {
        Write-Host "  ÉCHEC sur $poste : $_" -ForegroundColor Red
    }
}
