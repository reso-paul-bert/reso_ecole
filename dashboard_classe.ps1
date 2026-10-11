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

    # Compteurs de la carte reseau physique. Tailscale est exclu : son trafic transite deja par
    # le Wi-Fi et serait compte deux fois.
    $recu = 0
    $envoye = 0
    try {
        $compteursPerf = $null

        $cartes = Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
            Where-Object { $_.Status -eq "Up" -and $_.InterfaceDescription -notmatch "Tailscale" }

        foreach ($carte in $cartes) {
            $stats = Get-NetAdapterStatistics -Name $carte.Name -ErrorAction SilentlyContinue
            if ($stats) {
                $recu += $stats.ReceivedBytes
                $envoye += $stats.SentBytes
                continue
            }

            # Certains pilotes Wi-Fi anciens n'alimentent pas Get-NetAdapterStatistics (constate
            # sur Realtek RTL8723AE). Les compteurs de performance TCP/IP, eux, repondent : malgre
            # leur nom "PerSec", les valeurs brutes sont des totaux cumules depuis le demarrage.
            if (-not $compteursPerf) {
                $compteursPerf = Get-CimInstance Win32_PerfRawData_Tcpip_NetworkInterface -ErrorAction SilentlyContinue
            }

            # Le nom d'instance d'un compteur derive de la description de la carte, avec quelques
            # caracteres substitues par Windows.
            $instance = $carte.InterfaceDescription.Replace('(', '[').Replace(')', ']').Replace('#', '_').Replace('/', '_').Replace('\', '_')
            $perf = $compteursPerf | Where-Object { $_.Name -eq $instance } | Select-Object -First 1

            if ($perf) {
                $recu += $perf.BytesReceivedPersec
                $envoye += $perf.BytesSentPersec
            }
        }
    } catch { }

    [pscustomobject]@{
        Connecte = $nomActif
        Apps     = $apps
        Devoirs  = $devoirs
        Recu     = $recu
        Envoye   = $envoye
    }
}

# Test-NetConnection met plus d'une seconde par poste, meme quand il repond. Une connexion TCP
# brute avec delai court donne la meme information en quelques millisecondes.
function Test-Port($ip, $numeroPort, $delaiMs = 700) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $tentative = $client.BeginConnect($ip, $numeroPort, $null, $null)
        if (-not $tentative.AsyncWaitHandle.WaitOne($delaiMs)) { return $false }
        $client.EndConnect($tentative)
        return $true
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

# Les sessions sont conservees d'une actualisation a l'autre : ouvrir une session WinRM coute
# une a trois secondes, ce qui dominait entierement le temps de collecte.
$sessions = @{}

# Repere de consommation reseau, pris au premier releve et remis a zero par le bouton dedie.
# Les compteurs de Windows comptent depuis le demarrage du poste ; sans repere, ils melangeraient
# le cours en cours avec tout ce qui a precede.
$reperesReseau = @{}

function Formater-Octets($octets) {
    if ($octets -ge 1GB) { return "{0:N1} Go" -f ($octets / 1GB) }
    if ($octets -ge 1MB) { return "{0:N0} Mo" -f ($octets / 1MB) }
    return "{0:N0} Ko" -f ($octets / 1KB)
}

function Obtenir-Session($ip) {
    $existante = $sessions[$ip]
    if ($existante -and $existante.State -eq "Opened") { return $existante }

    if ($existante) {
        Remove-PSSession $existante -ErrorAction SilentlyContinue
        $sessions.Remove($ip)
    }

    try {
        $nouvelle = New-PSSession -ComputerName $ip -Credential $credential -ErrorAction Stop
        $sessions[$ip] = $nouvelle
        return $nouvelle
    } catch {
        return $null
    }
}

