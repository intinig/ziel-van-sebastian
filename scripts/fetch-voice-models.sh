#!/bin/bash
# Downloads whisper + VAD models to the app-support models dir (idempotent).
set -euo pipefail
DIR="$HOME/Library/Application Support/Ziel van Sebastian/models"
mkdir -p "$DIR"
[ -f "$DIR/ggml-base.en.bin" ] || curl -L -o "$DIR/ggml-base.en.bin" \
  "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin"
[ -f "$DIR/ggml-silero-v5.1.2.bin" ] || curl -L -o "$DIR/ggml-silero-v5.1.2.bin" \
  "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin"
ls -lh "$DIR"
