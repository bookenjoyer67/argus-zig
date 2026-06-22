#!/usr/bin/env bash
# Build a merged Argus firmware image and publish it as a GitHub Release.
# The Pages workflow (.github/workflows/pages.yml) then pulls the asset into
# web/firmware/ so the web flasher serves it same-origin.
#
# Usage: tools/release.sh [tag]   (default tag: v1.0.0)
set -eo pipefail

TAG="${1:-v1.0.0}"
cd "$(dirname "$0")/.."

echo "=== Building Zig library ==="
./build-zig.sh

echo "=== ESP-IDF env ==="
# shellcheck disable=SC1090
source "${IDF_PATH:-$HOME/esp/esp-idf}/export.sh"

echo "=== idf.py build + merge-bin ==="
idf.py build
idf.py merge-bin -o argus-merged.bin

echo "=== Publishing release $TAG ==="
gh release create "$TAG" argus-merged.bin \
  --title "Argus $TAG" \
  --notes "Prebuilt firmware for the Heltec WiFi LoRa 32 V3 (ESP32-S3). Flash from a desktop Chrome/Edge browser at https://bookenjoyer67.github.io/argus-zig/web/flash.html"

echo "=== Done. Pages will fetch argus-merged.bin on the next deploy. ==="
