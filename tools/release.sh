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
# argus-merged.bin: full image for the web flasher (USB).
# argus-zig.bin:    app-only image for OTA (HTTPS + BLE).
gh release create "$TAG" build/argus-merged.bin build/argus-zig.bin \
  --title "Argus $TAG" \
  --notes "Prebuilt firmware for the Heltec WiFi LoRa 32 V3 (ESP32-S3). Flash from a desktop Chrome/Edge browser at https://bookenjoyer67.github.io/argus-zig/web/flash.html"

# Deploy Pages from main (the github-pages environment rejects tag refs, so we
# can't trigger off the release event). This pulls the new release assets into
# web/firmware/ and writes version.json.
echo "=== Triggering Pages deploy ==="
gh workflow run pages.yml --ref main

echo "=== Done. Pages will publish the new binaries + version.json shortly. ==="
