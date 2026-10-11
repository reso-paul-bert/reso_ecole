# Diagnostic des compteurs reseau : affiche les cartes vues sur un poste, leur etat tel que
# Windows le nomme, et les compteurs bruts. Sert a comprendre pourquoi le tableau de bord
# afficherait zero.

$fichierMapping = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "renommage.csv"

if (-not (Test-Path $fichierMapping)) {
    Write-Host "ERREUR: renommage.csv introuvable." -ForegroundColor Red
    exit 1
}

$machines = Import-Csv -Path $fichierMapping -Encoding UTF8 |
    Where-Object { $_.PosteActuel.Trim() -ne "" -and $_.PosteActuel -notlike "<*>*" }

Write-Host "Postes connus :" -ForegroundColor Yellow
$machines | ForEach-Object { Write-Host "   $($_.NouveauNom.Trim()) = $($_.PosteActuel.Trim())" }

$poste = Read-Host "Adresse IP du poste a tester"
$credential = Get-Credential -Message "Compte administrateur local - saisis .\NomDuCompte"

Invoke-Command -ComputerName $poste -Credential $credential -ScriptBlock {

    $toutes = Get-NetAdapter -ErrorAction SilentlyContinue |
        Select-Object Name, InterfaceDescription, Status, InterfaceOperationalStatus,
                      @{n = 'Physique'; e = { -not $_.Virtual } }

    $physiques = Get-NetAdapter -Physical -ErrorAction SilentlyContinue

    $stats = foreach ($carte in $physiques) {
        $s = Get-NetAdapterStatistics -Name $carte.Name -ErrorAction SilentlyContinue
        [pscustomobject]@{
            Carte     = $carte.Name
            Statut    = $carte.Status
            RecuMo    = if ($s) { [math]::Round($s.ReceivedBytes / 1MB, 1) } else { "n/a" }
            EnvoyeMo  = if ($s) { [math]::Round($s.SentBytes / 1MB, 1) } else { "n/a" }
        }
    }

    # Ce que le tableau de bord calcule aujourd'hui, avec son filtre sur le mot "Up"
    $filtrees = Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
        Where-Object { $_.Status -eq "Up" -and $_.InterfaceDescription -notmatch "Tailscale" }

    # Repli utilise quand le pilote n'alimente pas Get-NetAdapterStatistics
    $compteursPerf = Get-CimInstance Win32_PerfRawData_Tcpip_NetworkInterface -ErrorAction SilentlyContinue
    $repli = foreach ($carte in $filtrees) {
        $instance = $carte.InterfaceDescription.Replace('(', '[').Replace(')', ']').Replace('#', '_').Replace('/', '_').Replace('\', '_')
        $perf = $compteursPerf | Where-Object { $_.Name -eq $instance } | Select-Object -First 1
        [pscustomobject]@{
            Carte    = $carte.Name
            Instance = $instance
            Trouvee  = [bool]$perf
            RecuMo   = if ($perf) { [math]::Round($perf.BytesReceivedPersec / 1MB, 1) } else { "n/a" }
            EnvoyeMo = if ($perf) { [math]::Round($perf.BytesSentPersec / 1MB, 1) } else { "n/a" }
        }
    }

    [pscustomobject]@{
        ToutesLesCartes     = ($toutes | Format-Table -AutoSize | Out-String)
        CompteursPhysiques  = ($stats | Format-Table -AutoSize | Out-String)
        RetenuesParLeFiltre = if ($filtrees) { ($filtrees.Name -join ", ") } else { "AUCUNE - c'est la cause du zero" }
        CompteursDeRepli    = ($repli | Format-List | Out-String)
        InstancesDisponibles = (($compteursPerf | ForEach-Object { $_.Name }) -join " | ")
    }
} | Format-List
