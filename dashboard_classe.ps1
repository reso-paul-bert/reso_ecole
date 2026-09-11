# Tableau de bord classe : page web locale montrant qui est connecte, quelles applications sont
# ouvertes et ce qui a ete rendu, avec des boutons pour recuperer les devoirs.
#
# A lancer depuis le PC enseignant, EN ADMINISTRATEUR (necessaire pour ouvrir le port local).
# Garder la fenetre PowerShell ouverte tant que le tableau de bord sert.
#
# Limitation connue : la session WinRM tourne en session 0, isolee du bureau de l'eleve. Les
# titres de fenetres (et donc les sites web consultes) y sont toujours vides. Seuls les noms
# des applications sont remontes.

$port = 8099
$intervalleSecondes = 30

Add-Type -AssemblyName System.Web

$dossierScript = Split-Path -Parent $MyInvocation.MyCommand.Path
$fichierMapping = Join-Path $dossierScript "renommage.csv"
$dossierDevoirs = Join-Path $dossierScript "Devoirs_Recuperes"

if (-not (Test-Path $fichierMapping)) {
    Write-Host "ERREUR: renommage.csv introuvable." -ForegroundColor Red
    exit 1
}

$machines = Import-Csv -Path $fichierMapping -Encoding UTF8 |
    Where-Object { $_.PosteActuel.Trim() -ne "" -and $_.PosteActuel -notlike "<*>*" }

$credential = Get-Credential -Message "Compte administrateur local - saisis .\NomDuCompte"

New-Item -Path $dossierDevoirs -ItemType Directory -Force | Out-Null

# ---------------------------------------------------------------------------
# Raccourcis de prise de controle (shadow RDP : l'eleve n'est PAS deconnecte)
# ---------------------------------------------------------------------------
$dossierControle = Join-Path ([Environment]::GetFolderPath("Desktop")) "Controle_Postes"
New-Item -Path $dossierControle -ItemType Directory -Force | Out-Null
$shell = New-Object -ComObject WScript.Shell

foreach ($machine in $machines) {
    $ip = $machine.PosteActuel.Trim()
    $nom = $machine.NouveauNom.Trim()

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
$fichierExclusions = Join-Path $dossierScript ".appliignore"

# Relu a chaque actualisation : modifier .appliignore ne demande pas de relancer le tableau de bord.
function Lire-Exclusions {
    if (-not (Test-Path $fichierExclusions)) { return @() }
    return Get-Content $fichierExclusions -ErrorAction SilentlyContinue |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -ne "" -and -not $_.StartsWith("#") }
}

$scriptEtat = {
    param($exclus)

    $sessions = @()
    $lignesQuser = @()
    try { $lignesQuser = quser } catch { }

    foreach ($ligne in ($lignesQuser | Select-Object -Skip 1)) {
        $champs = ($ligne.Trim() -replace '\s{2,}', '|').Split('|')
        if ($champs.Count -ge 4) {
            $sessions += [pscustomobject]@{
                Utilisateur = $champs[0].TrimStart('>')
                Etat        = $champs[3]
            }
        }
    }

    $actif = $sessions | Where-Object { $_.Etat -match "Actif|Active" } | Select-Object -First 1
    $nomActif = if ($actif) { $actif.Utilisateur } else { "" }

    $apps = @()
    if ($nomActif -ne "") {
        try {
            $apps = Get-Process -IncludeUserName -ErrorAction SilentlyContinue |
                Where-Object { $_.UserName -and $_.UserName -like "*\$nomActif" -and $exclus -notcontains $_.ProcessName } |
                ForEach-Object { $_.ProcessName } |
                Select-Object -Unique |
                Sort-Object
        } catch { }
    }

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
        Connecte = $nomActif
        Apps     = $apps
        Devoirs  = $devoirs
    }
}

