$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$sourceFile = Join-Path $repoRoot 'reframework\autorun\monster_hp_overlay.lua'
$sourceImageDir = Join-Path $repoRoot 'reframework\images\monster_hp_overlay'
$sourceFont = Join-Path $env:WINDIR 'Fonts\NotoSansJP-Medium.otf'

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
$targetImageDir = Join-Path (Split-Path -Parent $targetDir) 'images\monster_hp_overlay'
$targetFontDir = Join-Path (Split-Path -Parent $targetDir) 'fonts'
$targetFont = Join-Path $targetFontDir 'NotoSansJP-Medium.otf'

if (-not (Test-Path -LiteralPath $sourceFile -PathType Leaf)) {
    throw "Source file was not found: $sourceFile"
}

if (-not (Test-Path -LiteralPath $sourceImageDir -PathType Container)) {
    throw "Image directory was not found: $sourceImageDir"
}

if (-not (Test-Path -LiteralPath $sourceFont -PathType Leaf)) {
    throw "Japanese font was not found: $sourceFont"
}

New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
New-Item -ItemType Directory -Path $targetImageDir -Force | Out-Null
New-Item -ItemType Directory -Path $targetFontDir -Force | Out-Null
Copy-Item -LiteralPath $sourceFile -Destination $targetFile -Force
Get-ChildItem -LiteralPath $sourceImageDir -Recurse -File | ForEach-Object {
    $relativePath = [System.IO.Path]::GetRelativePath($sourceImageDir, $_.FullName)
    $targetImage = Join-Path $targetImageDir $relativePath
    $targetImageParent = Split-Path -Parent $targetImage
    New-Item -ItemType Directory -Path $targetImageParent -Force | Out-Null

    if (-not (Test-Path -LiteralPath $targetImage -PathType Leaf)) {
        Copy-Item -LiteralPath $_.FullName -Destination $targetImage
    }
}
Copy-Item -LiteralPath $sourceFont -Destination $targetFont -Force
Write-Output "Deployed monster_hp_overlay.lua to $targetDir"
Write-Output "Deployed monster_hp_overlay images to $targetImageDir"
Write-Output "Deployed NotoSansJP-Medium.otf to $targetFontDir"
