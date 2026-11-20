#Requires -Version 5.1
<#
Benchmark reproductible pour OpenCode + Ollama, Windows PowerShell 5.1.
Version 1.3 : suivi des fins prematurees, reprises de session limitees,
comparaison premier passage vs autonomie assistee, traces JSONL par passage.
Projet source : Benchmark_PREFA_14B_vs_MoE.zip.
ATTENTION : -AutoApprove autorise automatiquement les outils OpenCode.
Ne lancer que sur cette archive de demonstration, dans un environnement de confiance.
Exemple : powershell.exe -NoProfile -ExecutionPolicy Bypass -File D:\IA\Tests\Benchmark-OpenCode-LLM.ps1 -Repetitions 1 -AutoApprove
#>
[CmdletBinding()]
param(
    [ValidateRange(1,10)][int]$Repetitions = 1,
    [ValidateRange(0,8)][int]$RelancesMax = 3,
    [ValidateRange(3,90)][int]$TimeoutMinutes = 20,
    [string]$ArchivePath = 'D:\IA\Tests\Benchmark_PREFA_14B_vs_MoE.zip',
    [string]$OutputRoot = 'D:\IA\Benchmarks',
    [switch]$AutoApprove
)
$ErrorActionPreference = 'Stop'

function Assert-Command([string]$Name) {
    $c = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $c) { throw "Commande introuvable : $Name" }
    return $c.Source
}
function Invoke-TestSuite([string]$Root, [string]$Log) {
    # Windows PowerShell 5.1 transforme parfois la sortie stderr de Python en
    # NativeCommandError. Or unittest -v ecrit son rapport sur stderr, meme
    # quand les tests reussissent ! Capturer les flux dans deux fichiers evite
    # que $ErrorActionPreference = 'Stop' interrompe le benchmark.
    $stdoutLog = "$Log.stdout.tmp"
    $stderrLog = "$Log.stderr.tmp"
    $text = ''
    $code = -1
    try {
        $pythonPath = (Get-Command 'python.exe' -ErrorAction Stop).Source
        $process = Start-Process -FilePath $pythonPath `
            -ArgumentList @('-m', 'unittest', 'discover', '-s', 'tests', '-v') `
            -WorkingDirectory $Root `
            -RedirectStandardOutput $stdoutLog `
            -RedirectStandardError $stderrLog `
            -NoNewWindow -Wait -PassThru
        $code = $process.ExitCode
        $stdoutText = if (Test-Path -LiteralPath $stdoutLog) { Get-Content -LiteralPath $stdoutLog -Raw } else { '' }
        $stderrText = if (Test-Path -LiteralPath $stderrLog) { Get-Content -LiteralPath $stderrLog -Raw } else { '' }
        $text = "$stdoutText`r`n$stderrText"
    } finally {
        Remove-Item -LiteralPath $stdoutLog, $stderrLog -Force -ErrorAction SilentlyContinue
    }
    $text | Set-Content -LiteralPath $Log -Encoding UTF8
    $run = [regex]::Match($text, 'Ran\s+(\d+)\s+tests?')
    $fails = [regex]::Match($text, 'FAILED\s*\(failures=(\d+)')
    $errors = [regex]::Match($text, 'errors=(\d+)')
    $count = if ($run.Success) { [int]$run.Groups[1].Value } else { -1 }
    $failCount = if ($fails.Success) { [int]$fails.Groups[1].Value } else { 0 }
    $errorCount = if ($errors.Success) { [int]$errors.Groups[1].Value } else { 0 }
    return [pscustomobject]@{
        ExitCode = $code
        Total = $count
        Failures = $failCount
        Errors = $errorCount
        AllPassed = (($code -eq 0) -and ($count -eq 15) -and ($text -match '(?m)^OK\s*$'))
    }
}
function Get-FileSignature([string]$Root, [string]$Subfolder) {
    $base = Join-Path $Root $Subfolder
    if (-not (Test-Path -LiteralPath $base)) { return @() }
    $result = @()
    foreach ($file in (Get-ChildItem -LiteralPath $base -Recurse -File | Sort-Object FullName)) {
        $rel = $file.FullName.Substring($Root.TrimEnd('\').Length + 1)
        # Ignore uniquement les artefacts Python generes automatiquement par les tests.
        # Conserve la verification SHA256 de tous les autres fichiers, y compris les
        # ajouts et suppressions dans tests/ (pas seulement les modifications).
        if ($rel -match '(^|[\\/])(__pycache__|\.pytest_cache)([\\/]|$)') { continue }
        if ($file.Extension -in @('.pyc', '.pyo')) { continue }
        $result += ('{0}:{1}' -f $rel, (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash)
    }
    return @($result)
}
function Unload-TestModels {
    foreach ($name in @('qwen3-opencode', 'qwen36-moe:16k')) {
        try {
            $data = @{ model = $name; keep_alive = 0 } | ConvertTo-Json -Compress
            $null = Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/generate' -Method Post -ContentType 'application/json' -Body $data -TimeoutSec 40
        } catch { Write-Warning "Dechargement de $name non confirme : $($_.Exception.Message)" }
    }
    Start-Sleep -Seconds 2
}
function Warm-TestModel([string]$Model) {
    $body = @{
        model = $Model
        prompt = 'Reponds OK.'
        stream = $false
        keep_alive = '30m'
        options = @{ num_predict = 8; num_ctx = 16384 }
    } | ConvertTo-Json -Depth 6 -Compress
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $response = Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/generate' -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 360
    $timer.Stop()
    if ($response.error) { throw "Echec du prechauffage : $($response.error)" }
    return [math]::Round($timer.Elapsed.TotalSeconds, 2)
}
function Get-GpuSnapshot {
    $smi = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue
    if (-not $smi) { return '' }
    try {
        $r = & $smi.Source --query-gpu=utilization.gpu,memory.used,temperature.gpu,power.draw --format=csv,noheader,nounits 2>$null
        return (($r | Select-Object -First 1) -join '')
    } catch { return '' }
}

if (-not $AutoApprove) {
    throw 'Pour un benchmark autonome, ajouter -AutoApprove. Attention : les commandes et ecritures demandees par l agent seront approuvees automatiquement. Utiliser uniquement sur des copies de test.'
}
if (-not (Test-Path -LiteralPath $ArchivePath -PathType Leaf)) { throw "Archive introuvable : $ArchivePath" }
$null = Assert-Command 'opencode.cmd'
$null = Assert-Command 'ollama.exe'
$null = Assert-Command 'python.exe'
try { $null = Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/tags' -TimeoutSec 10 }
catch { throw 'Ollama ne repond pas sur http://127.0.0.1:11434' }

$models = @(
    [pscustomobject]@{ Label = '14B'; Cli = 'ollama/qwen3-opencode'; Ollama = 'qwen3-opencode'; Folder = 'Bench-14B' },
    [pscustomobject]@{ Label = 'MoE'; Cli = 'ollama/qwen36-moe:16k'; Ollama = 'qwen36-moe:16k'; Folder = 'Bench-MoE' }
)
$modelsText = (& opencode.cmd models ollama | Out-String)
foreach ($m in $models) {
    if ($modelsText -notmatch [regex]::Escape($m.Cli)) { throw "Modele non configure dans OpenCode : $($m.Cli)" }
}

$session = '{0}-{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), ([guid]::NewGuid().ToString('N').Substring(0, 6))
$sessionDir = Join-Path $OutputRoot $session
New-Item -ItemType Directory -Path $sessionDir -Force | Out-Null
$resultsCsv = Join-Path $sessionDir 'resultats.csv'
$allResults = New-Object System.Collections.Generic.List[object]

# Consigne STRICTEMENT identique pour les deux modeles et toutes les repetitions.
$prompt = @'
Analyse cette application Python de calcul de panneaux en beton prefabrique.
Le projet contient 15 tests automatises, dont 7 echouent actuellement.
Ta mission : identifier les causes des erreurs ; corriger les calculs de geometrie, masses, levage et rapports ; ne modifier AUCUN fichier du dossier tests ; conserver les fonctionnalites existantes.
Utilise tes outils pour analyser et modifier reellement le code. Execute python -m unittest discover -s tests -v apres correction.
Objectif : 15 tests reussis, aucune erreur. Travaille de maniere autonome jusqu'a ce resultat ou explique ce qui bloque.
Termine par un bilan des fichiers modifies et des corrections effectuees. Ne modifie rien en dehors du dossier de travail et ne contacte aucun service externe.
'@

# Worker : une invocation CLI par passage; chaque passage conserve son JSONL.
# --session reutilise la MEME session OpenCode, pas un nouveau chat.
$workerScript = Join-Path $sessionDir '_opencode_worker.ps1'
$worker = @'
param([Parameter(Mandatory=$true)][string]$ConfigFile)
$ErrorActionPreference = 'Continue'
$cfg = Get-Content -LiteralPath $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
$prompt = Get-Content -LiteralPath $cfg.promptPath -Raw -Encoding UTF8
Set-Location -LiteralPath $cfg.workdir
$cliArgs = @('run', '--dir', [string]$cfg.workdir, '-m', [string]$cfg.model, '--pure', '--auto', '--format', 'json')
if ($cfg.sessionID) {
    $cliArgs += @('--session', [string]$cfg.sessionID)
} else {
    $cliArgs += @('--title', [string]$cfg.title)
}
$cliArgs += @($prompt)
& opencode.cmd @cliArgs 2>&1 | Out-File -LiteralPath $cfg.agentLog -Encoding UTF8
exit $LASTEXITCODE
'@
$worker | Set-Content -LiteralPath $workerScript -Encoding UTF8
$promptFile = Join-Path $sessionDir 'consigne-identique.txt'
$prompt | Set-Content -LiteralPath $promptFile -Encoding UTF8
$followupFile = Join-Path $sessionDir 'relance-identique.txt'
@'
La mission initiale n'est pas terminee : la verification independante n'a pas obtenu 15 tests OK.
Poursuis les corrections dans cette MEME session et ce MEME dossier. Ne reponds pas par une simple analyse.
Modifie uniquement les modules metier sous prefa/, sans modifier tests/ ni README.md.
Execute python -m unittest discover -s tests -v et ne termine que lorsque les 15 tests reussissent, ou explique le blocage concret.
'@ | Set-Content -LiteralPath $followupFile -Encoding UTF8

Write-Host "RESULTATS : $sessionDir" -ForegroundColor Cyan
Write-Host 'Arreter le minage et fermer les autres agents avant de continuer.' -ForegroundColor Yellow
Write-Host 'Deux metriques distinctes : 1er passage (sans aide) et resolution apres relances (assistance automatique).' -ForegroundColor Yellow
Write-Host 'Chronometre : temps de bout en bout des passages OpenCode + controles intermediaires, sans copie ni prechauffage.'

try {
for ($i = 1; $i -le $Repetitions; $i++) {
    $order = if (($i % 2) -eq 1) { $models } else { @($models[1], $models[0]) }
    foreach ($m in $order) {
        $id = '{0}-essai-{1:00}' -f $m.Label, $i
        $caseDir = Join-Path $sessionDir $id
        New-Item -ItemType Directory -Path $caseDir -Force | Out-Null
        Expand-Archive -LiteralPath $ArchivePath -DestinationPath $caseDir -Force
        $workdir = Join-Path $caseDir $m.Folder
        if (-not (Test-Path -LiteralPath (Join-Path $workdir 'tests\test_prefa.py'))) { throw "Projet source non conforme : $workdir" }
        $beforeTests = Get-FileSignature -Root $workdir -Subfolder 'tests'
        $beforeReadme = (Get-FileHash -LiteralPath (Join-Path $workdir 'README.md') -Algorithm SHA256).Hash
        $baseline = Invoke-TestSuite -Root $workdir -Log (Join-Path $caseDir 'tests-avant.txt')
        if (($baseline.Total -ne 15) -or ($baseline.Failures -ne 7) -or ($baseline.Errors -ne 0)) {
            throw "Base incorrecte pour $id : $($baseline.Total) tests, $($baseline.Failures) echecs, $($baseline.Errors) erreurs."
        }
        Unload-TestModels
        Write-Host "`n[$id] Prechauffage $($m.Ollama)..." -ForegroundColor Cyan
        $warmSec = Warm-TestModel -Model $m.Ollama
        $gpuBefore = Get-GpuSnapshot
        $gpuSamples = New-Object System.Collections.Generic.List[string]
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $start = Get-Date
        $timedOut = $false
        $sessionID = ''
        $exitCode = -2
        $passages = 0
        $lastTestedPassage = 0
        $premierPassageOK = $false
        $premierPassageTests = -1
        $after = $null
        $testsUntouched = $false
        $readmeUntouched = $false

        for ($round = 0; $round -le $RelancesMax; $round++) {
            if ($watch.Elapsed.TotalMinutes -ge $TimeoutMinutes) { $timedOut = $true; break }
            $num = $round + 1
            $configFile = Join-Path $caseDir ('worker-config-{0:00}.json' -f $num)
            $agentLog = Join-Path $caseDir ('opencode-events-{0:00}.jsonl' -f $num)
            $whichPrompt = if ($round -eq 0) { $promptFile } else { $followupFile }
            @{
                workdir = $workdir; model = $m.Cli; title = "Benchmark $id";
                promptPath = $whichPrompt; agentLog = $agentLog; sessionID = $sessionID
            } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $configFile -Encoding UTF8
            Write-Host "[$id] Passage $num : chrono en cours (limite globale $TimeoutMinutes min)." -ForegroundColor Yellow
            $args = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "{0}" -ConfigFile "{1}"' -f $workerScript, $configFile
            $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $args -WorkingDirectory $workdir -WindowStyle Hidden -PassThru
            $passages++
            while (-not $proc.HasExited) {
                if ($watch.Elapsed.TotalMinutes -ge $TimeoutMinutes) {
                    $timedOut = $true
                    & taskkill.exe /PID $proc.Id /T /F 2>$null | Out-Null
                    break
                }
                $snapshot = Get-GpuSnapshot
                if ($snapshot) { $gpuSamples.Add(('{0:o},{1}' -f (Get-Date), $snapshot)) }
                if ($proc.WaitForExit(3000)) { break }
                $proc.Refresh()
            }
            $proc.Refresh()
            $exitCode = if ($timedOut) { -1 } elseif ($proc.HasExited) { $proc.ExitCode } else { -2 }
            if ($timedOut) { break }

            # La session est donnee par le flux de JSONL de OpenCode.
            if (Test-Path -LiteralPath $agentLog) {
                try {
                    $firstEvent = Get-Content -LiteralPath $agentLog -TotalCount 1 -Encoding UTF8 | ConvertFrom-Json
                    if ($firstEvent.sessionID) { $sessionID = [string]$firstEvent.sessionID }
                } catch { Write-Warning "[$id] Impossible de lire l'ID de session au passage $num." }
            }

            $after = Invoke-TestSuite -Root $workdir -Log (Join-Path $caseDir ('tests-apres-passage-{0:00}.txt' -f $num))
            $lastTestedPassage = $num
            $afterTests = Get-FileSignature -Root $workdir -Subfolder 'tests'
            $testsUntouched = ((@($beforeTests) -join "`n") -ceq (@($afterTests) -join "`n"))
            $readmeUntouched = ((Get-FileHash -LiteralPath (Join-Path $workdir 'README.md') -Algorithm SHA256).Hash -ceq $beforeReadme)
            $nbOK = if ($after.Total -eq 15) {15 - $after.Failures - $after.Errors} else {0}
            if ($round -eq 0) {
                $premierPassageTests = $nbOK
                $premierPassageOK = ($after.AllPassed -and $testsUntouched -and $readmeUntouched -and ($exitCode -eq 0))
            }
            Write-Host "[$id] Passage $num : $nbOK/15 ; sortie OpenCode $exitCode ; session $sessionID" -ForegroundColor Cyan
            if ($after.AllPassed) { break }
            if ($exitCode -ne 0) { Write-Warning "[$id] OpenCode en erreur : pas de relance."; break }
            if (-not $sessionID) { Write-Warning "[$id] ID de session manquant : pas de relance."; break }
            if (-not $testsUntouched -or -not $readmeUntouched) { Write-Warning "[$id] Fichiers proteges modifies : abandon."; break }
        }
        $watch.Stop()
        $finish = Get-Date
        $gpuSamples | Set-Content -LiteralPath (Join-Path $caseDir 'gpu-samples.csv') -Encoding UTF8
        if ($null -eq $after) {
            $after = Invoke-TestSuite -Root $workdir -Log (Join-Path $caseDir 'tests-apres.txt')
        } else {
            Copy-Item -LiteralPath (Join-Path $caseDir ('tests-apres-passage-{0:00}.txt' -f $lastTestedPassage)) -Destination (Join-Path $caseDir 'tests-apres.txt') -Force
        }
        $afterTests = Get-FileSignature -Root $workdir -Subfolder 'tests'
        $testsUntouched = ((@($beforeTests) -join "`n") -ceq (@($afterTests) -join "`n"))
        $readmeUntouched = ((Get-FileHash -LiteralPath (Join-Path $workdir 'README.md') -Algorithm SHA256).Hash -ceq $beforeReadme)
        $state = if ($timedOut) { 'TIMEOUT' }
                 elseif (($exitCode -eq 0) -and $after.AllPassed -and $testsUntouched -and $readmeUntouched) { 'SUCCES' }
                 elseif ($after.AllPassed -and -not $testsUntouched) { 'TESTS_MODIFIES' }
                 elseif ($after.AllPassed -and -not $readmeUntouched) { 'README_MODIFIE' }
                 elseif ($after.AllPassed) { 'TESTS_OK_AGENT_ERREUR' }
                 else { 'ECHEC' }
        $row = [pscustomobject]@{
            DateDebut = $start.ToString('s'); Modele = $m.Label; IdModele = $m.Cli; Essai = $i;
            TempsAgentSecondes = [math]::Round($watch.Elapsed.TotalSeconds, 2)
            PrechauffageSecondes = $warmSec; Fin = $finish.ToString('s');
            TestsAvant = $baseline.Total; EchecsAvant = $baseline.Failures;
            TestsApres = $after.Total; EchecsApres = $after.Failures; ErreursApres = $after.Errors;
            TestsTousOK = $after.AllPassed; TestsIntacts = $testsUntouched;
            ReadmeIntact = $readmeUntouched; CodeSortieAgent = $exitCode; Timeout = $timedOut;
            PremierPassageTestsOK = $premierPassageTests; PremierPassageOK = $premierPassageOK;
            Passages = $passages; Relances = [math]::Max(0, $passages - 1);
            Resultat = $state; GpuAvant = $gpuBefore; Dossier = $caseDir
        }
        $allResults.Add($row)
        $allResults | Export-Csv -LiteralPath $resultsCsv -NoTypeInformation -Encoding UTF8 -Delimiter ';'
        Write-Host ('[{0}] {1} s ; passages {2} ; premier passage {3}/15 ; final {4}/15 ; statut {5}' -f $id, $row.TempsAgentSecondes, $passages, $premierPassageTests, (15-$after.Failures-$after.Errors), $state) -ForegroundColor Green
    }
}
} finally {
    Unload-TestModels
}
Write-Host "`nBENCHMARK TERMINE. CSV : $resultsCsv" -ForegroundColor Green
$allResults | Format-Table Modele,Essai,TempsAgentSecondes,PremierPassageTestsOK,Passages,TestsTousOK,Resultat -AutoSize
Write-Host 'Attention : SUCCES au 1er passage != SUCCES apres relances. Comparer ces deux criteres separement.'