# Murmur

Native macOS menu-bar push-to-talk dictation (whisper.cpp + local or Anthropic cleanup).

## Setup
1. `brew install whisper-cpp ollama`; `ollama pull qwen3:4b-instruct-2507-q4_K_M`.
2. Model at `models/ggml-large-v3-turbo.bin` (or `~/Library/Application Support/Murmur/models/`, or `$MURMUR_MODEL`).
3. `scripts/build.sh`, then `scripts/install.sh` (copies to `~/Applications`) and open Murmur.
   Murmur starts `whisper-server` on port 8178 if none is running, and stops only the one it started.

## Permissions
Menu > Check permissions. Grant Microphone, Accessibility (paste, text-before-cursor) and Input Monitoring (hotkey), then restart Murmur.
The app is ad-hoc signed, so rebuilding may require re-granting.

## Hotkeys
- Hold Fn/Globe: record while held (holds under 250 ms are ignored).
- Fn + Space, or double-tap Fn: hands-free; press Fn again to finish.
- Esc: cancel.
- Menu > Hotkey: switch to Right Option. Menu > "Disable Globe emoji popup" stops the emoji picker.

## Other
- Vocabulary/snippets: `~/Library/Application Support/Murmur/dictionary.json`, `[{"phrase","replacement"?}]`.
- History: `history.jsonl` in the same folder.
- Anthropic provider: Menu > Set Anthropic key… (Keychain).
- Headless test: `Murmur --transcribe file.wav --bundle-id com.apple.Terminal [--before "text"]`.

## Wispr Flow
Quit Wispr Flow or change its hotkey, otherwise both apps capture the same key.

## How it matches Wispr Flow (clean-room)

Nothing was decompiled or copied from Wispr Flow. Its behaviour was matched black-box: `eval/` replays your own Wispr Flow history (the audio, raw transcript and formatted text that WF stores locally in `flow.sqlite`) through Murmur and scores the output against what WF produced. The clips are exported to `eval/data/`, which is gitignored.

| Stage | Metric (80 of your clips) | Result |
|---|---|---|
| ASR: whisper large-v3-turbo + vocab prompt | WER vs WF raw transcript | 5.2%, 0.26 s p50 |
| Cleanup: qwen3:4b, given WF's own transcript | format-error vs WF output (raw passthrough = 8.6%) | **7.9%**, 0.47 s p50 |
| Cleanup: qwen3:14b (optional, slower) | same | 6.5%, 1.8 s p50 |
| Full Murmur binary | format-error vs WF output | 14.3%, ~1.0 s wall |

Format-error is a token edit distance that counts case, punctuation and line breaks. Most of the remaining end-to-end gap is ASR word choice: WF runs a proprietary cloud ASR, and Murmur runs Whisper locally.

To reproduce:
```
python3 -I eval/export.py eval/data 80
python3 -I eval/asr_eval.py eval/data 8178 eval/out/asr.json
python3 -I eval/fmt_eval.py eval/data qwen3:4b-instruct-2507-q4_K_M wfasr eval/out/fmt.json
python3 -I eval/swift_e2e.py eval/data build/Murmur.app/Contents/MacOS/Murmur eval/out/e2e.json
```
For higher fidelity, set the provider to Anthropic (Claude Haiku 5.5) and run `defaults write com.aidanjones.murmur ollamaModel qwen3:14b`, or run `fmt_eval.py` with `claude-haiku-5-5` and `ANTHROPIC_API_KEY` set to measure it.
