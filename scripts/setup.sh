#!/bin/bash
# One-shot, non-interactive installer for Murmur on Apple Silicon. Safe to re-run.
#   scripts/setup.sh [--prefix DIR] [--no-open] [--accurate] [--force]
# Env: MURMUR_SUPPORT_DIR (data folder, default ~/Library/Application Support/Murmur; for tests),
#      MURMUR_SKIP_MODEL=1 (skip the 2.5 GB cleanup model), MURMUR_SKIP_LLM=1 (skip llama.cpp and the model).
# Exit codes: 0 ok, 2 unsupported system or bad usage, 3 Xcode Command Line Tools being installed, 4 download failed.
set -euo pipefail
CALLER_PWD="$PWD"
cd "$(dirname "$0")/.."

LLAMA_TAG="b11429"
LLAMA_URL="https://github.com/ggml-org/llama.cpp/releases/download/$LLAMA_TAG/llama-$LLAMA_TAG-bin-macos-arm64.tar.gz"
LLAMA_SHA256="740288ec6887be94280a5dfa25b5e23a78285cab104519e6c7e218904ee82459"
MODEL_NAME="qwen3-4b-instruct-2507-q4_K_M.gguf"
MODEL_URL="https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF/resolve/main/Qwen3-4B-Instruct-2507-Q4_K_M.gguf"
MODEL_SIZE=2497281120
MODEL_SHA256="3605803b982cb64aead44f6c1b2ae36e3acdb41d8e46c8a94c6533bc4c67e597"
WHISPER_NAME="ggml-large-v3-turbo.bin"
WHISPER_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3-turbo.bin"
WHISPER_SIZE=1624555275
WHISPER_SHA256="1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69"

PREFIX="$HOME/Applications"; OPEN=1; ACCURATE=0; FORCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) [ $# -ge 2 ] || { echo "--prefix needs a directory" >&2; exit 2; }; PREFIX="$2"; shift 2 ;;
    --no-open) OPEN=0; shift ;;
    --accurate) ACCURATE=1; shift ;;
    --force) FORCE=1; shift ;;
    -h|--help) sed -n 2,6p "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

