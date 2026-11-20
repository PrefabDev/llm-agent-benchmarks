#Requires -Version 5.1
<#
Benchmark reproductible pour OpenCode + Ollama, Windows PowerShell 5.1.
Version 2.0 : grande application (30 fichiers), 40 tests visibles, 21 tests de validation independants.
Creation d un alias 32K sans nouveau telechargement des poids.
Protocole v1.3 conserve : chrono, relances, controle du code et CSV.
Projet source : Benchmark_PREFA_Complexe_V2.zip. Le validateur ne sera extrait qu apres la derniere intervention OpenCode.
ATTENTION : -AutoApprove autorise automatiquement les outils OpenCode.
Ne lancer que sur cette archive de demonstration, idealement en VM : --auto n isole PAS les commandes.
Exemple : powershell.exe -NoProfile -ExecutionPolicy Bypass -File "D:\IA\Tests\Benchmark-PREFA-Complexe-16K-vs-32K.ps1" -Repetitions 1 -RelancesMax 3 -AutoApprove
#>
[CmdletBinding()]
param(
    [ValidateRange(1,10)][int]$Repetitions = 1,
    [ValidateRange(0,8)][int]$RelancesMax = 3,
    [ValidateRange(3,120)][int]$TimeoutMinutes = 35,
    [string]$ArchivePath = 'D:\IA\Tests\Benchmark_PREFA_Complexe_V2.zip',
    [string]$ValidationArchive = 'D:\IA\Tests\Validation_PREFA_Complexe_V2.zip',
    [string]$OutputRoot = 'D:\IA\Benchmarks',
    [switch]$AutoApprove,
    [switch]$PreparationSeulement,
    [switch]$VerificationSeulement
)
$ErrorActionPreference = 'Stop'