function Lire-Etat {
    $exclus = @(Lire-Exclusions)
    $resultats = @{}
    $aInterroger = @()

    foreach ($machine in $machines) {
        $ip = $machine.PosteActuel.Trim()
        $nom = $machine.NouveauNom.Trim()

        if (-not (Test-Port $ip 5985)) {
            $resultats[$ip] = [pscustomobject]@{ Nom = $nom; Ip = $ip; Etat = "hors-ligne" }
            continue
        }

        $session = Obtenir-Session $ip
        if ($session) {
            $aInterroger += $session
        } else {
            $resultats[$ip] = [pscustomobject]@{ Nom = $nom; Ip = $ip; Etat = "erreur" }
        }
    }

    # Un seul appel pour tous les postes : Invoke-Command interroge les sessions en parallele,
    # la collecte dure donc le temps du poste le plus lent et non la somme des sept.
    if ($aInterroger.Count -gt 0) {
        $reponses = Invoke-Command -Session $aInterroger -ScriptBlock $scriptEtat -ArgumentList (, $exclus) -ErrorAction SilentlyContinue

        foreach ($reponse in $reponses) {
            $ip = $reponse.PSComputerName
            $nom = ($machines | Where-Object { $_.PosteActuel.Trim() -eq $ip } | Select-Object -First 1).NouveauNom.Trim()

            # Premier releve, ou compteurs repartis de zero apres un redemarrage du poste
            if (-not $reperesReseau.ContainsKey($ip) -or
                $reponse.Recu -lt $reperesReseau[$ip].Recu -or
                $reponse.Envoye -lt $reperesReseau[$ip].Envoye) {
                $reperesReseau[$ip] = [pscustomobject]@{ Recu = $reponse.Recu; Envoye = $reponse.Envoye }
            }

            $resultats[$ip] = [pscustomobject]@{
                Nom      = $nom
                Ip       = $ip
                Etat     = "ok"
                Connecte = $reponse.Connecte
                Apps     = @($reponse.Apps)
                Devoirs  = @($reponse.Devoirs)
                Recu     = $reponse.Recu - $reperesReseau[$ip].Recu
                Envoye   = $reponse.Envoye - $reperesReseau[$ip].Envoye
            }
        }
    }

    # Remise dans l'ordre du fichier, et postes sans reponse marques en erreur
    return $machines | ForEach-Object {
        $ip = $_.PosteActuel.Trim()
        if ($resultats.ContainsKey($ip)) {
            $resultats[$ip]
        } else {
            [pscustomobject]@{ Nom = $_.NouveauNom.Trim(); Ip = $ip; Etat = "erreur" }
        }
    }
}

