# Applique des réglages machine-wide (HKLM, valables pour TOUS les comptes, présents et futurs)
# sur chaque poste, via PowerShell Remoting. Contrairement aux tweaks WinUtil lancés depuis un
# profil (HKCU), ceux-ci n'ont pas besoin d'être refaits à chaque nouveau compte élève.
#
# Réglages appliqués :
#   - Désactive Cortana (intégration recherche)
#   - Désactive le bouton/la fonctionnalité Windows Copilot
#   - Désactive le Centre de notifications / notifications
#   - Désactive l'écran "paramètres de confidentialité" (localisation, partage de données...)
#     qui apparaît à CHAQUE première connexion d'un nouveau compte (DisablePrivacyExperience)
#   - Désactive l'animation de première connexion + les suggestions d'apps/pubs (CloudContent)
#   - Force le retrait des paquets Xbox encore provisionnés (corrige les postes où le retrait
#     initial via WinUtil a échoué silencieusement, ex: Totoro)
# + vérifie si Microsoft Edge est encore présent (il n'est pas concerné par ces clés : ce n'est
#   pas une AppX, donc s'il traîne encore, sa suppression WinUtil n'a pas tenu sur ce poste).

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
    function Set-Policy($path, $name, $value) {
        if (-not (Test-Path $path)) {
            New-Item -Path $path -Force | Out-Null
        }
        New-ItemProperty -Path $path -Name $name -Value $value -PropertyType DWord -Force | Out-Null
    }

    Set-Policy "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" "AllowCortana" 0
    Set-Policy "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot" "TurnOffWindowsCopilot" 1
    Set-Policy "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer" "DisableNotificationCenter" 1
    Set-Policy "HKLM:\SOFTWARE\Policies\Microsoft\Windows\OOBE" "DisablePrivacyExperience" 1
    Set-Policy "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" "EnableFirstLogonAnimation" 0
    Set-Policy "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" "DisableWindowsConsumerFeatures" 1
    # Empêche le thème/Windows Spotlight de réimposer son propre fond d'écran par-dessus celui
    # qu'on définit dans bureau_raccourcis.ps1 (constaté via diagnostic : WallpaperSetFromTheme=1)
    Set-Policy "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" "DisableSpotlightCollectionOnDesktop" 1

    $xboxRestants = Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -like "*Xbox*" }
    $xboxSupprimes = @()
    foreach ($paquet in $xboxRestants) {
        try {
            Remove-AppxProvisionedPackage -Online -PackageName $paquet.PackageName -ErrorAction Stop | Out-Null
            $xboxSupprimes += $paquet.DisplayName
        } catch {
            $xboxSupprimes += "$($paquet.DisplayName) : ÉCHEC - $_"
        }
    }

    $edgePresent = Test-Path "$env:ProgramFiles(x86)\Microsoft\Edge\Application\msedge.exe"

    [pscustomobject]@{
        EdgePresent   = $edgePresent
        XboxSupprimes = $xboxSupprimes
    }
}

foreach ($poste in $postes) {
    Write-Host "=== $poste ===" -ForegroundColor Cyan
    try {
        $resultat = Invoke-Command -ComputerName $poste -Credential $credential -ScriptBlock $scriptDistant -ErrorAction Stop
        Write-Host "  Policies appliquées (Cortana, Copilot, notifications, confidentialité, première connexion)." -ForegroundColor Green
        if ($resultat.XboxSupprimes.Count -gt 0) {
            foreach ($x in $resultat.XboxSupprimes) {
                Write-Host "  Xbox déprovisionné: $x" -ForegroundColor Green
            }
        }
        if ($resultat.EdgePresent) {
            Write-Host "  Edge est toujours présent sur ce poste (pas concerné par ces policies, à traiter séparément)." -ForegroundColor Yellow
        } else {
            Write-Host "  Edge absent." -ForegroundColor Green
        }
    } catch {
        Write-Host "  ÉCHEC sur $poste : $_" -ForegroundColor Red
    }
}
