# Build Guide — Argus on Heltec V3

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

## 4. Build the Zig static library

```bash
./build-zig.sh
```

This runs `zig build-lib` targeting `xtensa-freestanding-none -mcpu esp32s3`
with ReleaseSafe optimization. Output: `zig-out/libargus.a` (~77 KB).

If this fails with "symbol not found" errors, the Zig fork isn't on PATH
or the esp32s3 target isn't available. Run `~/zig-xtensa/zig targets | grep esp32s3`
to verify.

## 5. Configure ESP-IDF target

```bash
source ~/esp/esp-idf/export.sh
idf.py set-target esp32s3
```

This generates `sdkconfig` and `build/config/sdkconfig.h`. Only needed once.

If CMake fails with "component not found," check that `main/CMakeLists.txt`
lists the correct REQUIRES components for your ESP-IDF version.

## 6. Build the firmware

```bash
idf.py build
```

This compiles ESP-IDF components (FreeRTOS, NimBLE, WiFi, SPIFFS, etc.) and
links them with `zig-out/libargus.a`. Output: `build/argus-zig.bin` (~228 KB).

Expected output:
```
[100%] Linking CXX executable argus-zig.elf
argus-zig.bin binary size 0x37d60 bytes
Smallest app partition is 0x100000 bytes. 0xc82a0 bytes (78%) free.
```

## 7. Flash to the Heltec V3

```bash
# Plug in USB-C, find the port
ls /dev/ttyUSB* /dev/ttyACM*

# Flash (adjust port as needed)
idf.py -p /dev/ttyUSB0 flash

# Monitor serial output
idf.py -p /dev/ttyUSB0 monitor
```

You should see:
```
Argus Zig — booting
```

The onboard LED blinks twice, a startup chirp plays on the buzzer,
and the main loop starts (LED heartbeat every 3 seconds).

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
The device runs headless — buzzer + LED only.

### Without buzzer (save GPIO 3)

Set `PIN_BUZZER` to an unused pin or remove buzzer code entirely.
LED still provides visual alerts.

## Development workflow

```
1. Edit src/main.zig
2. ./build-zig.sh              # ~2 seconds
3. idf.py build                # ~5 seconds (cached)
4. idf.py -p /dev/ttyUSB0 flash monitor   # ~8 seconds
```

Full cycle: ~15 seconds. Most of that is flashing and bootloader handshake.
