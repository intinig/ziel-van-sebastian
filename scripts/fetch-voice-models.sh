#!/bin/bash
# Downloads whisper + VAD models to the app-support models dir (idempotent).
#
# Usage: ./scripts/fetch-voice-models.sh [model ...]
#   model = a whisper.cpp repo model name suffix, e.g. base.en, base, small,
#   small.en, medium (see https://huggingface.co/ggerganov/whisper.cpp for
#   the full list). Defaults to base.en when no models are given. The Silero
#   VAD model is always fetched in addition to whatever whisper model(s) are
#   requested.
set -euo pipefail
DIR="$HOME/Library/Application Support/Ziel van Sebastian/models"
mkdir -p "$DIR"

if [ "$#" -eq 0 ]; then
  set -- base.en
fi

for MODEL in "$@"; do
  [ -f "$DIR/ggml-$MODEL.bin" ] || { curl -fL -o "$DIR/ggml-$MODEL.bin.tmp" \
    "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-$MODEL.bin" && \
    mv "$DIR/ggml-$MODEL.bin.tmp" "$DIR/ggml-$MODEL.bin"; }
done

[ -f "$DIR/ggml-silero-v5.1.2.bin" ] || { curl -fL -o "$DIR/ggml-silero-v5.1.2.bin.tmp" \
  "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin" && \
  mv "$DIR/ggml-silero-v5.1.2.bin.tmp" "$DIR/ggml-silero-v5.1.2.bin"; }
ls -lh "$DIR"
