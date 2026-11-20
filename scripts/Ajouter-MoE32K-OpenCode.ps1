#Requires -Version 5.1
# Ajoute l'alias Ollama 32K a OpenCode sans toucher aux modeles existants.
# Ne telecharge pas de poids et ne lance pas de benchmark.
$ErrorActionPreference = 'Stop'
$path = Join-Path $env:USERPROFILE '.config\opencode\opencode.json'
$oldId = 'qwen36-moe:16k'
$newId = 'qwen36-moe:32k'

if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    throw "Configuration OpenCode introuvable : $path"
}

# S'assurer que le modele existe dans Ollama avant de modifier OpenCode.
$ollamaList = (& ollama.exe list | Out-String)
if ($LASTEXITCODE -ne 0 -or $ollamaList -notmatch '(?m)^qwen36-moe:32k\s') {
    throw 'qwen36-moe:32k introuvable dans Ollama. Executer la phase PreparationSeulement du benchmark en premier.'
}

$original = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
try {
    $config = $original | ConvertFrom-Json
} catch {
    throw "Le fichier de configuration n'est pas un JSON standard. Aucune modification appliquee. Details : $($_.Exception.Message)"
}

if ($null -eq $config.provider -or $null -eq $config.provider.ollama -or $null -eq $config.provider.ollama.models) {
    throw 'provider.ollama.models est introuvable dans opencode.json. Aucune modification.'
}

$models = $config.provider.ollama.models
$oldProperty = $models.PSObject.Properties[$oldId]
if ($null -eq $oldProperty) {
    throw "Entree $oldId absente. Aucune modification : il faut examiner la configuration existante."
}

if ($models.PSObject.Properties[$newId]) {
    Write-Host "$newId est deja enregistre dans OpenCode. Aucun changement." -ForegroundColor Green
    exit 0
}

# Dupliquer la definition du modele qui fonctionne deja.
$copy = ($oldProperty.Value | ConvertTo-Json -Depth 100) | ConvertFrom-Json
if ($copy.PSObject.Properties['name']) {
    $copy.name = ([string]$copy.name) -replace '(?i)16\s*K', '32K'
}
if ($copy.PSObject.Properties['id'] -and $copy.id -eq $oldId) {
    $copy.id = $newId
}
if (-not $copy.PSObject.Properties['limit']) {
    $copy | Add-Member -MemberType NoteProperty -Name limit -Value ([pscustomobject]@{ context = 32768 })
} elseif ($null -eq $copy.limit) {
    $copy.limit = [pscustomobject]@{ context = 32768 }
} elseif ($copy.limit.PSObject.Properties['context']) {
    $copy.limit.context = 32768
} else {
    $copy.limit | Add-Member -MemberType NoteProperty -Name context -Value 32768
}
if ($copy.PSObject.Properties['options'] -and $null -ne $copy.options) {
    if ($copy.options.PSObject.Properties['num_ctx']) { $copy.options.num_ctx = 32768 }
    if ($copy.options.PSObject.Properties['numCtx']) { $copy.options.numCtx = 32768 }
}
if ($copy.PSObject.Properties['num_ctx']) { $copy.num_ctx = 32768 }

$models | Add-Member -MemberType NoteProperty -Name $newId -Value $copy
$newText = $config | ConvertTo-Json -Depth 100
$check = $newText | ConvertFrom-Json
if (-not $check.provider.ollama.models.PSObject.Properties[$newId]) {
    throw 'Validation du JSON echouee avant ecriture. Aucune modification.'
}

$backup = '{0}.bak-{1}' -f $path, (Get-Date -Format 'yyyyMMdd-HHmmss')
Copy-Item -LiteralPath $path -Destination $backup -ErrorAction Stop
[System.IO.File]::WriteAllText($path, $newText + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))

Write-Host "Sauvegarde creee : $backup" -ForegroundColor Cyan
Write-Host "Alias ajoute dans OpenCode : ollama/$newId (contexte annonce : 32768)." -ForegroundColor Green
Write-Host 'Controle des modeles declares :' -ForegroundColor Cyan
& opencode.cmd models ollama
if ($LASTEXITCODE -ne 0) { throw 'OpenCode n a pas pu lister les modeles apres modification. Restaurer la sauvegarde si necessaire.' }