abspath() { case "$1" in /*) printf %s "$1" ;; "~") printf %s "$HOME" ;; "~/"*) printf %s "$HOME/${1#"~/"}" ;; *) printf %s "$CALLER_PWD/$1" ;; esac; }
PREFIX="$(abspath "$PREFIX")"
SUPPORT="$(abspath "${MURMUR_SUPPORT_DIR:-$HOME/Library/Application Support/Murmur}")"
CURLQ="--progress-bar"; [ -t 1 ] || CURLQ="-sS"
say() { printf '==> %s\n' "$*"; }

# 1. System checks.
[ "$(uname -s)" = Darwin ] || { echo "Murmur's macOS installer runs on macOS only." >&2; exit 2; }
[ "$(uname -m)" = arm64 ] || { echo "Apple Silicon (arm64) is required." >&2; exit 2; }
MACOS_MAJOR=$(sw_vers -productVersion | cut -d. -f1)
[ "$MACOS_MAJOR" -ge 14 ] || { echo "macOS 14 or later is required (found $(sw_vers -productVersion))." >&2; exit 2; }
if ! xcode-select -p >/dev/null 2>&1 || ! command -v swift >/dev/null 2>&1; then
  xcode-select --install >/dev/null 2>&1 || true
  echo "Xcode Command Line Tools are missing. A macOS dialog was opened: click Install, wait for it to finish, then re-run scripts/setup.sh." >&2
  exit 3
fi
say "System OK: macOS $(sw_vers -productVersion), arm64, $(swift --version 2>&1 | head -n1)"

mkdir -p "$SUPPORT/bin" "$SUPPORT/models" "$PREFIX"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/murmur-setup.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

sha_of() { shasum -a 256 "$1" | cut -d' ' -f1; }
size_of() { stat -f %z "$1"; }

# Resumable download to $2 with exact size ($3) and SHA-256 ($4) checks. A fresh download always re-verifies.
fetch_big() {
  local url="$1" dest="$2" size="$3" sha="$4" part="$2.part" mark i
  mark="$(dirname "$dest")/.$(basename "$dest").verified"
  if [ -f "$dest" ] && [ "$(size_of "$dest")" = "$size" ]; then
    say "Reusing $(basename "$dest")"
  else
    rm -f "$dest" "$mark"
    for i in 1 2 3 4 5; do
      curl $CURLQ -L --fail --retry 3 -C - -o "$part" "$url" || true
      if [ -f "$part" ] && [ "$(size_of "$part")" = "$size" ]; then rm -f "$mark"; mv "$part" "$dest"; break; fi
      if [ -f "$part" ] && [ "$(size_of "$part")" -gt "$size" ]; then rm -f "$part"; fi
      echo "Download incomplete (attempt $i/5), retrying..." >&2
    done
    [ -f "$dest" ] || { echo "Download failed: $url. Re-run scripts/setup.sh to resume." >&2; exit 4; }
  fi
  if [ ! -f "$mark" ]; then
    [ "$(sha_of "$dest")" = "$sha" ] || { rm -f "$dest" "$mark"; echo "$(basename "$dest") checksum mismatch; deleted. Re-run to download again." >&2; exit 4; }
    : > "$mark"
  fi
}

# 2. llama.cpp (prebuilt official release; no Homebrew needed).
if [ "${MURMUR_SKIP_LLM:-0}" = 1 ]; then
  say "Skipping llama.cpp and the cleanup model (MURMUR_SKIP_LLM=1)"
else
  if [ -x "$SUPPORT/bin/llama-server" ] && [ "$(cat "$SUPPORT/bin/.llama-tag" 2>/dev/null)" = "$LLAMA_TAG" ]; then
    say "Reusing llama.cpp $LLAMA_TAG"
  else
    say "Downloading llama.cpp $LLAMA_TAG"
    curl $CURLQ -L --fail --retry 3 -o "$TMP/llama.tar.gz" "$LLAMA_URL" || { echo "llama.cpp download failed" >&2; exit 4; }
    [ "$(sha_of "$TMP/llama.tar.gz")" = "$LLAMA_SHA256" ] || { echo "llama.cpp checksum mismatch" >&2; exit 4; }
    mkdir -p "$TMP/llama"
    tar -xzf "$TMP/llama.tar.gz" -C "$TMP/llama"
    SRC="$TMP/llama/llama-$LLAMA_TAG"
    [ -x "$SRC/llama-server" ] || { echo "llama-server missing from the llama.cpp archive" >&2; exit 4; }
    cp -a "$SRC"/lib*.dylib "$SUPPORT/bin/"
    cp -f "$SRC/llama-server" "$SUPPORT/bin/llama-server"
    echo "$LLAMA_TAG" > "$SUPPORT/bin/.llama-tag"
  fi
  "$SUPPORT/bin/llama-server" --version >/dev/null 2>&1 || { echo "llama-server does not run" >&2; exit 4; }

  # 3. Cleanup model.
  if [ "${MURMUR_SKIP_MODEL:-0}" = 1 ]; then
    say "Skipping the cleanup model (MURMUR_SKIP_MODEL=1)"
  else
    fetch_big "$MODEL_URL" "$SUPPORT/models/$MODEL_NAME" "$MODEL_SIZE" "$MODEL_SHA256"
  fi
fi

# 4. Accurate (Whisper) mode: optional, needs Homebrew.
if [ "$ACCURATE" = 1 ]; then
  if command -v brew >/dev/null 2>&1; then
    command -v whisper-server >/dev/null 2>&1 || brew install whisper-cpp
    fetch_big "$WHISPER_URL" "$SUPPORT/models/$WHISPER_NAME" "$WHISPER_SIZE" "$WHISPER_SHA256"
    say "Accurate mode ready: choose Speech engine > Accurate in the Murmur menu."
  else
    say "Accurate mode left disabled: it needs Homebrew (https://brew.sh) for whisper-cpp. Fast mode works without it."
  fi
fi

# 5. Build and install.
if [ "$FORCE" != 1 ] && pgrep -f "$PREFIX/Murmur.app/Contents/MacOS/Murmur" >/dev/null 2>&1; then
  say "Murmur is running from $PREFIX/Murmur.app. Downloads are done; the installed app was not replaced."
  echo "Quit Murmur and re-run, or pass --force." >&2
  exit 0
fi
say "Building Murmur (first build takes a few minutes)"
nice -n 10 scripts/build.sh
rm -rf "$PREFIX/Murmur.app"
cp -R build/Murmur.app "$PREFIX/Murmur.app"
say "Installed $PREFIX/Murmur.app"

cat <<MSG

Next steps (only you can do these):
  1. Open Murmur: open "$PREFIX/Murmur.app"   (first time: right-click > Open if macOS asks)
  2. Allow Microphone when prompted.
  3. System Settings > Privacy & Security > Accessibility: switch Murmur on (needed for the hotkey and paste).
  4. Hold fn/Globe, speak, release. On third-party keyboards use menu > Push-to-talk key > Set custom key...
The speech model (Parakeet) downloads on first launch (about a minute).
MSG
if [ "$OPEN" = 1 ]; then open "$PREFIX/Murmur.app"; fi
