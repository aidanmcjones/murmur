# Murmur

Hold a key, talk, let go: clean, punctuated text appears wherever your cursor is. Murmur is a free, open-source push-to-talk dictation app for macOS that runs **entirely on your Mac**. No account, no subscription, and your voice never leaves the computer.

- **Fast:** text is usually pasted 150–350 ms after you release the key. Speech recognition runs on the Apple Neural Engine.
- **Clean:** it removes filler words, applies self-corrections ("at three, no wait, four" → "at 4"), writes numbers as digits, fixes punctuation, formats lists, and adjusts to the app you're typing in.
- **Private:** speech recognition and cleanup both run locally with open models.
- Inspired by Wispr Flow's experience and tuned against it black-box (see below). Not affiliated with Wispr.

> **Status: early.** You currently build Murmur from source (below). A prebuilt download and a Windows version are in progress.

## Requirements
- A Mac with Apple Silicon running macOS 14 or later.
- Xcode Command Line Tools (`xcode-select --install`).
- [Homebrew](https://brew.sh) `llama.cpp` for the cleanup model: `brew install llama.cpp`. Accurate mode also needs `brew install whisper-cpp`.
- About 4 GB of disk for models.

## Install from source
```
git clone https://github.com/aidanmcjones/murmur && cd murmur
mkdir -p ~/Library/Application\ Support/Murmur/models
curl -L -o ~/Library/Application\ Support/Murmur/models/qwen3-4b-instruct-2507-q4_K_M.gguf \
  https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF/resolve/main/Qwen3-4B-Instruct-2507-Q4_K_M.gguf
scripts/build.sh && scripts/install.sh && open ~/Applications/Murmur.app
```
The speech model (Parakeet) downloads on first launch, which takes about a minute. The app is signed locally, not by Apple, so macOS may ask you to confirm the first time you open it: right-click → Open.

## Permissions
On first launch, allow **Microphone** and **Accessibility**. Accessibility lets Murmur see the hotkey and paste. If dictation doesn't start, open Murmur's menu → **Check permissions**.

## Using it
- **Hold fn/🌐**, speak, release. Holds under 250 ms are ignored.
- **Double-tap fn**, or fn + Space, for hands-free mode. Press fn again to finish.
- **Esc** cancels.
- **Other keyboards:** many third-party keyboards (Keychron, Logitech…) handle fn inside the keyboard, so the Mac never sees it. Use Murmur menu → **Push-to-talk key → Set custom key…** and press a modifier (for example right ⌥) or an F-key.
- fn shortcuts such as fn+Delete keep working; Murmur cancels quietly when another key is pressed.
- The menu is under the Dock icon, and the menu-bar icon if your menu bar has room.

Settings in the menu:
- **Speech engine:** Fast (Parakeet, default) or Accurate (Whisper large-v3-turbo; slower, better with background noise).
- **Vocabulary and snippets:** `~/Library/Application Support/Murmur/dictionary.json`, `[{"phrase": "...", "replacement": "..."}]`. Menu → *Import from Wispr Flow* copies an existing Wispr Flow dictionary.
- **History:** `history.jsonl` in the same folder.

If you also run Wispr Flow, quit it or change its hotkey, otherwise both apps react to fn.

## Credits and licenses
Murmur is MIT-licensed (see `LICENSE`). It builds on:
- [FluidAudio](https://github.com/FluidInference/FluidAudio) (Apache-2.0), which runs NVIDIA Parakeet TDT speech models on CoreML. See each model's card for its license; Parakeet TDT models are CC-BY-4.0.
- [llama.cpp](https://github.com/ggml-org/llama.cpp) and [whisper.cpp](https://github.com/ggml-org/whisper.cpp) (MIT).
- Qwen3-4B-Instruct-2507 (Apache-2.0) for cleanup, and OpenAI Whisper large-v3-turbo (MIT) for Accurate mode.

---

# Development notes

Headless test: `Murmur --transcribe file.wav --bundle-id com.apple.Terminal [--before "text"]`. Debug log: `~/Library/Application Support/Murmur/debug.log`.

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
