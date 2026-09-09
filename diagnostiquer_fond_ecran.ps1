# Diagnostic ponctuel : inspecte le NTUSER.DAT d'un compte précis pour voir l'état réel des
# clés liées au fond d'écran (compte doit être déconnecté - hive verrouillé sinon).

$poste = "100.105.210.38"
$nomCompte = "Eleve01__PaulBert"

$fichierCredential = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "admin_credential.xml"
if (Test-Path $fichierCredential) {
    $credential = Import-Clixml -Path $fichierCredential
} else {
    $credential = Get-Credential -Message "Compte administrateur local - saisis .\NomDuCompte"
}

Invoke-Command -ComputerName $poste -Credential $credential -ScriptBlock {
    param($nom)

    $ntuser = "C:\Users\$nom\NTUSER.DAT"
    if (-not (Test-Path $ntuser)) {
        return [pscustomobject]@{ Erreur = "Profil introuvable : $ntuser" }
    }

    $chargement = reg load HKU\DiagTemp $ntuser 2>&1
    $desktop = reg query "HKU\DiagTemp\Control Panel\Desktop" 2>&1
    $colors = reg query "HKU\DiagTemp\Control Panel\Colors" 2>&1
    $wallpapers = reg query "HKU\DiagTemp\Software\Microsoft\Windows\CurrentVersion\Explorer\Wallpapers" 2>&1
    $themes = reg query "HKU\DiagTemp\Software\Microsoft\Windows\CurrentVersion\Themes" 2>&1

    [gc]::Collect()
    reg unload HKU\DiagTemp 2>&1 | Out-Null

    [pscustomobject]@{
        Chargement = $chargement -join "`n"
        Desktop    = $desktop -join "`n"
        Colors     = $colors -join "`n"
        Wallpapers = $wallpapers -join "`n"
        Themes     = $themes -join "`n"
    }
} -ArgumentList $nomCompte | Format-List
