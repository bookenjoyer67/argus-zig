#!/bin/bash
# ================================================================
# build-all.sh — build every supported board for a release
# ================================================================
#
# Produces per-board firmware artifacts under release/<board>/:
#   bootloader.bin  partition-table.bin  ota_data_initial.bin  argus-zig.bin
#
# Two-stage per board: BOARD=<board> ./build-zig.sh (Zig static lib), then a
# clean ESP-IDF reconfigure with the right sdkconfig defaults + idf.py build.
#
# Prereqs: ESP-IDF env sourced (source ~/esp/esp-idf/export.sh) and the
# Espressif Zig fork at ~/zig-xtensa/zig (see build-zig.sh).
#
# Usage:
#   source ~/esp/esp-idf/export.sh
#   tools/build-all.sh

set -e
cd "$(dirname "$0")/.."   # repo root

if ! command -v idf.py >/dev/null 2>&1; then
    echo "ERROR: ESP-IDF not on PATH. Run: source ~/esp/esp-idf/export.sh" >&2
    exit 1
fi

build_board() {
    local board="$1"
    local defaults="$2"
    echo ""
    echo "================================================================"
    echo "  Building board: $board"
    echo "================================================================"

    # Stage 1 — Zig static library (selects src/boards/<board>.zig).
    BOARD="$board" ./build-zig.sh

    # Stage 2 — ESP-IDF. Fresh sdkconfig from the board's defaults so a previous
    # board's config never leaks in.
    rm -f sdkconfig
    idf.py fullclean >/dev/null 2>&1 || true
    idf.py -DBOARD="$board" -DSDKCONFIG_DEFAULTS="$defaults" set-target esp32s3
    python tools/patch-sdkconfig.py
    idf.py -DBOARD="$board" -DSDKCONFIG_DEFAULTS="$defaults" build

    # Collect artifacts.
    local out="release/$board"
    mkdir -p "$out"
    cp build/bootloader/bootloader.bin "$out/"
    cp build/partition_table/partition-table.bin "$out/"
    cp build/ota_data_initial.bin "$out/" 2>/dev/null || true
    cp build/argus-zig.bin "$out/"
    echo "--- $board artifacts -> $out/"
    ls -la "$out/"
}

rm -rf release
build_board heltec_v3 "sdkconfig.defaults"
build_board tdeck     "sdkconfig.defaults;sdkconfig.defaults.tdeck"

echo ""
echo "=== All boards built. Artifacts under release/ ==="
