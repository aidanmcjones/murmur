<#
.SYNOPSIS
  One-shot, non-interactive, idempotent installer for Murmur on Windows 10/11 (x64).

.DESCRIPTION
  1. Checks the machine (64-bit Windows 10 1809+ / Windows 11).
  2. Downloads the latest `win-v*` GitHub release zip (murmur.exe, llama-server.exe, DLLs) into
     %LOCALAPPDATA%\Murmur, unblocks it, and replaces any older copy (stopping a running Murmur first).
  3. Downloads the speech model (NVIDIA Parakeet TDT 0.6B v2 int8, ~0.5 GB) and the cleanup model
     (Qwen3-4B-Instruct-2507 Q4_K_M, ~2.5 GB) into <install>\models with resume and size/SHA-256 checks.
  4. Creates a Start-menu shortcut; -Startup also starts Murmur at login.
  5. Launches Murmur unless -NoLaunch.

  Safe to run again: finished downloads are verified and skipped, a newer release is installed over the old one.

.PARAMETER Startup      Start Murmur when you sign in.
.PARAMETER NoLaunch     Install only, do not start Murmur.
.PARAMETER InstallDir   Default: %LOCALAPPDATA%\Murmur
.PARAMETER Repo         Default: aidanmcjones/murmur
.PARAMETER Tag          Install a specific release tag (default: newest win-v* release).
.PARAMETER ZipPath      Use a local murmur-win-x64.zip instead of downloading a release (used by CI).
.PARAMETER SkipLlmModel Skip the 2.5 GB cleanup model (Murmur then uses deterministic cleanup only).
#>
[CmdletBinding()]
param(
    [switch]$Startup,
    [switch]$NoLaunch,
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'Murmur'),
    [string]$Repo = 'aidanmcjones/murmur',
    [string]$Tag = '',
    [string]$ZipPath = '',
    [switch]$SkipLlmModel
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$ParakeetUrl = 'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8.tar.bz2'
$ParakeetSize = 482440461
$ParakeetSha = '6fc4426b54aa549a0019b8a75b8dea59164e71790a37ac56a045ad57f915f714'
$ParakeetDirName = 'sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8'
$GgufUrl = 'https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF/resolve/main/Qwen3-4B-Instruct-2507-Q4_K_M.gguf'
$GgufName = 'qwen3-4b-instruct-2507-q4_K_M.gguf'
$GgufSize = 2497281120
$GgufSha = '3605803b982cb64aead44f6c1b2ae36e3acdb41d8e46c8a94c6533bc4c67e597'

