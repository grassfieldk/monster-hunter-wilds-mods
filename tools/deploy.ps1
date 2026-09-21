$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$sourceFile = Join-Path $repoRoot 'reframework\autorun\monster_hp_overlay.lua'

if ([string]::IsNullOrWhiteSpace($env:REFRAMEWORK_AUTORUN_DIR)) {
    if ([string]::IsNullOrWhiteSpace($env:MH_WILDS_GAME_DIR)) {
        throw 'Set MH_WILDS_GAME_DIR or REFRAMEWORK_AUTORUN_DIR in .env before deploying.'
    }

    $targetDir = Join-Path $env:MH_WILDS_GAME_DIR 'reframework\autorun'
} else {
    $targetDir = $env:REFRAMEWORK_AUTORUN_DIR
}

$targetDir = [System.IO.Path]::GetFullPath($targetDir)
$targetFile = Join-Path $targetDir 'monster_hp_overlay.lua'

if (-not (Test-Path -LiteralPath $sourceFile -PathType Leaf)) {
    throw "Source file was not found: $sourceFile"
}

New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
Copy-Item -LiteralPath $sourceFile -Destination $targetFile -Force
Write-Output "Deployed monster_hp_overlay.lua to $targetDir"
