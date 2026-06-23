# Build Guide — Argus (Heltec V3 + Lilygo T-Deck)

> **Just want to flash a device?** You don't need any of this. Open the
> **[web flasher](https://bookenjoyer67.github.io/argus-zig/web/flash.html)**
> in desktop Chrome/Edge, pick your board, plug in over USB-C, click Install.
> The guide below is for building from source.

## Prerequisites

- x86_64 Linux (tested on CachyOS/Arch)
- USB-C cable with data lines
- ~2 GB free disk space (ESP-IDF + toolchains)

## 1. Install the Espressif Zig fork

Upstream Zig lacks the Xtensa backend. The fork adds `esp32s3` CPU support.

```bash
# Download prebuilt binary
curl -L -o /tmp/zig-xtensa.tar.xz \
  "https://github.com/kassane/zig-espressif-bootstrap/releases/download/0.16.0-xtensa/zig-relsafe-x86_64-linux-musl-baseline.tar.xz"

# Extract to home directory
cd ~
tar -xJf /tmp/zig-xtensa.tar.xz
mv zig-relsafe-x86_64-linux-musl-baseline zig-xtensa

# Verify it has esp32s3 target
~/zig-xtensa/zig version   # → 0.16.0
```

The fork lives at `~/zig-xtensa/`. Your system Zig (0.16.0 upstream) is
untouched at `~/.local/bin/zig`.

## 2. Install ESP-IDF v5.4

```bash
mkdir -p ~/esp
cd ~/esp
git clone --depth 1 --branch v5.4 --recursive \
  https://github.com/espressif/esp-idf.git

# Install Python tools for esp32s3
cd esp-idf
./install.sh esp32s3
```

This downloads the Xtensa GCC toolchain, OpenOCD, esptool.py, and Python
dependencies into `~/.espressif/`.

## 3. Clone or create the project

```bash
cd ~/argus-zig
```

## Board selection

Argus supports two boards. The board is chosen at build time with the `BOARD`
environment variable (default `heltec_v3`):

| Board | `BOARD` | sdkconfig defaults |
|-------|---------|--------------------|
| Heltec WiFi LoRa 32 V3 | `heltec_v3` (default) | `sdkconfig.defaults` |
| Lilygo T-Deck | `tdeck` | `sdkconfig.defaults` + `sdkconfig.defaults.tdeck` (PSRAM / 16 MB / USB-JTAG console / 16 KB main stack) |

`build-zig.sh` reads `BOARD`, generates a small `src/board.zig` shim that forwards
the selected `src/boards/<board>.zig`, and builds the Zig static library. The C
side gets `-DBOARD_TDECK` via `idf.py -DBOARD=tdeck`.

The steps below default to the Heltec; the T-Deck variant is shown inline. To
build **both** boards into `release/<board>/` in one go (after sourcing ESP-IDF):

```bash
tools/build-all.sh
```

## 4. Build the Zig static library

```bash
./build-zig.sh                  # Heltec V3 (default)
BOARD=tdeck ./build-zig.sh      # Lilygo T-Deck
```

This runs `zig build-lib` targeting `xtensa-freestanding-none -mcpu esp32s3`
with ReleaseSafe optimization. Output: `zig-out/libargus.a` (~77 KB).

If this fails with "symbol not found" errors, the Zig fork isn't on PATH
or the esp32s3 target isn't available. Run `~/zig-xtensa/zig targets | grep esp32s3`
to verify.

## 5. Configure ESP-IDF target

```bash
source ~/esp/esp-idf/export.sh

# Heltec V3 (default sdkconfig.defaults)
idf.py set-target esp32s3

# Lilygo T-Deck (layer the T-Deck overrides + define BOARD_TDECK)
idf.py -DBOARD=tdeck -DSDKCONFIG_DEFAULTS="sdkconfig.defaults;sdkconfig.defaults.tdeck" set-target esp32s3
```

After `set-target`, run the NimBLE/partition patch (and, on a board switch,
`rm -f sdkconfig` + `idf.py fullclean` first so the previous board's config
doesn't leak in):

```bash
python tools/patch-sdkconfig.py
```

This generates `sdkconfig` and `build/config/sdkconfig.h`.

If CMake fails with "component not found," check that `main/CMakeLists.txt`
lists the correct REQUIRES components for your ESP-IDF version.

## 6. Build the firmware

```bash
idf.py build                                                                   # Heltec
idf.py -DBOARD=tdeck -DSDKCONFIG_DEFAULTS="sdkconfig.defaults;sdkconfig.defaults.tdeck" build  # T-Deck
```

This compiles ESP-IDF components (FreeRTOS, NimBLE, WiFi, displays, etc.) and
links them with `zig-out/libargus.a`. Output: `build/argus-zig.bin` (~1.4 MB
with the full detection + UI stack).

## 7. Flash

**Heltec V3** — a CP2102 USB-UART that auto-resets, on `/dev/ttyUSB0`:

```bash
ls /dev/ttyUSB* /dev/ttyACM*
idf.py -p /dev/ttyUSB0 flash
idf.py -p /dev/ttyUSB0 monitor      # console on UART0
```

**Lilygo T-Deck** — native USB on `/dev/ttyACM0`. It often won't auto-enter the
bootloader, so force **download mode**: hold the trackball center-click, tap
**RESET**, release — then flash. Tap **RESET** again after flashing to boot.
(Console is USB-Serial-JTAG over the same port.)

```bash
idf.py -p /dev/ttyACM0 -DBOARD=tdeck -DSDKCONFIG_DEFAULTS="sdkconfig.defaults;sdkconfig.defaults.tdeck" flash
```

On boot you should see `Argus Zig — booting`, then the boot logo. On the Heltec
the white LED blinks the threat-level pattern; the T-Deck plays a startup chime.

## Rebuild after Zig changes

```bash
./build-zig.sh          # Rebuild libargus.a
idf.py build            # Relink and flash
idf.py -p /dev/ttyUSB0 flash
```

The ESP-IDF components are cached — only changed code recompiles.

## Troubleshooting

### "Zig: command not found" or "esp32s3 target not available"

The system Zig (upstream) doesn't have Xtensa. Make sure `build-zig.sh`
points to the fork:

```bash
ZIG=~/zig-xtensa/zig ./build-zig.sh
```

### "ld: undefined reference to main.ledOn"

Zig's ReleaseSmall inlines functions but leaves dangling symbol references.
Use ReleaseSafe (default in build-zig.sh). If you need ReleaseSmall,
declare affected functions as `inline` explicitly.

### "sdkconfig.h not found"

Run `idf.py set-target esp32s3` first. This generates the sdkconfig.

### "Failed to resolve component 'nimble'"

NimBLE is part of `bt` component in ESP-IDF v5.x. Use `bt` in REQUIRES,
not `nimble`. If you see `esp_nimble` errors, check ESP-IDF version.

### "partition table invalid" or "app partition too small"

The default partition table has a 1MB factory partition.
Our binary is ~228KB. If you add features and exceed 1MB,
create a custom `partitions.csv` with a larger app partition.

## Build variants

### Debug build (larger, includes panic traces)

Edit `build-zig.sh`:
```bash
-OReleaseSafe  →  -ODebug
```

### Minimum size build (experimental, may have symbol issues)

```bash
-OReleaseSafe  →  -OReleaseSmall
```

Note: ReleaseSmall currently produces incomplete symbol tables for GNU ld.
Use only when linking with Zig's lld (not yet configured for ESP-IDF).

### Without OLED (save ~10KB)

Comment out the display section in main.zig and remove oled_buf allocation.
The device runs headless — LED only (no buzzer is fitted; GPIO 3 is free).

## Development workflow

```
1. Edit src/main.zig
2. ./build-zig.sh              # ~2 seconds
3. idf.py build                # ~5 seconds (cached)
4. idf.py -p /dev/ttyUSB0 flash monitor   # ~8 seconds
```

Full cycle: ~15 seconds. Most of that is flashing and bootloader handshake.

## Cutting a release (prebuilt firmware + web flasher)

End users flash from a browser, so each release ships a **per-board merged
image**. One command builds both boards and publishes them:

```bash
tools/release.sh v1.2.0        # build both boards + merge-bin + gh release create
```

For each board it runs `BOARD=<b> ./build-zig.sh`, a clean per-board
`set-target` + `idf.py build`, and `idf.py merge-bin -o argus-<board>-merged.bin`,
then `gh release create <tag>` uploading both merged images (Heltec V3 + T-Deck)
plus the Heltec app image for OTA. Publishing triggers the GitHub Pages workflow
(`.github/workflows/pages.yml`), which downloads each merged image into
`web/firmware/<board>/` and redeploys, so `web/flash.html` (esp-web-tools) serves
them same-origin behind a board picker. Each board's manifest
(`web/firmware/<board>/manifest.json`) points at its merged image at offset 0.