# ---------------------------------------------------------------------------
# Recuperation des devoirs
# ---------------------------------------------------------------------------
# $eleve vide = tous les eleves du poste ; sinon uniquement ce compte.
function Recuperer-Devoirs($ip, $nomPoste, $eleve) {
    $racineDestination = Join-Path $dossierDevoirs $nomPoste
    New-Item -Path $racineDestination -ItemType Directory -Force | Out-Null

    $session = Obtenir-Session $ip
    if (-not $session) { return -1 }

    $archiveLocale = Join-Path $env:TEMP "depots_$nomPoste.zip"
    Remove-Item $archiveLocale -Force -ErrorAction SilentlyContinue

    try {
        # L'archive est construite sur le poste : un seul transfert au lieu d'un par fichier.
        # WinRM encode tout en Base64, donc chaque transfert coute cher quelle que soit la taille.
        $paquet = Invoke-Command -Session $session -ScriptBlock {
            param($filtre)

            $racine = "C:\Depots"
            $cible = if ($filtre) { Join-Path $racine $filtre } else { $racine }
            if (-not (Test-Path $cible)) { return $null }

            # Les devoirs vivent toujours dans un sous-dossier au nom de l'eleve. Ce qui traine a
            # la racine appartient au dispositif lui-meme (_Deposer.ps1) et ne doit jamais etre
            # ramasse : il serait emporte, puis supprime, privant les eleves de tout depot.
            $fichiers = Get-ChildItem $cible -File -Recurse -ErrorAction SilentlyContinue |
                Where-Object { $_.Directory.FullName -ne $racine }

            if (@($fichiers).Count -eq 0) { return $null }

            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $zip = Join-Path $env:TEMP "depots_$([Guid]::NewGuid().ToString('N')).zip"
            $archive = [System.IO.Compression.ZipFile]::Open($zip, 'Create')

            $contenu = @()
            foreach ($fichier in $fichiers) {
                # Chemin relatif a C:\Depots : l'archive porte donc <Eleve>\<fichier>, ce qui
                # reconstitue l'arborescence a l'extraction, que l'on vise un eleve ou tous.
                $relatif = $fichier.FullName.Substring($racine.Length + 1)
                [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $fichier.FullName, $relatif) | Out-Null
                $contenu += [pscustomobject]@{
                    Relatif = $relatif
                    Complet = $fichier.FullName
                    Taille  = $fichier.Length
                }
            }
            $archive.Dispose()

            [pscustomobject]@{ Archive = $zip; Contenu = $contenu }
        } -ArgumentList $eleve

        if (-not $paquet) { return 0 }

        Copy-Item -FromSession $session -Path $paquet.Archive -Destination $archiveLocale -Force -ErrorAction Stop
        Expand-Archive -Path $archiveLocale -DestinationPath $racineDestination -Force -ErrorAction Stop

        # Rien n'est supprime sur le poste avant d'avoir verifie chaque fichier extrait.
        $copies = 0
        $aSupprimer = @()
        foreach ($entree in $paquet.Contenu) {
            $local = Join-Path $racineDestination $entree.Relatif
            if ((Test-Path $local) -and (Get-Item $local).Length -eq $entree.Taille) {
                $copies++
                $aSupprimer += $entree.Complet
            }
        }

        Invoke-Command -Session $session -ScriptBlock {
            param($liste, $zip)
            foreach ($chemin in $liste) { Remove-Item -Path $chemin -Force -ErrorAction SilentlyContinue }
            Remove-Item -Path $zip -Force -ErrorAction SilentlyContinue
        } -ArgumentList $aSupprimer, $paquet.Archive

        return $copies
    } catch {
        return -1
    } finally {
        Remove-Item $archiveLocale -Force -ErrorAction SilentlyContinue
    }
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

        $reseau = "<p class='reseau'>&darr; $(Formater-Octets $poste.Recu) &nbsp; &uarr; $(Formater-Octets $poste.Envoye)</p>"

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
  $reseau
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

    $totalRecu = ($etat | Where-Object { $_.Etat -eq "ok" } | Measure-Object -Property Recu -Sum).Sum
    $totalEnvoye = ($etat | Where-Object { $_.Etat -eq "ok" } | Measure-Object -Property Envoye -Sum).Sum
    $totalReseau = "Forfait consomme depuis la remise a zero : &darr; $(Formater-Octets $totalRecu) &nbsp; &uarr; $(Formater-Octets $totalEnvoye)"

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
  .reseau { color:#9aa0b4; font-size:12px; margin:6px 0 0; font-variant-numeric:tabular-nums; }
  .total { color:#9aa0b4; font-size:13px; margin:0 0 16px; font-variant-numeric:tabular-nums; }
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
    <a class="bouton" href="/reseau-zero">Compteurs reseau a zero</a>
    <a class="bouton" href="/?force=1">Actualiser</a>
  </div>
</header>
<p class="maj">Mis a jour a $horodatage - actualisation automatique toutes les $intervalleSecondes s</p>
<p class="total">$totalReseau</p>
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
        "/reseau-zero" {
            $reperesReseau.Clear()
            $etat = Lire-Etat
            $dateEtat = Get-Date
            $message = "Compteurs reseau remis a zero."
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
    $sessions.Values | ForEach-Object { Remove-PSSession $_ -ErrorAction SilentlyContinue }
    Write-Host "Tableau de bord arrete, port $port libere." -ForegroundColor Cyan
}