function Assert-Command([string]$Name) {
    $c = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $c) { throw "Commande introuvable : $Name" }
    return $c.Source
}
function Invoke-TestSuite([string]$Root, [string]$Log, [string]$TestsDir = "tests", [int]$Expected = 40) {
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
            -ArgumentList @('-m', 'unittest', 'discover', '-s', ('"' + $TestsDir + '"'), '-v') `
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
        AllPassed = (($code -eq 0) -and ($count -eq $Expected) -and ($text -match '(?m)^OK\s*$'))
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
    foreach ($name in @('qwen36-moe:16k', 'qwen36-moe:32k')) {
        try {
            $data = @{ model = $name; keep_alive = 0 } | ConvertTo-Json -Compress
            $null = Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/generate' -Method Post -ContentType 'application/json' -Body $data -TimeoutSec 40
        } catch { Write-Warning "Dechargement de $name non confirme : $($_.Exception.Message)" }
    }
    Start-Sleep -Seconds 2
}
function Warm-TestModel([string]$Model, [int]$Context) {
    $body = @{
        model = $Model
        prompt = 'Reponds OK.'
        stream = $false
        keep_alive = '30m'
        options = @{ num_predict = 8; num_ctx = $Context }
    } | ConvertTo-Json -Depth 6 -Compress
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $response = Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/generate' -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 420
    $timer.Stop()
    if ($response.error) { throw "Echec du prechauffage : $($response.error)" }
    $ps = Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/ps' -TimeoutSec 20
    $loaded = @($ps.models | Where-Object { $_.name -eq $Model -or $_.model -eq $Model } | Select-Object -First 1)
    $activeCtx = -1
    $vramMb = -1
    if ($loaded.Count -gt 0) {
        if ($null -ne $loaded[0].context_length) { $activeCtx = [int]$loaded[0].context_length }
        if ($null -ne $loaded[0].size_vram) { $vramMb = [math]::Round(([double]$loaded[0].size_vram) / 1MB, 0) }
    }
    if ($activeCtx -gt 0 -and $activeCtx -ne $Context) {
        throw "Contexte reel Ollama inattendu pour $Model : $activeCtx (attendu $Context). Benchmark interrompu pour eviter une fausse comparaison."
    }
    if ($activeCtx -lt 0) { Write-Warning "Contexte reel non confirme pour $Model via Ollama /api/ps ; verifier ollama ps." }
    return [pscustomobject]@{
        Seconds = [math]::Round($timer.Elapsed.TotalSeconds, 2)
        Context = $activeCtx
        VramMB = $vramMb
    }
}
function Ensure-MoE32K {
    $base = 'qwen36-moe:16k'
    $newModel = 'qwen36-moe:32k'
    $list = (& ollama.exe list | Out-String)
    if ($list -notmatch '(?m)^qwen36-moe:16k\s') { throw "Modele source manquant : $base. Aucun telechargement automatique ne sera lance." }
    if ($list -match '(?m)^qwen36-moe:32k\s') {
        $modelfile = (& ollama.exe show --modelfile $newModel | Out-String)
        if ($modelfile -notmatch '(?im)^\s*PARAMETER\s+num_ctx\s+32768\b') {
            throw "Le modele $newModel existe deja sans PARAMETER num_ctx 32768. Je refuse de le remplacer automatiquement."
        }
        Write-Host "Modele 32K deja present et parametre correctement : $newModel" -ForegroundColor Green
        return
    }
    $modelfilePath = Join-Path (Split-Path -Parent $ArchivePath) 'bench-moe32k.Modelfile'
    # FROM d un modele local Ollama : reutilise les memes poids, sans retelecharger le GGUF.
    @'
FROM qwen36-moe:16k
PARAMETER num_ctx 32768
'@ | Set-Content -LiteralPath $modelfilePath -Encoding ASCII
    try {
        Write-Host 'Creation de qwen36-moe:32k a partir de l alias 16K existant...' -ForegroundColor Cyan
        # Sous Windows PowerShell 5.1, la progression de Ollama sur stderr
        # peut etre prise pour une erreur. Capturer les flux separement.
        $createOut = "$modelfilePath.stdout.tmp"
        $createErr = "$modelfilePath.stderr.tmp"
        $createProc = Start-Process -FilePath (Get-Command 'ollama.exe').Source `
            -ArgumentList @('create', $newModel, '-f', ('"' + $modelfilePath + '"')) `
            -RedirectStandardOutput $createOut -RedirectStandardError $createErr `
            -NoNewWindow -Wait -PassThru
        if ($createProc.ExitCode -ne 0) {
            $detail = if (Test-Path $createErr) { Get-Content $createErr -Raw } else { '' }
            throw "ollama create a echoue (code $($createProc.ExitCode)) : $detail"
        }
        $modelfile = (& ollama.exe show --modelfile $newModel | Out-String)
        if ($modelfile -notmatch '(?im)^\s*PARAMETER\s+num_ctx\s+32768\b') { throw 'Le modele cree n annonce pas num_ctx 32768.' }
    } finally {
        Remove-Item -LiteralPath $modelfilePath, "$modelfilePath.stdout.tmp", "$modelfilePath.stderr.tmp" -Force -ErrorAction SilentlyContinue
    }
}
function Get-AvailableRamMB {
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        return [math]::Round(([double]$os.FreePhysicalMemory) / 1024, 0)
    } catch { return -1 }
}
function Get-GpuSnapshot {
    $smi = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue
    if (-not $smi) { return '' }
    try {
        $r = & $smi.Source --query-gpu=utilization.gpu,memory.used,temperature.gpu,power.draw,clocks.gr --format=csv,noheader,nounits 2>$null
        return (($r | Select-Object -First 1) -join '')
    } catch { return '' }
}

# Reported OpenCode token statistics: per-step usage, NOT exact full-context occupancy.
function Get-EventStatistics([string]$CaseDir) {
    [long]$maxReportedTokens = 0
    [long]$totalReportedOutput = 0
    $steps = 0
    $tools = 0
    $jsonErrors = 0
    foreach ($f in @(Get-ChildItem -LiteralPath $CaseDir -Filter 'opencode-events-*.jsonl' -File -ErrorAction SilentlyContinue)) {
        foreach ($line in @(Get-Content -LiteralPath $f.FullName -Encoding UTF8 -ErrorAction SilentlyContinue)) {
            if (-not $line -or -not $line.TrimStart().StartsWith('{')) { continue }
            try {
                $event = $line | ConvertFrom-Json -ErrorAction Stop
                if ($event.type -eq 'tool_use') { $tools++ }
                if ($event.type -eq 'step_finish') {
                    $steps++
                    if ($event.part -and $event.part.tokens) {
                        if ($null -ne $event.part.tokens.total) {
                            $maxReportedTokens = [math]::Max($maxReportedTokens, [long]$event.part.tokens.total)
                        }
                        if ($null -ne $event.part.tokens.output) {
                            $totalReportedOutput += [long]$event.part.tokens.output
                        }
                    }
                }
            } catch { $jsonErrors++ }
        }
    }
    return [pscustomobject]@{ MaxTokensReported=$maxReportedTokens; SumOutputTokensReported=$totalReportedOutput; Steps=$steps; ToolEvents=$tools; JsonErrors=$jsonErrors }
}

