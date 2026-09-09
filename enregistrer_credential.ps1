# À lancer UNE FOIS : enregistre le compte admin local dans un fichier chiffré (DPAPI), réutilisé
# ensuite automatiquement par tous les autres scripts. Le chiffrement est lié à TON compte Windows
# ET à CE PC précis : le fichier est illisible copié ailleurs ou ouvert par quelqu'un d'autre.
#
# Si ce PC cesse d'être le PC admin (ex: tu passes sur le PC admin définitif), relance ce script
# là-bas pour y recréer le fichier - celui d'ici ne fonctionnera pas sur une autre machine/compte.

$fichierCredential = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "admin_credential.xml"

Get-Credential -Message "Compte administrateur local (le même sur tous les postes élèves) - saisis .\NomDuCompte" |
    Export-Clixml -Path $fichierCredential

Write-Host "Identifiants enregistrés dans $fichierCredential" -ForegroundColor Green
