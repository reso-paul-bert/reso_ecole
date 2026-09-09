# Diagnostic : affiche les permissions reelles sur C:\Depots et sur le dossier d'un eleve.

$fichierMapping = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "renommage.csv"

if (-not (Test-Path $fichierMapping)) {
    Write-Host "ERREUR: renommage.csv introuvable." -ForegroundColor Red
    exit 1
}

$postes = Import-Csv -Path $fichierMapping -Encoding UTF8 | ForEach-Object { $_.PosteActuel.Trim() } | Where-Object { $_ -ne "" -and $_ -notlike "<*>*" }
$poste = $postes | Select-Object -First 1

Write-Host "Poste cible : $poste" -ForegroundColor Cyan

$credential = Get-Credential -Message "Compte administrateur local - saisis .\NomDuCompte"

Invoke-Command -ComputerName $poste -Credential $credential -ScriptBlock {
    # Tout calculer dans des variables AVANT de construire l'objet : une redirection 2>&1 placee
    # directement dans un [pscustomobject]@{...} casse la construction de l'objet.
    $racine = "C:\Depots"
    $racineExiste = Test-Path $racine
    $sousDossiers = @(Get-ChildItem $racine -Directory -ErrorAction SilentlyContinue)
    $noms = ($sousDossiers | Select-Object -First 5 | ForEach-Object { $_.Name }) -join " | "

    $aclRacine = icacls $racine
    $aclRacineTexte = $aclRacine -join "`n"

    $premier = $sousDossiers | Select-Object -First 1
    if ($premier) {
        $cheminEleve = $premier.FullName
        $aclEleve = icacls $cheminEleve
        $aclEleveTexte = $aclEleve -join "`n"
    } else {
        $cheminEleve = "aucun"
        $aclEleveTexte = "n/a"
    }

    $membres = (Get-LocalGroupMember -Group "Eleves" -ErrorAction SilentlyContinue | Select-Object -First 3 | ForEach-Object { $_.Name }) -join " | "

    [pscustomobject]@{
        RacineExiste    = $racineExiste
        NbSousDossiers  = $sousDossiers.Count
        NomsSousDossier = $noms
        AclRacine       = $aclRacineTexte
        CheminEleve     = $cheminEleve
        AclEleve        = $aclEleveTexte
        MembresEleves   = $membres
    }
} | Format-List
