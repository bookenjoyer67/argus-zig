#!/bin/bash
# ================================================================
# Build Zig static library for ESP32-S3
# ================================================================
#
# This script compiles src/main.zig into zig-out/libargus.a
# using the Espressif Zig fork (zig-espressif-bootstrap 0.16.0).
#
# The resulting static library is linked into an ESP-IDF project
# by CMakeLists.txt. No C headers are needed — all C functions
# are declared as extern in main.zig and resolved by GNU ld.
#
# Prerequisites:
#   - Espressif Zig fork at ~/zig-xtensa/zig
#   - Or set ZIG=/path/to/zig-xtensa/zig
#
# Output:
#   zig-out/libargus.a   — static library, ~77 KB
#   zig-cache/           — build cache (safe to delete)
#
# Optimization:
#   ReleaseSafe is used instead of ReleaseSmall because
#   ReleaseSmall inlines functions but leaves dangling symbol
#   references in the .a file that GNU ld cannot resolve.
#   ReleaseSafe keeps function boundaries intact.
#
# Usage:
#   ./build-zig.sh                     # default
#   ZIG=~/custom-zig/zig ./build-zig.sh  # custom zig path

set -e

ZIG="${ZIG:-$HOME/zig-xtensa/zig}"

echo "=== Building Zig static library for ESP32-S3 ==="

# Build from src/ directory so @embedFile("ouis.txt") resolves
cd ~/argus-zig/src
mkdir -p ../zig-out

$ZIG build-lib \
    -OReleaseSafe \
    -target xtensa-freestanding-none \
    -mcpu esp32s3 \
    -static \
    main.zig \
    --name argus \
    --cache-dir ../zig-cache \
    --global-cache-dir "$HOME/.cache/zig" \
    --zig-lib-dir "$HOME/zig-xtensa/lib" \
    -femit-bin=../zig-out/libargus.a

echo "=== Done ==="
ls -la ../zig-out/libargus.a