function Lire-Etat {
    $resultats = @()
    $exclus = @(Lire-Exclusions)

    foreach ($machine in $machines) {
        $ip = $machine.PosteActuel.Trim()
        $nom = $machine.NouveauNom.Trim()

        $enLigne = Test-NetConnection -ComputerName $ip -Port 5985 -InformationLevel Quiet -WarningAction SilentlyContinue

        if (-not $enLigne) {
            $resultats += [pscustomobject]@{ Nom = $nom; Ip = $ip; Etat = "hors-ligne" }
            continue
        }

        try {
            $infos = Invoke-Command -ComputerName $ip -Credential $credential -ScriptBlock $scriptEtat -ArgumentList (, $exclus) -ErrorAction Stop
            $resultats += [pscustomobject]@{
                Nom      = $nom
                Ip       = $ip
                Etat     = "ok"
                Connecte = $infos.Connecte
                Apps     = @($infos.Apps)
                Devoirs  = @($infos.Devoirs)
            }
        } catch {
            $resultats += [pscustomobject]@{ Nom = $nom; Ip = $ip; Etat = "erreur" }
        }
    }

    return $resultats
}

# ---------------------------------------------------------------------------
# Recuperation des devoirs
# ---------------------------------------------------------------------------
# $eleve vide = tous les eleves du poste ; sinon uniquement ce compte.
function Recuperer-Devoirs($ip, $nomPoste, $eleve) {
    $racineDestination = Join-Path $dossierDevoirs $nomPoste
    New-Item -Path $racineDestination -ItemType Directory -Force | Out-Null

    $copies = 0
    try {
        $session = New-PSSession -ComputerName $ip -Credential $credential -ErrorAction Stop

        $fichiers = Invoke-Command -Session $session -ScriptBlock {
            param($filtre)
            $racine = "C:\Depots"
            if ($filtre) { $racine = "C:\Depots\$filtre" }
            if (-not (Test-Path $racine)) { return @() }
            Get-ChildItem $racine -File -Recurse -ErrorAction SilentlyContinue
        } -ArgumentList $eleve

        $aSupprimer = @()
        foreach ($fichier in $fichiers) {
            try {
                # Le dossier parent du fichier dans C:\Depots porte le nom du compte eleve
                $nomEleve = Split-Path (Split-Path $fichier.FullName -Parent) -Leaf
                $destination = Join-Path $racineDestination $nomEleve
                New-Item -Path $destination -ItemType Directory -Force | Out-Null

                Copy-Item -FromSession $session -Path $fichier.FullName -Destination $destination -Force -ErrorAction Stop
                $chemin = Join-Path $destination $fichier.Name
                if ((Test-Path $chemin) -and (Get-Item $chemin).Length -eq $fichier.Length) {
                    $copies++
                    $aSupprimer += $fichier.FullName
                }
            } catch { }
        }

        if ($aSupprimer.Count -gt 0) {
            Invoke-Command -Session $session -ScriptBlock {
                param($liste)
                foreach ($chemin in $liste) { Remove-Item -Path $chemin -Force -ErrorAction SilentlyContinue }
            } -ArgumentList (, $aSupprimer)
        }

        Remove-PSSession $session
    } catch {
        return -1
    }

    return $copies
}

