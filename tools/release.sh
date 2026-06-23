#!/usr/bin/env bash
# Build merged Argus firmware images for every board and publish them as a
# GitHub Release. The Pages workflow (.github/workflows/pages.yml) then pulls
# the assets into web/firmware/<board>/ so the web flasher serves them
# same-origin (per-board manifests + a board picker in web/flash.html).
#
# Produces, per board:
#   argus-<slug>-merged.bin   full image @ offset 0 (web flasher / USB)
#   argus-<slug>.bin          app-only image (OTA)
#
# Usage: tools/release.sh [tag]   (default tag: v1.0.0)
set -eo pipefail

TAG="${1:-v1.0.0}"
cd "$(dirname "$0")/.."

echo "=== ESP-IDF env ==="
# shellcheck disable=SC1090
source "${IDF_PATH:-$HOME/esp/esp-idf}/export.sh"

DIST="$(pwd)/dist"
rm -rf "$DIST"
mkdir -p "$DIST"

# build_board <BOARD> <slug> <sdkconfig-defaults>
build_board() {
    local board="$1" slug="$2" defaults="$3"
    echo ""
    echo "=== Building $board -> argus-$slug-merged.bin ==="

    # Stage 1 — Zig static library for this board.
    BOARD="$board" ./build-zig.sh

    # Stage 2 — clean ESP-IDF reconfigure so a previous board's sdkconfig never
    # leaks in, then build + merge.
    rm -f sdkconfig
    idf.py fullclean >/dev/null 2>&1 || true
    idf.py -DBOARD="$board" -DSDKCONFIG_DEFAULTS="$defaults" set-target esp32s3
    python tools/patch-sdkconfig.py
    idf.py -DBOARD="$board" -DSDKCONFIG_DEFAULTS="$defaults" build

    # merge-bin reads the current build/ — no -D needed (avoids a reconfigure).
    idf.py merge-bin -o "$DIST/argus-$slug-merged.bin"
    cp build/argus-zig.bin "$DIST/argus-$slug.bin"
}

build_board heltec_v3 heltec-v3 "sdkconfig.defaults"
build_board tdeck     tdeck     "sdkconfig.defaults;sdkconfig.defaults.tdeck"

# OTA asset (Heltec for now): keep the stable name the device + Pages expect.
cp "$DIST/argus-heltec-v3.bin" "$DIST/argus-zig.bin"

echo ""
echo "=== Publishing release $TAG ==="
gh release create "$TAG" \
    "$DIST/argus-heltec-v3-merged.bin" \
    "$DIST/argus-tdeck-merged.bin" \
    "$DIST/argus-zig.bin" \
    --title "Argus $TAG" \
    --notes "Prebuilt firmware for the Heltec WiFi LoRa 32 V3 and Lilygo T-Deck (ESP32-S3). Pick your board and flash from desktop Chrome/Edge at https://bookenjoyer67.github.io/argus-zig/web/flash.html"

# Deploy Pages from main (the github-pages environment rejects tag refs).
echo "=== Triggering Pages deploy ==="
gh workflow run pages.yml --ref main

echo "=== Done. Pages will publish the per-board binaries shortly. ==="
