# Crée le dossier racine C:\Depots sur chaque poste. Les élèves peuvent y NAVIGUER (traverser)
# mais pas en lister le contenu - donc pas moyen de voir la liste des autres élèves. Chaque élève
# a ensuite son propre sous-dossier privé, créé automatiquement par deployer_utilisateurs.ps1.
#
# Utilise les SID universels pour Administrateurs/SYSTEM (indépendant de la langue du système).

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
    $dossier = "C:\Depots"
    New-Item -Path $dossier -ItemType Directory -Force | Out-Null

    if (-not (Get-LocalGroup -Name "Eleves" -ErrorAction SilentlyContinue)) {
        New-LocalGroup -Name "Eleves" -Description "Comptes élèves" | Out-Null
    }

    icacls $dossier /inheritance:r | Out-Null
    icacls $dossier /grant:r "*S-1-5-18:(OI)(CI)(F)" | Out-Null
    icacls $dossier /grant:r "*S-1-5-32-544:(OI)(CI)(F)" | Out-Null
    icacls $dossier /grant:r "Enseignant:(OI)(CI)(F)" | Out-Null
    # (X) seul = peut traverser/entrer dans un sous-dossier où il a par ailleurs un accès explicite,
    # mais ne peut PAS lister le contenu de C:\Depots lui-même (donc pas voir les autres élèves).
    icacls $dossier /grant "Eleves:(X)" | Out-Null

    # Ancien raccourci qui tentait d'OUVRIR le dossier : impossible, l'Explorateur exige le droit
    # de lister le contenu (refuse aux eleves). Remplace par un selecteur de fichier.
    Remove-Item "C:\Users\Public\Desktop\Mes devoirs.lnk" -Force -ErrorAction SilentlyContinue
    Remove-Item "C:\Depots\_OuvrirMonDossier.bat" -Force -ErrorAction SilentlyContinue

    # Script de depot : double-clic = fenetre de selection de fichier ; glisser-deposer sur l'icone
    # = depot direct des fichiers laches dessus. L'Explorateur n'ouvre jamais le dossier de depot,
    # donc le refus de lecture ne gene pas.
    $scriptDepot = "C:\Depots\_Deposer.ps1"
    $contenu = @'
Add-Type -AssemblyName System.Windows.Forms

# Extensions acceptees. Sans cette liste, n'importe quel fichier peut etre rendu, y compris un
# executable pris ailleurs sur le disque. Ajouter une extension ici si un logiciel de classe
# produit un format absent.
$extensionsAutorisees = @(
    '.odt','.ods','.odp','.odg','.doc','.docx','.xls','.xlsx','.ppt','.pptx','.pdf','.rtf','.txt','.csv',
    '.jpg','.jpeg','.png','.gif','.bmp','.webp','.svg',
    '.mp3','.wav','.mp4','.avi','.mkv',
    # Scratch : .sb3 = projet, .sprite3 = lutin exporte, .sb/.sb2 = anciennes versions
    '.sb3','.sb2','.sb','.sprite3',
    '.py','.html','.css','.js','.zip'
)

$destination = "C:\Depots\$env:USERNAME"
$fichiers = @()

$filtre = "Devoirs|" + (($extensionsAutorisees | ForEach-Object { "*$_" }) -join ";")

if ($args.Count -gt 0) {
    $fichiers = $args | Where-Object { Test-Path $_ -PathType Leaf }
} else {
    $dialogue = New-Object System.Windows.Forms.OpenFileDialog
    $dialogue.Title = "Choisis le devoir a rendre"
    $dialogue.Multiselect = $true
    $dialogue.Filter = $filtre
    $dialogue.InitialDirectory = [Environment]::GetFolderPath("Desktop")
    if ($dialogue.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $fichiers = $dialogue.FileNames
    }
}

if ($fichiers.Count -eq 0) { return }

# Verification cote script : le filtre du dialogue est contournable (nom tape a la main) et ne
# s'applique pas du tout au glisser-deposer.
$refuses = $fichiers | Where-Object { $extensionsAutorisees -notcontains [System.IO.Path]::GetExtension($_).ToLower() }
$fichiers = $fichiers | Where-Object { $extensionsAutorisees -contains [System.IO.Path]::GetExtension($_).ToLower() }

