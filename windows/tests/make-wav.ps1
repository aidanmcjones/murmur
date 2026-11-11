# Synthesizes a WAV with the built-in Windows speech engine (System.Speech).
param([Parameter(Mandatory)][string]$Out, [string]$Text = 'Please send the report by Friday.')
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Speech
$s = New-Object System.Speech.Synthesis.SpeechSynthesizer
$voices = $s.GetInstalledVoices() | Where-Object { $_.Enabled }
Write-Host ("Voices: " + (($voices | ForEach-Object { $_.VoiceInfo.Name }) -join ', '))
if (-not $voices) { throw 'No System.Speech voice installed on this machine.' }
$s.SetOutputToWaveFile($Out)
$s.Speak($Text)
$s.Dispose()
Write-Host "Wrote $Out ($((Get-Item $Out).Length) bytes)"
