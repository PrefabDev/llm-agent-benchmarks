# Générer l'archive source utilisée par les scripts de benchmark.
# Exécuter depuis la racine du dépôt après l'avoir cloné ou téléchargé.
# Ne nécessite aucun paquet Python externe.
[CmdletBinding()]
param(
    [string]$Destination = 'D:\IA\Tests\Benchmark_PREFA_14B_vs_MoE.zip'
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$source = Join-Path $root 'benchmark\prefa-panel'
if (-not (Test-Path -LiteralPath (Join-Path $source 'tests\test_prefa.py'))) { throw "Source introuvable : $source" }
$targetDir = Split-Path -Parent $Destination
New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
$staging = Join-Path ([IO.Path]::GetTempPath()) ('prefa-' + [guid]::NewGuid().ToString('N'))
try {
    foreach ($name in @('Bench-14B','Bench-MoE')) {
        $dest = Join-Path $staging $name
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $source 'README.md') -Destination $dest
        Copy-Item -LiteralPath (Join-Path $source 'prefa') -Destination $dest -Recurse
        Copy-Item -LiteralPath (Join-Path $source 'tests') -Destination $dest -Recurse
    }
    if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Force }
    Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $Destination
    Write-Host "Archive créée : $Destination"
    Write-Host 'Vérifier la base : 15 tests, dont 7 échoués, dans chaque copie.'
} finally {
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
}
