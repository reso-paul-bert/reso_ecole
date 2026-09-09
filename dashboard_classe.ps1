# Tableau de bord classe : interroge les postes en boucle et genere une page HTML qui se
# rafraichit toute seule. A lancer depuis le PC enseignant, garder la fenetre PowerShell ouverte.
#
# Affiche par poste : etat en ligne, qui est connecte, logiciels ouverts (+ titre de fenetre),
# et le contenu du dossier de depot de l'eleve connecte.
#
# Cree aussi un dossier "Controle_Postes" sur le Bureau avec un raccourci par machine pour
# prendre la main sur la session de l'eleve SANS le deconnecter (shadow RDP).

$intervalleSecondes = 30

# Necessaire pour HtmlEncode (titres de fenetres pouvant contenir < > &)
Add-Type -AssemblyName System.Web

$dossierScript = Split-Path -Parent $MyInvocation.MyCommand.Path
$fichierMapping = Join-Path $dossierScript "renommage.csv"
$fichierHtml = Join-Path $dossierScript "dashboard.html"

if (-not (Test-Path $fichierMapping)) {
    Write-Host "ERREUR: renommage.csv introuvable." -ForegroundColor Red
    exit 1
}

$machines = Import-Csv -Path $fichierMapping -Encoding UTF8 |
    Where-Object { $_.PosteActuel.Trim() -ne "" -and $_.PosteActuel -notlike "<*>*" }

$credential = Get-Credential -Message "Compte administrateur local - saisis .\NomDuCompte"

# ---------------------------------------------------------------------------
# Raccourcis de prise de controle (shadow RDP : l'eleve n'est PAS deconnecte)
# ---------------------------------------------------------------------------
$dossierControle = Join-Path ([Environment]::GetFolderPath("Desktop")) "Controle_Postes"
New-Item -Path $dossierControle -ItemType Directory -Force | Out-Null
$shell = New-Object -ComObject WScript.Shell

foreach ($machine in $machines) {
    $ip = $machine.PosteActuel.Trim()
    $nom = $machine.NouveauNom.Trim()

    # /shadow:1 = session console (celle de l'eleve). /control = peut agir, sinon simple observation.
    $bat = Join-Path $dossierControle "$nom.bat"
    $lignes = @(
        "@echo off",
        "echo Connexion a $nom ($ip)...",
        "mstsc /v:$ip /shadow:1 /control /noConsentPrompt",
        "if errorlevel 1 pause"
    )
    Set-Content -Path $bat -Value ($lignes -join "`r`n") -Encoding ASCII

    $lnk = $shell.CreateShortcut((Join-Path $dossierControle "Controler $nom.lnk"))
    $lnk.TargetPath = $bat
    $lnk.IconLocation = "%SystemRoot%\System32\mstsc.exe,0"
    $lnk.Save()
}

# ---------------------------------------------------------------------------
# Collecte distante
# ---------------------------------------------------------------------------
$scriptDistant = {
    # Tout dans des variables avant de construire l'objet (une redirection dans un
    # [pscustomobject]@{...} casse la construction)
    $sessions = @()
    $lignesQuser = @()
    try { $lignesQuser = quser } catch { }

    foreach ($ligne in ($lignesQuser | Select-Object -Skip 1)) {
        $champs = ($ligne.Trim() -replace '\s{2,}', '|').Split('|')
        if ($champs.Count -ge 3) {
            $sessions += [pscustomobject]@{
                Utilisateur = $champs[0].TrimStart('>')
                Etat        = if ($champs.Count -ge 4) { $champs[3] } else { "?" }
                Inactif     = if ($champs.Count -ge 5) { $champs[4] } else { "" }
            }
        }
    }

    $actif = $sessions | Where-Object { $_.Etat -match "Actif|Active" } | Select-Object -First 1
    $nomActif = if ($actif) { $actif.Utilisateur } else { "" }

    # Logiciels avec une fenetre visible, pour l'utilisateur connecte
    $apps = @()
    try {
        $apps = Get-Process -IncludeUserName -ErrorAction SilentlyContinue |
            Where-Object { $_.MainWindowTitle -ne "" -and $_.UserName -like "*$nomActif*" } |
            ForEach-Object { "$($_.ProcessName) - $($_.MainWindowTitle)" } |
            Select-Object -Unique
    } catch { }

    # Contenu du dossier de depot de l'eleve connecte
    $devoirs = @()
    if ($nomActif -ne "") {
        $dossierDepot = "C:\Depots\$nomActif"
        if (Test-Path $dossierDepot) {
            $devoirs = Get-ChildItem $dossierDepot -File -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending |
                ForEach-Object { "$($_.Name) ($([math]::Round($_.Length / 1KB)) Ko)" }
        }
    }

    [pscustomobject]@{
        Sessions = ($sessions | ForEach-Object { "$($_.Utilisateur) [$($_.Etat)] inactif:$($_.Inactif)" })
        Connecte = $nomActif
        Apps     = $apps
        Devoirs  = $devoirs
    }
}

