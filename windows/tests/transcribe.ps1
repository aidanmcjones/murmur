# Headless test: murmur.exe --transcribe <wav>; the result must match the spoken sentence (WER-ish).
param(
    [Parameter(Mandatory)][string]$Murmur,
    [Parameter(Mandatory)][string]$Wav,
    [string]$Expected = 'Please send the report by Friday.',
    [double]$MaxWer = 0.2
)
$ErrorActionPreference = 'Stop'
function Norm([string]$s) { ($s.ToLower() -replace "[^a-z0-9' ]", ' ' -split '\s+' | Where-Object { $_ }) }
function Wer($ref, $hyp) {
    $d = New-Object 'int[,]' ($ref.Count + 1), ($hyp.Count + 1)
    for ($i = 0; $i -le $ref.Count; $i++) { $d[$i, 0] = $i }
    for ($j = 0; $j -le $hyp.Count; $j++) { $d[0, $j] = $j }
    for ($i = 1; $i -le $ref.Count; $i++) {
        for ($j = 1; $j -le $hyp.Count; $j++) {
            $c = if ($ref[$i - 1] -eq $hyp[$j - 1]) { 0 } else { 1 }
            $d[$i, $j] = [Math]::Min([Math]::Min($d[($i - 1), $j] + 1, $d[$i, ($j - 1)] + 1), $d[($i - 1), ($j - 1)] + $c)
        }
    }
    return $d[$ref.Count, $hyp.Count] / [Math]::Max($ref.Count, 1)
}
$out = Join-Path $env:TEMP 'murmur-transcribe-out.txt'
$err = Join-Path $env:TEMP 'murmur-transcribe-err.txt'
$p = Start-Process -FilePath $Murmur -ArgumentList @('--transcribe', "`"$Wav`"") -Wait -PassThru -NoNewWindow `
    -RedirectStandardOutput $out -RedirectStandardError $err
$text = ("" + (Get-Content -Raw $out)).Trim()
Write-Host "exit=$($p.ExitCode) stdout='$text'"
Write-Host ("stderr: " + (Get-Content -Raw $err))
if (Test-Path "$env:MURMUR_APPDATA\debug.log") { Write-Host '--- debug.log ---'; Get-Content "$env:MURMUR_APPDATA\debug.log" | Select-Object -Last 30 }
if ($p.ExitCode -ne 0) { throw "murmur --transcribe exited with $($p.ExitCode)" }
$wer = Wer (Norm $Expected) (Norm $text)
Write-Host "WER vs '$Expected' = $wer"
if ($wer -gt $MaxWer) { throw "Transcript '$text' is too far from '$Expected' (WER $wer > $MaxWer)" }
if ($text -cne $Expected) { Write-Warning "Not an exact match (cleaned text differs only slightly): '$text'" }
Write-Host 'PASS: headless transcription'