# Smoke test without any LLM/GPU usage, including the external validator.
if ($VerificationSeulement) {
    if (-not (Test-Path -LiteralPath $ArchivePath -PathType Leaf)) { throw "Archive introuvable : $ArchivePath" }
    if (-not (Test-Path -LiteralPath $ValidationArchive -PathType Leaf)) { throw "Archive de verification introuvable : $ValidationArchive" }
    $null = Assert-Command 'python.exe'
    $testRoot = Join-Path ([IO.Path]::GetTempPath()) ('prefa-v2-check-' + [guid]::NewGuid().ToString('N'))
    try {
        Expand-Archive -LiteralPath $ArchivePath -DestinationPath $testRoot -Force
        Expand-Archive -LiteralPath $ValidationArchive -DestinationPath $testRoot -Force
        $projectDir = Join-Path $testRoot 'Project'
        $privateTestsDir = Join-Path $testRoot 'Validator\hidden_tests'
        $visible = Invoke-TestSuite -Root $projectDir -Log (Join-Path $testRoot 'visibles.log')
        $indep = Invoke-TestSuite -Root $projectDir -Log (Join-Path $testRoot 'independants.log') -TestsDir $privateTestsDir -Expected 21
        Write-Host ('Test de base : {0} tests visibles / {1} echecs / {2} erreur(s)' -f $visible.Total,$visible.Failures,$visible.Errors)
        Write-Host ('Validation separee : {0} tests / {1} echecs / {2} erreur(s)' -f $indep.Total,$indep.Failures,$indep.Errors)
        if (($visible.Total -ne 40) -or ($visible.Failures -ne 17) -or ($visible.Errors -ne 1) -or ($indep.Total -ne 21) -or ($indep.Failures -ne 14) -or ($indep.Errors -ne 2)) {
            throw 'Archive ou environnement non conforme. Aucun benchmark ne doit etre lance.'
        }
        Write-Host 'PREFLIGHT OK : les deux suites ont les echecs initiaux attendus.' -ForegroundColor Green
    } finally {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    exit 0
}

if (-not $AutoApprove -and -not $PreparationSeulement) {
    throw 'Ajouter -AutoApprove pour un benchmark autonome (copies de demonstration uniquement).'
}
if (-not (Test-Path -LiteralPath $ArchivePath -PathType Leaf)) { throw "Archive introuvable : $ArchivePath" }
if (-not (Test-Path -LiteralPath $ValidationArchive -PathType Leaf)) { throw "Archive de verification introuvable : $ValidationArchive" }
$null = Assert-Command 'opencode.cmd'
$null = Assert-Command 'ollama.exe'
$null = Assert-Command 'python.exe'
try { $null = Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/tags' -TimeoutSec 10 }
catch { throw 'Ollama ne repond pas sur http://127.0.0.1:11434' }

# Le setup est non destructif : un alias 32K partage les poids du modele local 16K.
Ensure-MoE32K
$models = @(
    [pscustomobject]@{ Label = 'MoE16K'; Cli = 'ollama/qwen36-moe:16k'; Ollama = 'qwen36-moe:16k'; Folder = 'Bench-MoE'; Context = 16384 },
    [pscustomobject]@{ Label = 'MoE32K'; Cli = 'ollama/qwen36-moe:32k'; Ollama = 'qwen36-moe:32k'; Folder = 'Bench-MoE'; Context = 32768 }
)
# Ollama doit annoncer les deux modeles a OpenCode. En cas de cache ou de
# configuration personnalisee, ne pas modifier automatiquement opencode.json.
$modelsText = ''
for ($n = 0; $n -lt 5; $n++) {
    try { $modelsText = (& opencode.cmd models ollama | Out-String) }
    catch { $modelsText = "OpenCode: $($_.Exception.Message)" }
    $allSeen = $true
    foreach ($m in $models) { if ($modelsText -notmatch [regex]::Escape($m.Cli)) { $allSeen = $false } }
    if ($allSeen) { break }
    Start-Sleep -Seconds 2
}
if (-not $allSeen) {
    Write-Host $modelsText
    throw 'OpenCode ne voit pas les deux alias MoE. Le 32K est cree dans Ollama, mais il faut verifier la configuration OpenCode (sans toucher a la configuration existante).'
}
Write-Host 'CONFIGURATION OK : alias 16K et 32K visibles dans OpenCode.' -ForegroundColor Green
if ($PreparationSeulement) {
    Write-Host 'Preparation terminee. Lancer ensuite le meme script sans -PreparationSeulement, avec -AutoApprove.' -ForegroundColor Green
    exit 0
}

$session = '{0}-{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), ([guid]::NewGuid().ToString('N').Substring(0, 6))
$sessionDir = Join-Path $OutputRoot $session
New-Item -ItemType Directory -Path $sessionDir -Force | Out-Null
$resultsCsv = Join-Path $sessionDir 'resultats.csv'
$allResults = New-Object System.Collections.Generic.List[object]

# Consigne STRICTEMENT identique pour les deux contextes et toutes les repetitions.
$prompt = @'
Lis le README.md de cette application de prefabrication. Corrige les incoherences metier pour faire passer tous les tests visibles.
Commence par executer python -m unittest discover -s tests -v. Explore les modules et corrige reellement leur code : il ne suffit pas de decrire les solutions.
Respecte les specifications de README.md (unites, reservations, couches sandwich, levage, thermique, moules, exports et agregations).
Ne modifie JAMAIS README.md, ni les fichiers sous tests/. N'installe rien, ne contacte aucun service externe, ne modifie rien hors du dossier de travail.
Verifie en relancant python -m unittest discover -s tests -v. Si des tests echouent encore, continue jusqu'a tous les reussir ou explique un blocage precis.
Termine par un bref compte rendu des fichiers modifies et des validations.
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
La mission n'est PAS terminee. La verification independante des tests visibles a encore des echecs.
Continue dans la MEME session et corrige le code metier, au lieu de repondre par une analyse.
Ne touche ni a README.md ni aux tests. Lance python -m unittest discover -s tests -v et cherche une solution complete.
'@ | Set-Content -LiteralPath $followupFile -Encoding UTF8

Write-Host "RESULTATS : $sessionDir" -ForegroundColor Cyan
Write-Host 'Verifier que le minage est arrete et que le GPU reste aux frequences automatiques pour les deux essais.' -ForegroundColor Yellow
Write-Host 'Tests : 40 visibles + 21 independants (executables uniquement apres le travail de OpenCode).'
Write-Host 'Deux metriques distinctes : succes au premier passage et succes apres relances automatiques.' -ForegroundColor Yellow
Write-Host 'Chronometre : temps de bout en bout des passages OpenCode + controles intermediaires, sans copie ni prechauffage.'

try {
for ($i = 1; $i -le $Repetitions; $i++) {
    $order = if (($i % 2) -eq 1) { $models } else { @($models[1], $models[0]) }
    foreach ($m in $order) {
        $id = '{0}-essai-{1:00}' -f $m.Label, $i
        $caseDir = Join-Path $sessionDir $id
        New-Item -ItemType Directory -Path $caseDir -Force | Out-Null
        Expand-Archive -LiteralPath $ArchivePath -DestinationPath $caseDir -Force
        $workdir = Join-Path $caseDir 'Project'
        # The Validator archive is NOT unpacked while OpenCode runs.
        $validationPrivate = Join-Path $sessionDir ('_validation_' + $id)
        if (-not (Test-Path -LiteralPath (Join-Path $workdir 'tests\test_geometry.py'))) { throw "Projet source non conforme : $workdir" }
        $beforeTests = Get-FileSignature -Root $workdir -Subfolder 'tests'
        $beforeReadme = (Get-FileHash -LiteralPath (Join-Path $workdir 'README.md') -Algorithm SHA256).Hash
        $baseline = Invoke-TestSuite -Root $workdir -Log (Join-Path $caseDir 'tests-avant.txt')
        if (($baseline.Total -ne 40) -or ($baseline.Failures -ne 17) -or ($baseline.Errors -ne 1)) {
            throw "Base incorrecte pour $id : $($baseline.Total) tests, $($baseline.Failures) echecs, $($baseline.Errors) erreurs."
        }
        Unload-TestModels
        Write-Host "`n[$id] Prechauffage $($m.Ollama) avec $($m.Context) tokens..." -ForegroundColor Cyan
        $warm = Warm-TestModel -Model $m.Ollama -Context $m.Context
        $warmSec = $warm.Seconds
        $gpuBefore = Get-GpuSnapshot
        $ramFreeMB = Get-AvailableRamMB
        Write-Host ('[{0}] Contexte Ollama : {1} ; VRAM chargee Ollama : {2} Mo ; RAM libre : {3} Mo ; GPU : {4}' -f $id, $warm.Context, $warm.VramMB, $ramFreeMB, $gpuBefore) -ForegroundColor DarkCyan
        if ($m.Context -eq 32768 -and $ramFreeMB -ge 0 -and $ramFreeMB -lt 4096) {
            Write-Warning 'RAM libre inferieure a 4 Go apres prechauffage 32K. Risque de pagination disque et lenteurs. Tu peux interrompre le benchmark sans risque.'
        }
        $gpuSamples = New-Object System.Collections.Generic.List[string]
        $ramSamples = New-Object System.Collections.Generic.List[int]
        $sampleTick = 0
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
                # RAM sampled every ~18 seconds, rather than on every GPU poll.
                $sampleTick++
                if (($sampleTick % 6) -eq 0) {
                    $freeNow = Get-AvailableRamMB
                    if ($freeNow -ge 0) { $ramSamples.Add([int]$freeNow) }
                }
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
            $nbOK = if ($after.Total -eq 40) {40 - $after.Failures - $after.Errors} else {0}
            if ($round -eq 0) {
                $premierPassageTests = $nbOK
                $premierPassageOK = ($after.AllPassed -and $testsUntouched -and $readmeUntouched -and ($exitCode -eq 0))
            }
            Write-Host "[$id] Passage $num : $nbOK/40 ; sortie OpenCode $exitCode ; session $sessionID" -ForegroundColor Cyan
            if ($after.AllPassed) { break }
            if ($exitCode -ne 0) { Write-Warning "[$id] OpenCode en erreur : pas de relance."; break }
            if (-not $sessionID) { Write-Warning "[$id] ID de session manquant : pas de relance."; break }
            if (-not $testsUntouched -or -not $readmeUntouched) { Write-Warning "[$id] Fichiers proteges modifies : abandon."; break }
        }
        $watch.Stop()
        $finish = Get-Date
        $gpuSamples | Set-Content -LiteralPath (Join-Path $caseDir 'gpu-samples.csv') -Encoding UTF8
        $peakGpuMemoryMiB = -1
        foreach ($sample in $gpuSamples) {
            $parts = $sample.Split(',')
            if ($parts.Length -ge 3) {
                $mem = 0
                if ([int]::TryParse($parts[2].Trim(), [ref]$mem)) { $peakGpuMemoryMiB = [math]::Max($peakGpuMemoryMiB, $mem) }
            }
        }
        $minFreeRamMB = if ($ramSamples.Count -gt 0) { [int](($ramSamples | Measure-Object -Minimum).Minimum) } else { -1 }
        if ($null -eq $after) {
            $after = Invoke-TestSuite -Root $workdir -Log (Join-Path $caseDir 'tests-apres.txt')
        } else {
            Copy-Item -LiteralPath (Join-Path $caseDir ('tests-apres-passage-{0:00}.txt' -f $lastTestedPassage)) -Destination (Join-Path $caseDir 'tests-apres.txt') -Force
        }
        $afterTests = Get-FileSignature -Root $workdir -Subfolder 'tests'
        $testsUntouched = ((@($beforeTests) -join "`n") -ceq (@($afterTests) -join "`n"))
        $readmeUntouched = ((Get-FileHash -LiteralPath (Join-Path $workdir 'README.md') -Algorithm SHA256).Hash -ceq $beforeReadme)
        # Independent hidden tests are extracted and run only AFTER OpenCode is done.
        Expand-Archive -LiteralPath $ValidationArchive -DestinationPath $validationPrivate -Force
        $hiddenTestsDir = Join-Path $validationPrivate 'Validator\hidden_tests'
        $hidden = Invoke-TestSuite -Root $workdir -Log (Join-Path $caseDir 'tests-caches-apres.txt') -TestsDir $hiddenTestsDir -Expected 21
        $events = Get-EventStatistics -CaseDir $caseDir
        $state = if ($timedOut) { 'TIMEOUT' }
                 elseif (($exitCode -eq 0) -and $after.AllPassed -and $hidden.AllPassed -and $testsUntouched -and $readmeUntouched) { 'SUCCES' }
                 elseif ($after.AllPassed -and -not $testsUntouched) { 'TESTS_MODIFIES' }
                 elseif ($after.AllPassed -and -not $readmeUntouched) { 'README_MODIFIE' }
                 elseif ($after.AllPassed -and -not $hidden.AllPassed) { 'ECHEC_TESTS_INDEPENDANTS' }
                 elseif ($after.AllPassed) { 'TESTS_OK_AGENT_ERREUR' }
                 else { 'ECHEC' }
        $row = [pscustomobject]@{
            DateDebut = $start.ToString('s'); Modele = $m.Label; IdModele = $m.Cli; ContexteDemande = $m.Context; ContexteOllama = $warm.Context; VramChargeeMo = $warm.VramMB; RamLibreMo = $ramFreeMB; Essai = $i;
            TempsAgentSecondes = [math]::Round($watch.Elapsed.TotalSeconds, 2)
            PrechauffageSecondes = $warmSec; Fin = $finish.ToString('s');
            TestsAvant = $baseline.Total; EchecsAvant = $baseline.Failures;
            TestsApres = $after.Total; EchecsApres = $after.Failures; ErreursApres = $after.Errors;
            TestsTousOK = $after.AllPassed; TestsCachesOK = $hidden.AllPassed; TestsCachesTotal = $hidden.Total; TestsCachesEchecs = $hidden.Failures; TestsCachesErreurs = $hidden.Errors;
            MaxTokensRapportes = $events.MaxTokensReported; TokensSortieRapportes = $events.SumOutputTokensReported; EtapesRapportees = $events.Steps; AppelsOutilsRapportes = $events.ToolEvents; JsonErreurs = $events.JsonErrors;
            VramPicEchantillonneMiB = $peakGpuMemoryMiB; RamLibreMiniEchantillonMo = $minFreeRamMB;
            TestsIntacts = $testsUntouched;
            ReadmeIntact = $readmeUntouched; CodeSortieAgent = $exitCode; Timeout = $timedOut;
            PremierPassageTestsOK = $premierPassageTests; PremierPassageOK = $premierPassageOK;
            Passages = $passages; Relances = [math]::Max(0, $passages - 1);
            Resultat = $state; GpuAvant = $gpuBefore; Dossier = $caseDir
        }
        $allResults.Add($row)
        $allResults | Export-Csv -LiteralPath $resultsCsv -NoTypeInformation -Encoding UTF8 -Delimiter ';'
        Write-Host ('[{0}] {1} s ; passages {2} ; premier passage {3}/40 ; visibles {4}/40 ; independants {5}/21 ; statut {6}' -f $id, $row.TempsAgentSecondes, $passages, $premierPassageTests, (40-$after.Failures-$after.Errors), (21-$hidden.Failures-$hidden.Errors), $state) -ForegroundColor Green
    }
}
} finally {
    Unload-TestModels
}
Write-Host "`nBENCHMARK TERMINE. CSV : $resultsCsv" -ForegroundColor Green
$allResults | Format-Table Modele,ContexteDemande,Essai,TempsAgentSecondes,PremierPassageTestsOK,Passages,TestsTousOK,TestsCachesOK,MaxTokensRapportes,Resultat -AutoSize
Write-Host 'Metrique MaxTokensRapportes = maximum du champ total des evenements OpenCode, PAS occupation exacte de contexte ni tokens/sec.'
