#!/bin/bash
# Builds whisper.cpp v1.9.1 as static libs (Metal embedded) into Vendor/whisper/.
# Vendor/ is gitignored; run once per checkout (make vendor).
set -euo pipefail
cd "$(dirname "$0")/.."
PIN=v1.9.1
BUILD=.vendor-build/whisper.cpp
if [ ! -d "$BUILD" ]; then
  mkdir -p .vendor-build
  git clone --depth 1 --branch "$PIN" https://github.com/ggml-org/whisper.cpp.git "$BUILD"
fi
cmake -S "$BUILD" -B "$BUILD/build" -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
  -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
  -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON \
  -DWHISPER_BUILD_EXAMPLES=OFF -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF
cmake --build "$BUILD/build" -j "$(sysctl -n hw.ncpu)"
mkdir -p Vendor/whisper/lib Vendor/whisper/include
cp "$BUILD/build/src/libwhisper.a" Vendor/whisper/lib/
find "$BUILD/build/ggml" -name 'libggml*.a' -exec cp {} Vendor/whisper/lib/ \;
cp "$BUILD/include/whisper.h" "$BUILD"/ggml/include/ggml*.h Vendor/whisper/include/
cat > Vendor/whisper/include/module.modulemap <<'EOF'
module CWhisper {
    header "whisper.h"
    export *
}
EOF
echo "vendored: $(ls Vendor/whisper/lib)"