# ---------------------------------------------------------------------------
# Page HTML
# ---------------------------------------------------------------------------
function Construire-Html($etat, $message) {
    $cartes = ""

    foreach ($poste in $etat) {
        $nom = [System.Web.HttpUtility]::HtmlEncode($poste.Nom)

        if ($poste.Etat -eq "hors-ligne") {
            $cartes += "<div class='poste hors-ligne'><h2>$nom <span class='pastille rouge'></span></h2><p class='ip'>$($poste.Ip)</p><p class='vide'>Poste eteint ou injoignable</p></div>"
            continue
        }
        if ($poste.Etat -eq "erreur") {
            $cartes += "<div class='poste erreur'><h2>$nom <span class='pastille orange'></span></h2><p class='ip'>$($poste.Ip)</p><p class='vide'>Erreur de lecture</p></div>"
            continue
        }

        $connecte = if ($poste.Connecte) { [System.Web.HttpUtility]::HtmlEncode($poste.Connecte) } else { "personne" }
        $classe = if ($poste.Connecte) { "connecte" } else { "libre" }

        $listeApps = if ($poste.Apps.Count -gt 0) {
            ($poste.Apps | ForEach-Object { "<li>" + [System.Web.HttpUtility]::HtmlEncode($_) + "</li>" }) -join ""
        } else { "<li class='vide'>aucune application</li>" }

        $listeDevoirs = if ($poste.Devoirs.Count -gt 0) {
            ($poste.Devoirs | ForEach-Object { "<li>" + [System.Web.HttpUtility]::HtmlEncode($_) + "</li>" }) -join ""
        } else { "<li class='vide'>rien rendu</li>" }

        $bouton = if ($poste.Connecte) {
            "<a class='bouton' href='/recuperer?poste=$([uri]::EscapeDataString($poste.Nom))&eleve=$([uri]::EscapeDataString($poste.Connecte))'>Recuperer les devoirs de cet eleve</a>"
        } else {
            "<span class='bouton inactif'>Personne connecte</span>"
        }

        $cartes += @"
<div class="poste">
  <h2>$nom <span class="pastille verte"></span></h2>
  <p class="ip">$($poste.Ip)</p>
  <p class="$classe">$connecte</p>
  <h3>Applications ouvertes</h3>
  <ul>$listeApps</ul>
  <h3>Devoirs en attente</h3>
  <ul>$listeDevoirs</ul>
  $bouton
</div>
"@
    }

    $blocMessage = if ($message) { "<div class='message'>" + [System.Web.HttpUtility]::HtmlEncode($message) + "</div>" } else { "" }
    $horodatage = Get-Date -Format "HH:mm:ss"

    return @"
<!doctype html>
<html lang="fr">
<head>
<meta charset="utf-8">
<meta http-equiv="refresh" content="$intervalleSecondes">
<title>Tableau de bord - Classe</title>
<style>
  body { font-family: Segoe UI, sans-serif; background:#12141a; color:#e6e8ee; margin:0; padding:24px; }
  header { display:flex; justify-content:space-between; align-items:center; gap:16px; flex-wrap:wrap; margin-bottom:18px; }
  h1 { font-size:22px; margin:0; }
  .maj { color:#8b90a0; font-size:13px; }
  .actions { display:flex; gap:10px; }
  .grille { display:grid; grid-template-columns:repeat(auto-fill,minmax(290px,1fr)); gap:16px; }
  .poste { background:#1b1e27; border:1px solid #2a2f3d; border-radius:10px; padding:16px; display:flex; flex-direction:column; }
  .poste.hors-ligne { opacity:.5; }
  .poste.erreur { border-color:#7a5620; }
  h2 { font-size:17px; margin:0 0 2px; display:flex; align-items:center; gap:8px; }
  h3 { font-size:11px; text-transform:uppercase; color:#8b90a0; margin:14px 0 6px; letter-spacing:.05em; }
  .ip { color:#6c7185; font-size:12px; margin:0 0 10px; }
  .connecte { color:#5fd18c; font-weight:600; margin:0; }
  .libre { color:#6c7185; margin:0; }
  ul { margin:0; padding-left:18px; font-size:13px; line-height:1.5; }
  li.vide, p.vide { color:#6c7185; font-style:italic; list-style:none; margin-left:-18px; }
  p.vide { margin:0; }
  .pastille { width:9px; height:9px; border-radius:50%; display:inline-block; }
  .verte { background:#5fd18c; } .rouge { background:#e0574b; } .orange { background:#d99a3a; }
  .bouton { display:inline-block; margin-top:14px; padding:8px 12px; border-radius:7px; background:#2d5bd7;
            color:#fff; text-decoration:none; font-size:13px; text-align:center; }
  .bouton:hover { background:#3b6ae8; }
  .bouton.principal { background:#1f9d55; }
  .bouton.principal:hover { background:#25b763; }
  .bouton.inactif { background:#242938; color:#6c7185; }
  .message { background:#16301f; border:1px solid #2b5e3c; color:#8ee0ab; padding:11px 14px;
             border-radius:8px; margin-bottom:16px; font-size:14px; }
</style>
</head>
<body>
<header>
  <h1>Tableau de bord - Classe</h1>
  <div class="actions">
    <a class="bouton principal" href="/recuperer-tout">Tout recuperer</a>
    <a class="bouton" href="/?force=1">Actualiser</a>
  </div>
</header>
<p class="maj">Mis a jour a $horodatage - actualisation automatique toutes les $intervalleSecondes s</p>
$blocMessage
<div class="grille">
$cartes
</div>
</body>
</html>
"@
}

# ---------------------------------------------------------------------------
# Serveur local
# ---------------------------------------------------------------------------
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$port/")

try {
    $listener.Start()
} catch {
    Write-Host "ERREUR: impossible d'ouvrir le port $port." -ForegroundColor Red

    $occupant = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if ($occupant) {
        $processus = Get-Process -Id $occupant.OwningProcess -ErrorAction SilentlyContinue
        Write-Host "Le port est deja utilise par : $($processus.ProcessName) (PID $($occupant.OwningProcess))" -ForegroundColor Yellow
        Write-Host "C'est probablement un tableau de bord deja lance. Pour le fermer :" -ForegroundColor Yellow
        Write-Host "   Stop-Process -Id $($occupant.OwningProcess) -Force" -ForegroundColor White
    } else {
        Write-Host "Aucun processus ne detient ce port : il s'agit donc d'un refus de Windows." -ForegroundColor Yellow
        Write-Host "Relance cette fenetre PowerShell EN TANT QU'ADMINISTRATEUR." -ForegroundColor Yellow
    }
    exit 1
}

Write-Host "Tableau de bord : http://localhost:$port/" -ForegroundColor Cyan
Write-Host "Raccourcis de prise de controle : $dossierControle" -ForegroundColor Cyan
Write-Host "Ctrl+C pour arreter." -ForegroundColor Yellow

$etat = Lire-Etat
$dateEtat = Get-Date
$message = ""

Start-Process "http://localhost:$port/"

try {

while ($listener.IsListening) {
    # Attente asynchrone plutot que GetContext() bloquant : celui-ci ne rend jamais la main a
    # PowerShell, ce qui rendait Ctrl+C inoperant. Ici l'attente se reveille toutes les 300 ms,
    # laissant l'interruption etre prise en compte.
    $attente = $listener.BeginGetContext($null, $null)
    while (-not $attente.AsyncWaitHandle.WaitOne(300)) { }
    $contexte = $listener.EndGetContext($attente)

    $chemin = $contexte.Request.Url.AbsolutePath
    $parametres = $contexte.Request.QueryString

    $redirection = $false

    switch ($chemin) {
        "/recuperer" {
            $nomPoste = $parametres["poste"]
            $eleve = $parametres["eleve"]
            $machine = $machines | Where-Object { $_.NouveauNom.Trim() -eq $nomPoste } | Select-Object -First 1
            if ($machine) {
                Write-Host "Recuperation : $eleve sur $nomPoste..." -ForegroundColor Cyan
                $n = Recuperer-Devoirs $machine.PosteActuel.Trim() $nomPoste $eleve
                $message = if ($n -lt 0) { "Echec de connexion a $nomPoste." }
                           elseif ($n -eq 0) { "Rien a recuperer pour $eleve." }
                           else { "$n fichier(s) recupere(s) pour $eleve ($nomPoste)." }
            }
            $etat = Lire-Etat
            $dateEtat = Get-Date
            $redirection = $true
        }
        "/recuperer-tout" {
            Write-Host "Recuperation complete..." -ForegroundColor Cyan
            $total = 0
            $echecs = @()
            foreach ($machine in $machines) {
                $nomPoste = $machine.NouveauNom.Trim()
                $n = Recuperer-Devoirs $machine.PosteActuel.Trim() $nomPoste ""
                if ($n -lt 0) { $echecs += $nomPoste } else { $total += $n }
            }
            $message = "$total fichier(s) recupere(s) au total."
            if ($echecs.Count -gt 0) { $message += " Postes injoignables : " + ($echecs -join ", ") + "." }
            $etat = Lire-Etat
            $dateEtat = Get-Date
            $redirection = $true
        }
        default {
            if ($parametres["force"] -eq "1" -or ((Get-Date) - $dateEtat).TotalSeconds -ge $intervalleSecondes) {
                $etat = Lire-Etat
                $dateEtat = Get-Date
            }
        }
    }

    if ($redirection) {
        $contexte.Response.StatusCode = 303
        $contexte.Response.RedirectLocation = "/"
        $contexte.Response.Close()
        continue
    }

    $html = Construire-Html $etat $message
    $message = ""

    $octets = [System.Text.Encoding]::UTF8.GetBytes($html)
    $contexte.Response.ContentType = "text/html; charset=utf-8"
    $contexte.Response.ContentLength64 = $octets.Length
    $contexte.Response.OutputStream.Write($octets, 0, $octets.Length)
    $contexte.Response.Close()
}

} finally {
    # Libere le port meme en cas d'interruption, sinon la prochaine execution le trouve occupe.
    if ($listener.IsListening) { $listener.Stop() }
    $listener.Close()
    Write-Host "Tableau de bord arrete, port $port libere." -ForegroundColor Cyan
}
