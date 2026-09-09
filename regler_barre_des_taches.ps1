# Vide la barre des tâches pour TOUT nouveau compte élève (via le profil Default, aucune
# connexion préalable requise) :
#   - Supprime le bouton "Affichage des tâches"
#   - Supprime la barre de recherche
#   - Tente de vider les icônes épinglées par défaut (Courrier, Store, Explorateur de fichiers,
#     Edge) via un LayoutModification.xml vide (PinListPlacement="Replace")
#
# ATTENTION (documenté par Microsoft) : Courrier, Edge, Explorateur de fichiers et Store sont
# officiellement listés comme "non supprimables/non remplaçables" par ce mécanisme. En pratique
# certaines versions de Windows 10 les retirent quand même, d'autres non - pas de garantie à 100%.
# Courrier et Store devraient de toute façon disparaître une fois déprovisionnés par WinUtil.
# Pour l'Explorateur de fichiers, il n'existe pas de méthode fiable connue si celle-ci échoue.

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
    # 1) Bouton Affichage des tâches + barre de recherche : réglages HKCU classiques,
    # appliqués directement dans le hive du profil Default.
    reg load HKU\DefaultTemp "C:\Users\Default\NTUSER.DAT" | Out-Null

    $explorerPath = "Registry::HKEY_USERS\DefaultTemp\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
    New-Item -Path $explorerPath -Force | Out-Null
    New-ItemProperty -Path $explorerPath -Name "ShowTaskViewButton" -Value 0 -PropertyType DWord -Force | Out-Null

    $searchPath = "Registry::HKEY_USERS\DefaultTemp\Software\Microsoft\Windows\CurrentVersion\Search"
    New-Item -Path $searchPath -Force | Out-Null
    New-ItemProperty -Path $searchPath -Name "SearchboxTaskbarMode" -Value 0 -PropertyType DWord -Force | Out-Null
    # Sans celle-ci, Windows réinitialise SearchboxTaskbarMode à l'initialisation d'un nouveau profil
    New-ItemProperty -Path $searchPath -Name "SearchboxTaskbarModeCache" -Value 0 -PropertyType DWord -Force | Out-Null
    # Bundle Search récent (build 22H2) : ce sont ces 2 clés qui pilotent réellement l'affichage,
    # et l'onboarding (OnboardSearchboxOnTaskbar) réécrit sinon SearchboxTaskbarMode tout seul.
    New-ItemProperty -Path $searchPath -Name "TraySearchBoxVisible" -Value 0 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $searchPath -Name "TraySearchBoxVisibleOnAnyMonitor" -Value 0 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $searchPath -Name "OnboardSearchboxOnTaskbar" -Value 0 -PropertyType DWord -Force | Out-Null

    [gc]::Collect()
    reg unload HKU\DefaultTemp | Out-Null

    # 2) Tentative de vidage des icônes épinglées par défaut (Courrier, Store, Explorateur, Edge)
    $shellDir = "C:\Users\Default\AppData\Local\Microsoft\Windows\Shell"
    New-Item -Path $shellDir -ItemType Directory -Force | Out-Null

    $xml = @'
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
      </taskbar:TaskbarPinList>
    </defaultlayout:TaskbarLayout>
  </CustomTaskbarLayoutCollection>
</LayoutModificationTemplate>
'@
    Set-Content -Path (Join-Path $shellDir "LayoutModification.xml") -Value $xml -Encoding UTF8
}

foreach ($poste in $postes) {
    Write-Host "=== $poste ===" -ForegroundColor Cyan
    try {
        Invoke-Command -ComputerName $poste -Credential $credential -ScriptBlock $scriptDistant -ErrorAction Stop
        Write-Host "  Réglages appliqués au profil Default." -ForegroundColor Green
    } catch {
        Write-Host "  ÉCHEC sur $poste : $_" -ForegroundColor Red
    }
}