# ---------------------------------------------------------------------------
# Boucle d'actualisation
# ---------------------------------------------------------------------------
Write-Host "Tableau de bord actif. Page : $fichierHtml" -ForegroundColor Cyan
Write-Host "Raccourcis de prise de controle : $dossierControle" -ForegroundColor Cyan
Write-Host "Ctrl+C pour arreter." -ForegroundColor Yellow

$premierPassage = $true

while ($true) {
    $cartes = ""

    foreach ($machine in $machines) {
        $ip = $machine.PosteActuel.Trim()
        $nom = $machine.NouveauNom.Trim()

        $enLigne = Test-NetConnection -ComputerName $ip -Port 5985 -InformationLevel Quiet -WarningAction SilentlyContinue

        if (-not $enLigne) {
            $cartes += @"
<div class="poste hors-ligne">
  <h2>$nom <span class="pastille rouge"></span></h2>
  <p class="ip">$ip</p>
  <p class="vide">Poste eteint ou injoignable</p>
</div>
"@
            continue
        }

        try {
            $infos = Invoke-Command -ComputerName $ip -Credential $credential -ScriptBlock $scriptDistant -ErrorAction Stop

            $connecte = if ($infos.Connecte) { $infos.Connecte } else { "personne" }
            $classeConnecte = if ($infos.Connecte) { "connecte" } else { "libre" }

            $listeApps = if ($infos.Apps -and $infos.Apps.Count -gt 0) {
                ($infos.Apps | ForEach-Object { "<li>" + [System.Web.HttpUtility]::HtmlEncode($_) + "</li>" }) -join ""
            } else { "<li class='vide'>aucune fenetre ouverte</li>" }

            $listeDevoirs = if ($infos.Devoirs -and $infos.Devoirs.Count -gt 0) {
                ($infos.Devoirs | ForEach-Object { "<li>" + [System.Web.HttpUtility]::HtmlEncode($_) + "</li>" }) -join ""
            } else { "<li class='vide'>rien rendu</li>" }

            $cartes += @"
<div class="poste">
  <h2>$nom <span class="pastille verte"></span></h2>
  <p class="ip">$ip</p>
  <p class="$classeConnecte">$connecte</p>
  <h3>Logiciels ouverts</h3>
  <ul>$listeApps</ul>
  <h3>Devoirs rendus</h3>
  <ul>$listeDevoirs</ul>
</div>
"@
        } catch {
            $cartes += @"
<div class="poste erreur">
  <h2>$nom <span class="pastille orange"></span></h2>
  <p class="ip">$ip</p>
  <p class="vide">Erreur de lecture</p>
</div>
"@
        }
    }

    $horodatage = Get-Date -Format "HH:mm:ss"

    $html = @"
<!doctype html>
<html lang="fr">
<head>
<meta charset="utf-8">
<meta http-equiv="refresh" content="$intervalleSecondes">
<title>Tableau de bord - Classe</title>
<style>
  body { font-family: Segoe UI, sans-serif; background:#12141a; color:#e6e8ee; margin:0; padding:24px; }
  header { display:flex; justify-content:space-between; align-items:baseline; margin-bottom:20px; }
  h1 { font-size:22px; margin:0; }
  .maj { color:#8b90a0; font-size:14px; }
  .grille { display:grid; grid-template-columns:repeat(auto-fill,minmax(280px,1fr)); gap:16px; }
  .poste { background:#1b1e27; border:1px solid #2a2f3d; border-radius:10px; padding:16px; }
  .poste.hors-ligne { opacity:.5; }
  .poste.erreur { border-color:#7a5620; }
  h2 { font-size:17px; margin:0 0 2px; display:flex; align-items:center; gap:8px; }
  h3 { font-size:12px; text-transform:uppercase; color:#8b90a0; margin:14px 0 6px; letter-spacing:.04em; }
  .ip { color:#6c7185; font-size:12px; margin:0 0 10px; }
  .connecte { color:#5fd18c; font-weight:600; margin:0; }
  .libre { color:#6c7185; margin:0; }
  ul { margin:0; padding-left:18px; font-size:13px; line-height:1.5; }
  li.vide, p.vide { color:#6c7185; font-style:italic; list-style:none; margin-left:-18px; }
  p.vide { margin:0; }
  .pastille { width:9px; height:9px; border-radius:50%; display:inline-block; }
  .verte { background:#5fd18c; } .rouge { background:#e0574b; } .orange { background:#d99a3a; }
</style>
</head>
<body>
<header>
  <h1>Tableau de bord - Classe</h1>
  <span class="maj">Mis a jour a $horodatage - actualisation toutes les $intervalleSecondes s</span>
</header>
<div class="grille">
$cartes
</div>
</body>
</html>
"@

    $html | Out-File -FilePath $fichierHtml -Encoding UTF8

    if ($premierPassage) {
        Start-Process $fichierHtml
        $premierPassage = $false
    }

    Write-Host "[$horodatage] Actualise." -ForegroundColor DarkGray
    Start-Sleep -Seconds $intervalleSecondes
}