if ($refuses.Count -gt 0) {
    $noms = ($refuses | ForEach-Object { [System.IO.Path]::GetFileName($_) }) -join ", "
    [System.Windows.Forms.MessageBox]::Show("Ce type de fichier ne peut pas etre rendu : $noms", "Fichier refuse", "OK", "Warning") | Out-Null
}

if ($fichiers.Count -eq 0) { return }

$horodatage = Get-Date -Format "yyyy-MM-dd_HH-mm"
$reussis = 0
$echecs = @()

foreach ($fichier in $fichiers) {
    $nom = [System.IO.Path]::GetFileNameWithoutExtension($fichier)
    $ext = [System.IO.Path]::GetExtension($fichier)
    # Horodatage dans le nom : chaque depot cree un nouveau fichier, l'eleve ne peut donc pas
    # ecraser un travail deja rendu (il n'a de toute facon pas le droit de supprimer).
    $cible = Join-Path $destination "$nom`_$horodatage$ext"
    try {
        Copy-Item -LiteralPath $fichier -Destination $cible -ErrorAction Stop
        $reussis++
    } catch {
        $echecs += [System.IO.Path]::GetFileName($fichier)
    }
}

if ($echecs.Count -eq 0) {
    [System.Windows.Forms.MessageBox]::Show("$reussis devoir(s) rendu(s). C'est bon !", "Devoir rendu", "OK", "Information") | Out-Null
} else {
    [System.Windows.Forms.MessageBox]::Show("Probleme avec : $($echecs -join ', ')`n`nPreviens ton enseignant.", "Erreur", "OK", "Warning") | Out-Null
}
'@
    Set-Content -Path $scriptDepot -Value $contenu -Encoding UTF8

    icacls $scriptDepot /inheritance:r | Out-Null
    icacls $scriptDepot /grant:r "*S-1-5-18:(F)" | Out-Null
    icacls $scriptDepot /grant:r "*S-1-5-32-544:(F)" | Out-Null
    icacls $scriptDepot /grant:r "Enseignant:(F)" | Out-Null
    icacls $scriptDepot /grant:r "Eleves:(RX)" | Out-Null

    # Le raccourci n'est PAS pose dans le Public Desktop : il y serait visible par tout le monde,
    # Enseignant compris. Il est copie dans le profil Default (donc tout futur compte) et dans le
    # bureau de chaque compte eleve deja existant.
    Remove-Item "C:\Users\Public\Desktop\Deposer mon devoir.lnk" -Force -ErrorAction SilentlyContinue

    $shell = New-Object -ComObject WScript.Shell

    function New-RaccourciDepot($dossierBureau) {
        if (-not (Test-Path $dossierBureau)) { return $false }
        $lnk = $shell.CreateShortcut((Join-Path $dossierBureau "Deposer mon devoir.lnk"))
        $lnk.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
        $lnk.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptDepot`""
        $lnk.IconLocation = "%SystemRoot%\System32\shell32.dll,45"
        $lnk.WindowStyle = 7
        $lnk.Save()
        return $true
    }

    # Futurs comptes
    $bureauDefault = "C:\Users\Default\Desktop"
    New-Item -Path $bureauDefault -ItemType Directory -Force | Out-Null
    New-RaccourciDepot $bureauDefault | Out-Null

    # Comptes eleves deja crees : identifies par leur appartenance au groupe Eleves
    $poses = 0
    $membres = Get-LocalGroupMember -Group "Eleves" -ErrorAction SilentlyContinue
    foreach ($membre in $membres) {
        $nomCompte = ($membre.Name -split '\\')[-1]
        if (New-RaccourciDepot "C:\Users\$nomCompte\Desktop") { $poses++ }
    }

    "Raccourci pose dans le profil Default et sur $poses bureau(x) eleve(s) sur $(@($membres).Count) compte(s)."
    (icacls $dossier) -join "`n"
}

foreach ($poste in $postes) {
    Write-Host "=== $poste ===" -ForegroundColor Cyan
    try {
        $resultat = Invoke-Command -ComputerName $poste -Credential $credential -ScriptBlock $scriptDistant -ErrorAction Stop
        Write-Host $resultat -ForegroundColor Green
    } catch {
        Write-Host "  ÉCHEC sur $poste : $_" -ForegroundColor Red
    }
}
