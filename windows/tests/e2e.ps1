# End-to-end UI test: Notepad + murmur.exe --test-audio <wav>. Sends the push-to-talk key with SendInput,
# reads Notepad's text through UI Automation and asserts the cleaned sentence; then edits the pasted text and
# asserts that the vocabulary learner offers a suggestion (history.jsonl "vocab-suggest").
param(
    [Parameter(Mandatory)][string]$Murmur,
    [Parameter(Mandatory)][string]$Wav,
    [string]$ModelsDir,
    [string]$Expected = 'Please send the report by Friday.'
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class Win {
    [StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Explicit)] public struct INPUT { [FieldOffset(0)] public uint type; [FieldOffset(8)] public KEYBDINPUT ki; }
    [DllImport("user32.dll", SetLastError=true)] public static extern uint SendInput(uint n, INPUT[] inputs, int size);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
    [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    public static void Key(ushort vk, bool up, bool ext) {
        INPUT[] i = new INPUT[1];
        i[0].type = 1; i[0].ki.wVk = vk; i[0].ki.dwFlags = (uint)((up ? 2 : 0) | (ext ? 1 : 0));
        SendInput(1, i, Marshal.SizeOf(typeof(INPUT)));
    }
    public static void ForceForeground(IntPtr h) {
        keybd_event(0x12, 0, 0, UIntPtr.Zero); // Alt unlocks SetForegroundWindow
        ShowWindow(h, 9); BringWindowToTop(h); SetForegroundWindow(h);
        keybd_event(0x12, 0, 2, UIntPtr.Zero);
    }
}
"@

function Fail($m) { Write-Host "FAIL: $m"; throw $m }
function Tap([int]$vk, [bool]$ext = $false) { [Win]::Key($vk, $false, $ext); Start-Sleep -Milliseconds 25; [Win]::Key($vk, $true, $ext); Start-Sleep -Milliseconds 40 }

$work = Join-Path $env:RUNNER_TEMP 'murmur-e2e'
if (-not $env:RUNNER_TEMP) { $work = Join-Path $env:TEMP 'murmur-e2e' }
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $work
New-Item -ItemType Directory -Force -Path $work | Out-Null
$appdata = Join-Path $work 'appdata'
New-Item -ItemType Directory -Force -Path $appdata | Out-Null

Write-Host "Session: $([Diagnostics.Process]::GetCurrentProcess().SessionId), interactive=$([Environment]::UserInteractive)"
$notepad = Start-Process notepad.exe -PassThru
Start-Sleep -Seconds 3
$np = Get-Process -Id $notepad.Id -ErrorAction SilentlyContinue
$hwnd = if ($np) { $np.MainWindowHandle } else { [IntPtr]::Zero }
if ($hwnd -eq [IntPtr]::Zero) {
    # Windows 11 Notepad hands off to another process; look it up by name.
    $np = Get-Process notepad -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
    if ($np) { $hwnd = $np.MainWindowHandle }
}
if ($hwnd -eq [IntPtr]::Zero) {
    Write-Host 'SKIPPED: no interactive desktop window is available on this runner (Notepad has no top-level window).'
    Write-Host '::warning::UI end-to-end test skipped: runner has no interactive desktop'
    exit 0
}
[Win]::ForceForeground($hwnd)
Start-Sleep -Milliseconds 800
$root = [Windows.Automation.AutomationElement]::FromHandle($hwnd)
Write-Host ("Notepad window: '" + $root.Current.Name + "' class=" + $root.Current.ClassName + " pid=" + $root.Current.ProcessId)
$script:editEl = $null
function Find-Editor {
    $all = $root.FindAll([Windows.Automation.TreeScope]::Descendants, [Windows.Automation.Condition]::TrueCondition)
    $best = $null
    foreach ($e in $all) {
        $o = $null
        $hasText = $e.TryGetCurrentPattern([Windows.Automation.TextPattern]::Pattern, [ref]$o)
        $hasVal = $e.TryGetCurrentPattern([Windows.Automation.ValuePattern]::Pattern, [ref]$o)
        $ct = $e.Current.ControlType.ProgrammaticName
        if (($hasText -or $hasVal) -and ($ct -match 'Document|Edit')) { $best = $e; break }
    }
    if (-not $best) {
        Write-Host "Elements seen:"
        foreach ($e in $all) { Write-Host ("  " + $e.Current.ControlType.ProgrammaticName + " class=" + $e.Current.ClassName + " name='" + $e.Current.Name + "'") }
    }
    return $best
}
function Get-NotepadText {
    if (-not $script:editEl) { $script:editEl = Find-Editor }
    if (-not $script:editEl) { return $null }
    $o = $null
    if ($script:editEl.TryGetCurrentPattern([Windows.Automation.TextPattern]::Pattern, [ref]$o)) { return $o.DocumentRange.GetText(-1) }
    if ($script:editEl.TryGetCurrentPattern([Windows.Automation.ValuePattern]::Pattern, [ref]$o)) { return $o.Current.Value }
    return $null
}
$t0 = Get-Date
while ($null -eq (Get-NotepadText) -and ((Get-Date) - $t0).TotalSeconds -lt 15) { Start-Sleep -Milliseconds 500 }
if ($null -eq (Get-NotepadText)) { Fail 'cannot read Notepad text through UI Automation' }

$env:MURMUR_APPDATA = $appdata
if ($ModelsDir) { $env:MURMUR_MODELS_DIR = $ModelsDir }
$m = Start-Process -FilePath $Murmur -ArgumentList @('--test-audio', "`"$Wav`"", '--ptt', 'right-ctrl') -PassThru
try {
    $log = Join-Path $appdata 'debug.log'
    $t0 = Get-Date
    while (((Get-Date) - $t0).TotalSeconds -lt 180) {
        if ((Test-Path $log) -and ((Get-Content -Raw $log) -match 'asr: parakeet loaded') -and ((Get-Content -Raw $log) -match 'ready; push-to-talk')) { break }
        if ($m.HasExited) { Fail "murmur exited early (code $($m.ExitCode))" }
        Start-Sleep -Milliseconds 500
    }
    if (-not ((Test-Path $log) -and ((Get-Content -Raw $log) -match 'asr: parakeet loaded'))) { Fail 'speech model did not load in 180 s' }
    Write-Host 'murmur ready'

    # Make sure Notepad has the keyboard focus, then hold Right Ctrl for ~1.2 s.
    [Win]::ForceForeground($hwnd); Start-Sleep -Milliseconds 500
    Write-Host "foreground is notepad: $([Win]::GetForegroundWindow() -eq $hwnd)"
    [Win]::Key(0xA3, $false, $true)
    Start-Sleep -Milliseconds 1200
    [Win]::Key(0xA3, $true, $true)

    $text = $null
    $t0 = Get-Date
    while (((Get-Date) - $t0).TotalSeconds -lt 60) {
        $text = Get-NotepadText
        if ($text -and $text.Trim().Length -gt 0) { break }
        Start-Sleep -Milliseconds 500
    }
    Write-Host "Notepad text: '$text'"
    if (-not $text) { Fail 'nothing was pasted into Notepad' }
    if ($text.Trim() -cne $Expected) { Fail "Notepad contains '$text', expected '$Expected'" }
    Write-Host 'PASS: dictation pasted the cleaned sentence into Notepad'

    # Vocabulary learning: replace "Friday." with an unknown word by typing, then expect a suggestion.
    Start-Sleep -Milliseconds 600
    for ($i = 0; $i -lt 7; $i++) { Tap 0x08 }
    foreach ($c in 'zyntrex'.ToCharArray()) { Tap ([int][char]::ToUpper($c)) }
    $hist = Join-Path $appdata 'history.jsonl'
    $t0 = Get-Date
    $found = $false
    while (((Get-Date) - $t0).TotalSeconds -lt 20) {
        if ((Test-Path $hist) -and ((Get-Content -Raw $hist) -match 'vocab-suggest')) { $found = $true; break }
        Start-Sleep -Milliseconds 500
    }
    Write-Host ("Notepad text after edit: '" + (Get-NotepadText) + "'")
    if (-not $found) { Fail 'the vocabulary learner did not offer a suggestion after the edit' }
    Write-Host 'PASS: vocabulary learner offered a suggestion'
    Write-Host (Get-Content -Raw $hist)

    # UI Automation reader inside murmur.exe itself.
    $o = Join-Path $work 'uia.txt'
    Start-Process -FilePath $Murmur -ArgumentList @('--uia-read-focused') -Wait -NoNewWindow -RedirectStandardOutput $o -RedirectStandardError (Join-Path $work 'uia.err') | Out-Null
    Write-Host ("murmur --uia-read-focused: '" + ((Get-Content -Raw $o) -as [string]).Trim() + "'")
}
finally {
    if (Test-Path (Join-Path $appdata 'debug.log')) { Write-Host '--- murmur debug.log ---'; Get-Content (Join-Path $appdata 'debug.log') | Select-Object -Last 80 }
    Stop-Process -Id $m.Id -Force -ErrorAction SilentlyContinue
    Get-Process llama-server -ErrorAction SilentlyContinue | Stop-Process -Force
    Get-Process notepad -ErrorAction SilentlyContinue | Stop-Process -Force
    Copy-Item -Recurse -Force $appdata (Join-Path $(if ($env:GITHUB_WORKSPACE) { $env:GITHUB_WORKSPACE } else { $work }) 'e2e-appdata') -ErrorAction SilentlyContinue
}
