# Murmur

Hold a key, talk, let go: clean, punctuated text appears wherever your cursor is. Murmur is a free, open-source push-to-talk dictation app for macOS that runs **entirely on your Mac**. No account, no subscription, and your voice never leaves the computer.

> **Status: early.** Murmur is installed by building from source with one script (below). A prebuilt download is in progress; Windows is in beta.

## Install with your AI agent
Paste this into Claude Code, Codex or any coding agent, from an empty folder:

> Clone https://github.com/aidanmcjones/murmur, read AGENTS.md, and install Murmur on this computer; tell me only what I have to click myself.

The agent runs the installer, verifies it, and lists the few steps only you can do (permissions).

## Install by hand

### Mac (Apple Silicon, macOS 14+)
```
git clone https://github.com/aidanmcjones/murmur && cd murmur
scripts/setup.sh
```
`setup.sh` checks your system, downloads the official llama.cpp release and the cleanup model (about 2.5 GB) into `~/Library/Application Support/Murmur`, builds Murmur, installs `~/Applications/Murmur.app` and opens it. No Homebrew needed. It is safe to re-run. Options: `--prefix DIR`, `--no-open`, `--accurate` (also installs Whisper for Accurate mode; needs Homebrew). If the Xcode Command Line Tools are missing it opens their installer and exits; finish that and run it again. The app is signed locally, not by Apple, so the first time macOS may ask you to right-click > Open.

### Windows (beta)
```
git clone https://github.com/aidanmcjones/murmur && cd murmur
powershell -ExecutionPolicy Bypass -File scripts/setup.ps1
```
If SmartScreen warns about an unsigned app, choose More info > Run anyway. The Windows version is new and less polished than the Mac app.

## Features
- **Fast:** text is usually pasted 150-350 ms after you release the key. Speech recognition runs on the Apple Neural Engine.
- **Clean:** removes filler words, applies self-corrections ("at three, no wait, four" -> "at 4"), writes numbers as digits, handles spoken punctuation, formats lists, and adapts to the app you are typing in (chat, email, terminal and AI tools).
- **Self-learning vocabulary:** when you fix a misheard name or term right after dictating (for example "collab tree" -> "Kolabtree"), Murmur offers to remember it in a small pop-up. Accepted fixes are applied automatically from then on, including near-miss spellings. Menu toggles turn learning on or off; **Add word...** adds a term by hand; **Enable screen-text learning...** also notices corrections in apps Murmur cannot read directly, by reading the text on screen (needs Screen Recording permission; off by default).
- **Custom push-to-talk key:** fn/Globe by default, or any modifier or F-key via the menu (Push-to-talk key > Set custom key...). Needed for many third-party keyboards.
- **Snippets and vocabulary:** `dictionary.json`, plus import from Wispr Flow.
- Inspired by Wispr Flow's experience and tuned against it black-box (see below). Not affiliated with Wispr.

## Privacy
Speech recognition and cleanup run on your computer with open models. There is no account, no telemetry, and your audio and text are never uploaded. The only network use is downloading models and the llama.cpp release during install and first launch (and the optional cloud cleanup provider if you enter your own API key). Vocabulary learning keeps only the word pairs you accept; screen-text learning reads the screen locally and sends nothing anywhere.

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
