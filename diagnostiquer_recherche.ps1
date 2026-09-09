# Diagnostic ponctuel : inspecte le NTUSER.DAT d'un compte élève précis à distance (hors ligne,
# sans que le compte soit connecté) pour voir si nos clés de registre Search sont bien présentes,
# et récupère la version/build de Windows sur ce poste.
#
# Assure-toi que le compte ciblé est DÉCONNECTÉ sur ce poste avant de lancer (le hive est
# verrouillé tant que la session est active).

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
    $valeurs = reg query "HKU\DiagTemp\Software\Microsoft\Windows\CurrentVersion\Search" 2>&1

    [gc]::Collect()
    reg unload HKU\DiagTemp 2>&1 | Out-Null

    [pscustomobject]@{
        Chargement     = $chargement -join "`n"
        ValeursSearch  = $valeurs -join "`n"
        DisplayVersion = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').DisplayVersion
        CurrentBuild   = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuild
    }
} -ArgumentList $nomCompte | Format-List