function Step($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Warn($m) { Write-Host "!! $m" -ForegroundColor Yellow }
function Fail($m) { Write-Host "ERROR: $m" -ForegroundColor Red; exit 1 }

# ---- 1. machine check ------------------------------------------------------------------------------
Step 'Checking this PC'
if ($env:OS -ne 'Windows_NT') { Fail 'This installer is for Windows. On macOS use scripts/setup.sh.' }
$build = [Environment]::OSVersion.Version.Build
if ($build -lt 17763) { Fail "Windows 10 version 1809 or newer is required (this is build $build)." }
if (-not [Environment]::Is64BitOperatingSystem) { Fail 'A 64-bit (x64) version of Windows is required.' }
$arch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
if ($arch -eq 'ARM64') { Warn 'ARM64 Windows detected: the x64 build runs under emulation and will be slower.' }
elseif ($arch -ne 'AMD64') { Fail "Unsupported processor architecture: $arch" }
Write-Host "Windows build $build, $arch"
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
$ModelsDir = Join-Path $InstallDir 'models'
New-Item -ItemType Directory -Force -Path $ModelsDir | Out-Null

# ---- helpers ---------------------------------------------------------------------------------------
function Test-FileOk([string]$Path, [long]$Size, [string]$Sha) {
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    if ($Size -gt 0 -and (Get-Item -LiteralPath $Path).Length -ne $Size) { return $false }
    if ($Sha) {
        $h = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLower()
        if ($h -ne $Sha.ToLower()) { return $false }
    }
    return $true
}

# Resumable download (curl.exe ships with Windows 10 1803+), verified by size and SHA-256.
function Get-Verified([string]$Url, [string]$Dest, [long]$Size, [string]$Sha) {
    if (Test-FileOk $Dest $Size $Sha) { Write-Host "OK (already downloaded): $(Split-Path $Dest -Leaf)"; return }
    $part = "$Dest.part"
    Write-Host "Downloading $(Split-Path $Dest -Leaf) ..."
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    for ($try = 1; $try -le 4; $try++) {
        $quiet = if ($env:CI -or $env:GITHUB_ACTIONS) { '-sS' } else { '--progress-bar' }
        if (Test-Path $curl) {
            & $curl -L --fail --retry 5 --retry-delay 3 --connect-timeout 30 -C - $quiet -o $part $Url
            $code = $LASTEXITCODE
            # 33 = range not satisfiable: the .part file is already complete.
            if ($code -ne 0 -and $code -ne 33) { Warn "curl exit code $code (attempt $try of 4)"; Start-Sleep -Seconds 3; continue }
        } else {
            Invoke-WebRequest -Uri $Url -OutFile $part -UseBasicParsing
        }
        if (Test-FileOk $part $Size $Sha) { Move-Item -Force -LiteralPath $part -Destination $Dest; return }
        Warn "Downloaded file failed the size/SHA-256 check (attempt $try of 4)."
        Remove-Item -Force -ErrorAction SilentlyContinue $part
    }
    Fail "Could not download a valid copy of $Url. Check your internet connection and run this script again."
}

# ---- 2. app ----------------------------------------------------------------------------------------
Step 'Installing Murmur'
$zip = $ZipPath
$relTag = 'local'
if (-not $zip) {
    $headers = @{ 'User-Agent' = 'murmur-setup'; 'Accept' = 'application/vnd.github+json' }
    if ($env:GITHUB_TOKEN) { $headers['Authorization'] = "Bearer $env:GITHUB_TOKEN" }
    $rels = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases?per_page=50" -Headers $headers
    $rel = $rels | Where-Object { -not $_.draft -and $_.tag_name -like 'win-v*' -and ($Tag -eq '' -or $_.tag_name -eq $Tag) } | Select-Object -First 1
    if (-not $rel) { Fail "No Windows release (tag win-v*) found in $Repo yet." }
    $asset = $rel.assets | Where-Object { $_.name -eq 'murmur-win-x64.zip' } | Select-Object -First 1
    if (-not $asset) { Fail "Release $($rel.tag_name) has no murmur-win-x64.zip asset." }
    $relTag = $rel.tag_name
    $zip = Join-Path $env:TEMP "murmur-win-x64-$relTag.zip"
    $shaAsset = $rel.assets | Where-Object { $_.name -eq 'murmur-win-x64.zip.sha256' } | Select-Object -First 1
    $expected = ''
    if ($shaAsset) {
        $expected = ((Invoke-RestMethod -Uri $shaAsset.browser_download_url -Headers $headers) -as [string]).Trim().Split(' ')[0]
    }
    Get-Verified $asset.browser_download_url $zip $asset.size $expected
}
if (-not (Test-Path -LiteralPath $zip)) { Fail "Zip not found: $zip" }
Unblock-File -LiteralPath $zip

# Stop a running copy so files can be replaced.
Get-Process -Name murmur, llama-server -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -and $_.Path.StartsWith($InstallDir, [StringComparison]::OrdinalIgnoreCase) } |
    ForEach-Object { Write-Host "Stopping $($_.Name) ($($_.Id))"; Stop-Process -Id $_.Id -Force; $_.WaitForExit(5000) | Out-Null }

