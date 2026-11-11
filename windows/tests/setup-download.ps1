# Exercises scripts/setup.ps1's real download + SHA-256 path against a local mock release server:
# good hash installs; wrong hash, missing .sha256 asset and a mismatching expected hash are all fatal.
param([Parameter(Mandatory)][string]$Zip, [Parameter(Mandatory)][string]$InstallDir)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent | Split-Path -Parent
$setup = Join-Path $root 'scripts\setup.ps1'
$mock = Join-Path $PSScriptRoot 'mock-release.py'
$tmp = Join-Path $env:RUNNER_TEMP 'mock'
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$good = (Get-FileHash $Zip -Algorithm SHA256).Hash.ToLower()
$shaFile = Join-Path $tmp 'murmur-win-x64.zip.sha256'
[IO.File]::WriteAllText($shaFile, "$good  murmur-win-x64.zip`n")

function Run-Setup([string]$Port, [string]$Expected) {
    $zipTemp = Join-Path $env:TEMP 'murmur-win-x64-win-v0.0.0-test.zip'
    Remove-Item -Force -ErrorAction SilentlyContinue $zipTemp, "$zipTemp.part"
    $out = & pwsh -NoProfile -File $setup -NoLaunch -InstallDir $InstallDir -Repo test/murmur -ApiBase "http://127.0.0.1:$Port" `
        -Tag win-v0.0.0-test -ExpectedSha256 $Expected 2>&1 | Out-String
    return [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out }
}
function With-Server([int]$Port, [string[]]$Extra, [scriptblock]$Body) {
    $p = Start-Process python -ArgumentList (@($mock, $Port, $Zip, $shaFile) + $Extra) -PassThru -WindowStyle Hidden
    try {
        for ($i = 0; $i -lt 50; $i++) {
            try { Invoke-RestMethod "http://127.0.0.1:$Port/repos/test/murmur/releases" | Out-Null; break } catch { Start-Sleep -Milliseconds 200 }
        }
        & $Body
    } finally { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
}

With-Server 18731 @() {
    $r = Run-Setup 18731 $good
    Write-Host $r.Out
    if ($r.Code -ne 0 -or $r.Out -notmatch 'Installed win-v0\.0\.0-test') { throw "good download should install (exit $($r.Code))" }
    $r = Run-Setup 18731 ('0' * 64)
    if ($r.Code -eq 0 -or $r.Out -notmatch 'does not match') { throw "wrong expected hash must fail:`n$($r.Out)" }
}
With-Server 18732 @('--no-sha') {
    $r = Run-Setup 18732 $good
    if ($r.Code -eq 0 -or $r.Out -notmatch 'refusing') { throw "missing .sha256 asset must fail:`n$($r.Out)" }
}
Write-Host 'setup.ps1 download/hash path OK'
exit 0
