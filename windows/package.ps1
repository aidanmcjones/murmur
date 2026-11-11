# Assembles the Windows release zip: murmur.exe (+ any sherpa-onnx DLLs the build produced), llama-server.exe
# and its DLLs (official llama.cpp CPU build), the VC++ runtime DLLs, and a short README. CI only.
param(
    [string]$Target = (Join-Path $PSScriptRoot 'target\release'),
    [string]$Out = (Join-Path $PSScriptRoot 'dist')
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $Out
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$stage = Join-Path $Out 'stage'
New-Item -ItemType Directory -Force -Path $stage | Out-Null

Copy-Item (Join-Path $Target 'murmur.exe') $stage
Get-ChildItem $Target -Filter *.dll -File | Where-Object { $_.Name -match 'sherpa|onnxruntime|cargs' } | ForEach-Object { Copy-Item $_.FullName $stage }

# llama.cpp: official Windows CPU build, pinned (same tag as scripts/setup.sh) and verified by SHA-256.
# To bump: pick a release at https://github.com/ggml-org/llama.cpp/releases, update both values from the
# `llama-<tag>-bin-win-cpu-x64.zip` asset (GitHub shows its sha256 digest), and keep setup.sh's LLAMA_TAG in step.
$LlamaTag = 'b11429'
$LlamaZipName = "llama-$LlamaTag-bin-win-cpu-x64.zip"
$LlamaSha256 = '1283323272b04cd07905816a597a0da810918102de958f4ff6f7bbaa70ed2efe'
$rel = [pscustomobject]@{ tag_name = $LlamaTag }
$asset = [pscustomobject]@{ name = $LlamaZipName; browser_download_url = "https://github.com/ggml-org/llama.cpp/releases/download/$LlamaTag/$LlamaZipName" }
Write-Host "llama.cpp $($rel.tag_name): $($asset.name)"
$lz = Join-Path $Out 'llama.zip'
Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $lz -UseBasicParsing
$got = (Get-FileHash -LiteralPath $lz -Algorithm SHA256).Hash.ToLower()
if ($got -ne $LlamaSha256) { throw "llama.cpp archive SHA-256 mismatch: expected $LlamaSha256, got $got" }
$lx = Join-Path $Out 'llama'
Expand-Archive -LiteralPath $lz -DestinationPath $lx -Force
$srv = Get-ChildItem $lx -Recurse -Filter llama-server.exe | Select-Object -First 1
if (-not $srv) { throw 'llama-server.exe not found in the llama.cpp archive' }
Get-ChildItem $srv.DirectoryName -File | Where-Object { $_.Extension -in '.exe', '.dll' -and ($_.Name -eq 'llama-server.exe' -or $_.Extension -eq '.dll') } |
    ForEach-Object { Copy-Item $_.FullName $stage }
"llama.cpp $($rel.tag_name) ($($asset.name))" | Set-Content (Join-Path $stage 'LLAMA_CPP_VERSION.txt')

# App-local copy of the Visual C++ runtime so a fresh Windows install works without the redistributable.
foreach ($d in 'vcruntime140.dll', 'vcruntime140_1.dll', 'msvcp140.dll') {
    $p = Join-Path $env:SystemRoot "System32\$d"
    if (Test-Path $p) { Copy-Item $p $stage } else { Write-Warning "$d not found on this machine" }
}

@"
Murmur for Windows
==================
Install / update: run scripts\setup.ps1 from https://github.com/aidanmcjones/murmur (it downloads this zip and the models).
Hold Right Ctrl, speak, release. Esc cancels. Double-tap = hands-free. Tray icon > Set push-to-talk key...
Data: %APPDATA%\Murmur   Models: <this folder>\models
llama-server.exe is the unmodified llama.cpp CPU build (MIT licence).
"@ | Set-Content (Join-Path $stage 'README.txt')

$zip = Join-Path $Out 'murmur-win-x64.zip'
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -Force
$hash = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
"$hash  murmur-win-x64.zip" | Set-Content (Join-Path $Out 'murmur-win-x64.zip.sha256')
Get-ChildItem $stage | Format-Table Name, Length
Write-Host "Wrote $zip ($((Get-Item $zip).Length) bytes) sha256=$hash"
