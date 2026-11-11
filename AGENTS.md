# Installing and working on Murmur (for AI coding agents)

Murmur is a local push-to-talk dictation app. When the user asks you to install it, do the steps below yourself; do not hand the user commands to run.

## Install

1. Detect the OS (`uname -s`, or `$OS` / `ver` on Windows).
2. macOS (Apple Silicon, macOS 14+): from the repo root run `scripts/setup.sh --no-open`, then open the app with `open ~/Applications/Murmur.app`. It is idempotent and non-interactive. Options: `--prefix DIR` (default `~/Applications`), `--force`, `--accurate` (Whisper mode, needs Homebrew; otherwise it stays off and the script says so).
3. Windows (beta): `powershell -ExecutionPolicy Bypass -File scripts/setup.ps1`.
4. Any other OS or Intel Mac is unsupported: say so and stop.

If Murmur is already running from the install folder, the script finishes downloads, leaves the installed app alone and exits 0 saying "Quit Murmur and re-run, or pass --force": ask the user before quitting it or using `--force`.

Exit code 3 from `setup.sh` means the Xcode Command Line Tools install dialog was opened. Tell the user to finish it, then re-run the script. Exit 4 means a download failed: re-run (downloads resume).

## What only the human can do
- Finish the Xcode Command Line Tools dialog (macOS, first time only).
- Grant **Microphone** and **Accessibility** to Murmur (System Settings > Privacy & Security). Optional: **Screen Recording** for screen-text learning.
- First launch of an unsigned app: right-click > Open (macOS), or "More info > Run anyway" if Windows SmartScreen appears.
- Press their push-to-talk key and speak to confirm it works.

Never click through permission dialogs, send keystrokes, or take screenshots on the user's machine unless they ask.

## Verify (run these yourself)
```
~/Applications/Murmur.app/Contents/MacOS/Murmur --learn-selftest                      # ends with ALL PASS
~/Applications/Murmur.app/Contents/MacOS/Murmur --check-test-vectors shared/test-vectors   # N/N cases match
~/Applications/Murmur.app/Contents/MacOS/Murmur --clean-text "um so I I think so"      # -> So I think so
~/Applications/Murmur.app/Contents/MacOS/Murmur --transcribe some.wav --bundle-id com.apple.TextEdit
```
Use your `--prefix` path if you changed it. Data lives in `~/Library/Application Support/Murmur` (`bin/`, `models/`, `dictionary.json`, `debug.log`). Do not quit or relaunch a Murmur the user is already running without asking.

## Troubleshooting
| Symptom | Fix |
|---|---|
| Hotkey does nothing | Accessibility is not granted: Murmur menu > Check permissions, or System Settings > Privacy & Security > Accessibility, switch Murmur on, relaunch. |
| Fn/Globe key does nothing (Keychron, Logitech, other third-party keyboards) | The keyboard handles fn itself. Menu > Push-to-talk key > Set custom key... and press a modifier (e.g. right Option) or F-key. |
| Recording fails or silent | Microphone is not granted (System Settings > Privacy & Security > Microphone), or another app holds the mic. |
| Model download failed (exit 4) | Re-run `scripts/setup.sh`; it resumes and checks size and SHA-256. Needs about 3 GB free. |
| Permissions reset after a rebuild | Builds without the "Murmur Local Signing" certificate are ad-hoc signed, so macOS forgets grants. Re-grant once, or create the local certificate. |
| No cleanup LLM | `ls ~/Library/Application\ Support/Murmur/bin/llama-server` and the `.gguf` in `models/`; re-run `scripts/setup.sh`. Dictation still works with deterministic cleanup. |
| Both Murmur and Wispr Flow react to fn | Quit Wispr Flow or change one hotkey. |

## Developing
- Build: `scripts/build.sh` (SwiftPM, macOS). One build at a time; it is memory hungry.
- Tests: `Murmur --learn-selftest`, `Murmur --check-test-vectors shared/test-vectors`. Regenerate vectors only when behavior intentionally changes: `Murmur --dump-test-vectors shared/test-vectors`; the Windows port consumes them.
- Windows port: `windows/` and `scripts/setup.ps1`.
