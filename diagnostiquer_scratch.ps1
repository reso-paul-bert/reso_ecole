# Diagnostic ponctuel : localise où Scratch Desktop est réellement installé sur un poste,
# pour savoir si c'est une install machine-wide (Program Files, visible pour tous) ou
# per-user (AppData d'un seul compte, invisible pour les autres).

$poste = "100.105.210.38"

$fichierCredential = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "admin_credential.xml"
if (Test-Path $fichierCredential) {
    $credential = Import-Clixml -Path $fichierCredential
} else {
    $credential = Get-Credential -Message "Compte administrateur local - saisis .\NomDuCompte"
}

Invoke-Command -ComputerName $poste -Credential $credential -ScriptBlock {
    $emplacements = @(
        "C:\Program Files\Scratch 3",
        "C:\Program Files (x86)\Scratch 3",
        "C:\ProgramData\Microsoft\Windows\Start Menu\Programs"
    )

    $resultat = [ordered]@{}
    $resultat["ProgramFiles"] = Test-Path "C:\Program Files\Scratch 3"
    $resultat["ProgramFilesX86"] = Test-Path "C:\Program Files (x86)\Scratch 3"

    $dossiersUtilisateurs = Get-ChildItem "C:\Users" -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path (Join-Path $_.FullName "AppData\Local\Programs\Scratch 3") }
    $resultat["AppDataParUtilisateur"] = ($dossiersUtilisateurs.Name -join ", ")

    [pscustomobject]$resultat
} | Format-List
