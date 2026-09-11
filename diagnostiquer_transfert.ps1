# Diagnostic du transfert des devoirs : execute chaque etape separement en la chronometrant,
# pour voir laquelle bloque. La copie tourne en tache de fond pendant que la taille du fichier
# de destination est affichee en direct : si elle progresse, le transfert est lent mais
# fonctionnel ; si elle stagne, il est reellement bloque.
#
# Ce script ne SUPPRIME rien : les devoirs restent en place sur le poste.
# A lancer dans une deuxieme fenetre PowerShell, en parallele du tableau de bord.

$dossierScript = Split-Path -Parent $MyInvocation.MyCommand.Path
$fichierMapping = Join-Path $dossierScript "renommage.csv"
$dossierTest = Join-Path $env:TEMP "test_transfert"

$dureeMaxCopie = 180   # secondes avant d'abandonner la copie de test

function Etape($texte) {
    Write-Host ""
    Write-Host ">>> $texte" -ForegroundColor Cyan
}

# --- Choix du poste -------------------------------------------------------
if (Test-Path $fichierMapping) {
    $machines = Import-Csv -Path $fichierMapping -Encoding UTF8 |
        Where-Object { $_.PosteActuel.Trim() -ne "" -and $_.PosteActuel -notlike "<*>*" }
    Write-Host "Postes connus :" -ForegroundColor Yellow
    $machines | ForEach-Object { Write-Host "   $($_.NouveauNom.Trim()) = $($_.PosteActuel.Trim())" }
}

$poste = Read-Host "Adresse IP du poste a tester"
$eleve = Read-Host "Nom du compte eleve (vide = Eleve01__PaulBert)"
if ([string]::IsNullOrWhiteSpace($eleve)) { $eleve = "Eleve01__PaulBert" }

$credential = Get-Credential -Message "Compte administrateur local - saisis .\NomDuCompte"

# --- 1. Reseau ------------------------------------------------------------
Etape "1. Test du port WinRM (5985)"
$chrono = [Diagnostics.Stopwatch]::StartNew()
$ouvert = Test-NetConnection -ComputerName $poste -Port 5985 -InformationLevel Quiet -WarningAction SilentlyContinue
Write-Host "    Resultat : $ouvert  (en $([math]::Round($chrono.Elapsed.TotalSeconds,1)) s)"
if (-not $ouvert) {
    Write-Host "    Le poste ne repond pas sur WinRM. Inutile d'aller plus loin." -ForegroundColor Red
    exit 1
}

# --- 2. Ouverture de session ---------------------------------------------
Etape "2. Ouverture d'une session distante"
$chrono.Restart()
try {
    $session = New-PSSession -ComputerName $poste -Credential $credential -ErrorAction Stop
    Write-Host "    Session ouverte en $([math]::Round($chrono.Elapsed.TotalSeconds,1)) s" -ForegroundColor Green
} catch {
    Write-Host "    ECHEC : $_" -ForegroundColor Red
    exit 1
}

# --- 3. Liste des fichiers -----------------------------------------------
Etape "3. Liste des devoirs de $eleve"
$chrono.Restart()
$fichiers = Invoke-Command -Session $session -ScriptBlock {
    param($nom)
    $dossier = "C:\Depots\$nom"
    if (-not (Test-Path $dossier)) { return @() }
    Get-ChildItem $dossier -File -Recurse -ErrorAction SilentlyContinue |
        Select-Object FullName, Name, Length
} -ArgumentList $eleve

Write-Host "    Obtenu en $([math]::Round($chrono.Elapsed.TotalSeconds,1)) s"
Write-Host "    Nombre de fichiers : $(@($fichiers).Count)"
foreach ($f in $fichiers) {
    Write-Host "       $($f.Name)  -  $([math]::Round($f.Length/1MB,2)) Mo"
}

if (@($fichiers).Count -eq 0) {
    Write-Host "    Aucun fichier a transferer : le blocage ne vient pas de la copie." -ForegroundColor Yellow
    Remove-PSSession $session
    exit 0
}

# --- 4. Copie de test avec suivi en direct -------------------------------
$cible = $fichiers | Sort-Object Length -Descending | Select-Object -First 1
$tailleMo = [math]::Round($cible.Length / 1MB, 2)

Etape "4. Copie de test du plus gros fichier : $($cible.Name) ($tailleMo Mo)"
Write-Host "    (copie vers $dossierTest, rien n'est supprime sur le poste)"

New-Item -Path $dossierTest -ItemType Directory -Force | Out-Null
$destination = Join-Path $dossierTest $cible.Name
Remove-Item $destination -Force -ErrorAction SilentlyContinue

Remove-PSSession $session

# La copie tourne dans une tache separee : la session distante n'etant pas transmissible
# a une tache de fond, celle-ci ouvre la sienne.
$tache = Start-Job -ScriptBlock {
    param($poste, $credential, $source, $destination)
    $s = New-PSSession -ComputerName $poste -Credential $credential
    Copy-Item -FromSession $s -Path $source -Destination $destination -Force
    Remove-PSSession $s
} -ArgumentList $poste, $credential, $cible.FullName, $destination

$chrono.Restart()
$taillePrecedente = -1
$stagnation = 0

while ($tache.State -eq "Running" -and $chrono.Elapsed.TotalSeconds -lt $dureeMaxCopie) {
    Start-Sleep -Seconds 3
    $taille = if (Test-Path $destination) { (Get-Item $destination).Length } else { 0 }
    $pourcent = if ($cible.Length -gt 0) { [math]::Round(100 * $taille / $cible.Length, 1) } else { 0 }
    $vitesse = if ($chrono.Elapsed.TotalSeconds -gt 0) { [math]::Round(($taille / 1KB) / $chrono.Elapsed.TotalSeconds) } else { 0 }

    Write-Host ("    {0,6:N1} s  -  {1,8:N0} Ko recus  ({2} %)  -  {3} Ko/s" -f `
        $chrono.Elapsed.TotalSeconds, ($taille / 1KB), $pourcent, $vitesse)

    if ($taille -eq $taillePrecedente) { $stagnation++ } else { $stagnation = 0 }
    $taillePrecedente = $taille
}

Write-Host ""
if ($tache.State -eq "Completed") {
    Write-Host "RESULTAT : copie terminee en $([math]::Round($chrono.Elapsed.TotalSeconds,1)) s." -ForegroundColor Green
    Write-Host "Le transfert fonctionne. Si le tableau de bord semble fige, c'est qu'il attend"
    Write-Host "simplement la fin d'un transfert lent (WinRM plafonne a quelques centaines de Ko/s)."
} elseif ($tache.State -eq "Failed") {
    Write-Host "RESULTAT : la copie a echoue." -ForegroundColor Red
    Receive-Job $tache 2>&1 | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
} else {
    Write-Host "RESULTAT : toujours en cours apres $dureeMaxCopie s." -ForegroundColor Yellow
    if ($taillePrecedente -le 0) {
        Write-Host "Aucun octet n'est arrive : le transfert est reellement bloque, pas lent." -ForegroundColor Red
    } elseif ($stagnation -ge 3) {
        Write-Host "La taille ne progresse plus : transfert interrompu en cours de route." -ForegroundColor Red
    } else {
        Write-Host "La taille progresse : le transfert fonctionne, il est juste tres lent." -ForegroundColor Yellow
    }
    Stop-Job $tache
}

Remove-Job $tache -Force -ErrorAction SilentlyContinue
Write-Host ""
Write-Host "Fichier de test : $destination" -ForegroundColor DarkGray
