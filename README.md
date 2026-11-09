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

Nothing was decompiled or copied from Wispr Flow. Its behaviour was matched black-box: `eval/` replays your own Wispr Flow history (the audio, raw transcript and formatted text that WF stores locally in `flow.sqlite`) through Murmur and scores the output against what WF produced. Clips are exported to `eval/data*/`, which is gitignored.

### November 2026 revision: accuracy and latency

Measured on 250 held-out clips (not used for any tuning), against Wispr Flow's own output:

| | WER vs WF transcript | Format-error vs WF output |
|---|---|---|
| Parakeet TDT v2 (old Fast engine) | 6.7% | 17.5% (ASR + deterministic cleanup) |
| Whisper large-v3-turbo (Accurate) | 3.5% (210 ms p50) | |
| **Parakeet Ultra (new default)** | **2.8% (47 ms p50)** | **12.9% full app, headless** |
| WF's own transcript, passed through | 0% | 9.8% |

Wispr Flow's measured release-to-paste latency on this Mac (its `e2eLatency` field, last 400 dictations): 322 ms p50, 530 ms p90.

What changed and why:
- **Engine:** Parakeet Ultra (`AsrModelVersion.ultra`) replaces v2. `defaults write com.aidanjones.murmur parakeetVersion v2` reverts.
- **Dropped words:** the word-level background-speech gate deleted the speaker's own sentence-final words ("for me. You say" → "for say"). It is now off (`pkWordGate` re-enables it). A bare "▁" token no longer glues words together ("the11-hour").
- **Cleanup LLM is gated:** the local 4B model was neutral-to-harmful for fidelity (it reworded, censored profanity and sometimes answered the dictation), so it now runs only when the transcript has self-corrections, fillers, spoken punctuation or repeats (~7% of dictations), behind a stricter output guard. Everything else gets deterministic cleanup with no LLM latency. `defaults write com.aidanjones.murmur alwaysLLM -bool true` restores the old behaviour.
- **Latency:** cleanup requests stream, so cancelled speculative jobs stop the server immediately instead of queueing in front of the final request; after key release cleanup has a 0.9 s hard budget, past which the deterministic cleanup is pasted. A one-time migration moves the cleanup provider off Ollama, which reloaded its model after 30 min idle and hit the 4 s timeout.
- Switching to Parakeet stops Murmur's Whisper server (1.6 GB).
- `history.jsonl` records `mode` (`det`, `llm`, `timeout`) per dictation.

To reproduce (scripts under `eval/`):
```
python3 -I eval/export2.py eval/data2 250 eval/data/set.jsonl
(cd eval/asrbench && swift build -c release); eval/asrbench/.build/release/asrbench eval/data2 eval/out - v2 ultra unified
python3 -I eval/score_asr.py eval/data2 eval eval/out/asr_*.json
python3 -I eval/cleanup_eval.py eval/data2 eval/out/asr_wfasr.json . 8179 eval/out/ce_wfasr.json
python3 -I eval/swift_e2e.py eval/data2 build/Murmur.app/Contents/MacOS/Murmur eval/out/e2e.json
```
Cleanup runs on Murmur's own llama.cpp server (port 8179, `models/qwen3-4b-instruct-2507-q4_K_M.gguf`) with the weights mlock'ed in RAM. Murmur is signed with a local "Murmur Local Signing" certificate so macOS permission grants survive rebuilds.