$stage = Join-Path $env:TEMP "murmur-stage-$([Guid]::NewGuid().ToString('N'))"
Expand-Archive -LiteralPath $zip -DestinationPath $stage -Force
Get-ChildItem -LiteralPath $stage -Recurse -File | ForEach-Object { Unblock-File -LiteralPath $_.FullName }
Copy-Item -Path (Join-Path $stage '*') -Destination $InstallDir -Recurse -Force
Remove-Item -Recurse -Force $stage
$exe = Join-Path $InstallDir 'murmur.exe'
if (-not (Test-Path $exe)) { Fail 'murmur.exe is missing after extraction (is this the right zip?).' }
Write-Host "Installed $relTag to $InstallDir"

# ---- 3. models -------------------------------------------------------------------------------------
Step 'Speech model (Parakeet TDT 0.6B v2, int8)'
$pkDir = Join-Path $ModelsDir $ParakeetDirName
$pkFiles = 'encoder.int8.onnx', 'decoder.int8.onnx', 'joiner.int8.onnx', 'tokens.txt'
$pkOk = $true
foreach ($f in $pkFiles) { if (-not (Test-Path (Join-Path $pkDir $f))) { $pkOk = $false } }
if ($pkOk) { Write-Host 'OK (already installed)' }
else {
    $tar = Join-Path $ModelsDir 'parakeet.tar.bz2'
    Get-Verified $ParakeetUrl $tar $ParakeetSize $ParakeetSha
    Write-Host 'Extracting ...'
    & (Join-Path $env:SystemRoot 'System32\tar.exe') -xjf $tar -C $ModelsDir
    if ($LASTEXITCODE -ne 0) { Fail 'tar failed to extract the speech model.' }
    foreach ($f in $pkFiles) { if (-not (Test-Path (Join-Path $pkDir $f))) { Fail "Speech model file missing after extraction: $f" } }
    Remove-Item -Force $tar
}

Step 'Cleanup model (Qwen3-4B-Instruct-2507 Q4_K_M)'
if ($SkipLlmModel) { Warn 'Skipped (-SkipLlmModel): Murmur will use deterministic cleanup only.' }
else { Get-Verified $GgufUrl (Join-Path $ModelsDir $GgufName) $GgufSize $GgufSha }

# ---- 4. shortcuts ----------------------------------------------------------------------------------
Step 'Shortcuts'
$programs = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
New-Item -ItemType Directory -Force -Path $programs | Out-Null
$ws = New-Object -ComObject WScript.Shell
$lnk = $ws.CreateShortcut((Join-Path $programs 'Murmur.lnk'))
$lnk.TargetPath = $exe
$lnk.WorkingDirectory = $InstallDir
$lnk.Description = 'Murmur push-to-talk dictation'
$lnk.Save()
Write-Host 'Start menu shortcut: Murmur'
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
if ($Startup) {
    New-Item -Path $runKey -Force | Out-Null
    Set-ItemProperty -Path $runKey -Name 'Murmur' -Value "`"$exe`""
    Write-Host 'Murmur will start at login.'
} else {
    Write-Host 'Start at login: off (re-run with -Startup, or use the tray menu).'
}

# ---- 5. launch -------------------------------------------------------------------------------------
if (-not $NoLaunch) {
    Step 'Starting Murmur'
    Start-Process -FilePath $exe -WorkingDirectory $InstallDir
}

Write-Host ''
Write-Host 'Murmur is installed.' -ForegroundColor Green
Write-Host '  Hold Right Ctrl, speak, release: the text is pasted where you are typing. Esc cancels; double-tap = hands-free.'
Write-Host '  Change the key from the tray icon (near the clock) > Set push-to-talk key...'
Write-Host ''
Write-Host 'Things only you can do:' -ForegroundColor Yellow
Write-Host '  * If Windows blocks the microphone: Settings > Privacy & security > Microphone > allow "Let desktop apps access your microphone".'
Write-Host '  * If SmartScreen says "Windows protected your PC" the first time: click "More info", then "Run anyway".'
Write-Host '  * The tray icon may be hidden in the ^ overflow next to the clock; drag it out to keep it visible.'
Write-Host "  * Data and logs: $env:APPDATA\Murmur (dictionary.json, history.jsonl, debug.log)"
