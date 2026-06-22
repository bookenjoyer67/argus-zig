# AGENTS.md — Argus Surveillance Tracker Scanner

## Project

Passive BLE/WiFi surveillance detection for Heltec WiFi LoRa 32 V3 (ESP32-S3).
Zig application logic compiled to static library, linked into ESP-IDF project.
Zero external parts for basic operation. AGPLv3.

## Build

```bash
cd ~/argus-zig
./build-zig.sh                    # Zig → zig-out/libargus.a  (2s)
source ~/esp/esp-idf/export.sh    # ESP-IDF env
idf.py set-target esp32s3         # Once — generates sdkconfig
python3 tools/patch-sdkconfig.py  # Inject NimBLE configs (Kconfig choice workaround)
idf.py build                      # ESP-IDF → build/argus-zig.bin  (5s cached)
idf.py -p /dev/ttyUSB0 flash monitor  # Flash and monitor
```

The build is two-stage by design:
1. `build-zig.sh` compiles Zig to a static library using the Espressif fork
2. `idf.py build` compiles ESP-IDF components and links the Zig library

**Never** skip step 1 before step 2 — idf.py does not trigger the Zig build.

**sdkconfig note:** `CONFIG_BT_NIMBLE_ENABLED` cannot be set via `sdkconfig.defaults` due to
ESP-IDF v5.4 Kconfig choice dependency resolution. `tools/patch-sdkconfig.py` injects
the required BT/NimBLE configs directly. Run it after `idf.py set-target` and whenever
sdkconfig is regenerated.

## Toolchain

- **Zig fork**: `~/zig-xtensa/zig` (zig-espressif-bootstrap 0.16.0-xtensa)
- **ESP-IDF**: `~/esp/esp-idf` (v5.4)
- **Zig env var**: `ZIG=~/zig-xtensa/zig` in build-zig.sh
- **IDF env**: `source ~/esp/esp-idf/export.sh` before idf.py

The upstream Zig at `~/.local/bin/zig` (0.16.0) does NOT have Xtensa support.
Always use the fork.

## Architecture

```
main/main.c (C)          ← ESP-IDF app_main entry point
    │                       NVS init, then calls zig_main()
    ▼
src/main.zig (Zig)       ← All application logic
    │                       GPIO, buzzer, display, OUI matching, tracker table
    │
    ├── extern fn         ← C functions resolved by GNU ld at link time
    │   gpio_set_direction, gpio_set_level, vTaskDelay, etc.
    │   No @cImport — avoids ESP-IDF header translation problems.
    │
    ├── KNOWN_OUIS        ← @embedFile("ouis.txt") + comptime parsing
    │   [64][3]u8 array, KNOWN_OUIS_COUNT for actual count
    │
    ├── Tracker table     ← Fixed [MAX_TRACKERS] array, no heap
    │
    └── SSD1306 driver    ← Pure Zig, 200 lines, saves 500KB vs U8g2
        Framebuffer: 1024 bytes. I2C driver pending.
```

## Key design decisions

**Why extern fn instead of @cImport:**
ESP-IDF v5.4 headers are deeply nested. @cImport pulls in 50+ transitive includes
(freertos/FreeRTOS.h → FreeRTOSConfig.h → sdkconfig.h → assert.h → ...).
Each one breaks on a different missing path. extern fn avoids this entirely —
declare only the functions you use, linker resolves them.

**Why ReleaseSafe not ReleaseSmall:**
ReleaseSmall inlines functions but leaves dangling symbol references in the .a
file that GNU ld cannot resolve (e.g., `U main.ledOn` in nm output).
ReleaseSafe keeps function boundaries intact. Cost: ~20KB larger.

**Why pure-Zig SSD1306 instead of U8g2:**
U8g2 is 500KB compiled. The pure-Zig driver is ~2KB. We only need 5x7 text
on a 128x64 monochrome display — U8g2 is massive overkill.

**Why comptime OUI parsing:**
@embedFile + comptime loop bakes the OUI database into the binary at compile
time. No SPIFFS access, no runtime parsing, no malloc. Editing ouis.txt and
rebuilding is sufficient — no code generation step needed.

## Pin map (Heltec V3)

| GPIO | Function | Notes |
|------|----------|-------|
| 35 | LED | Onboard white, active HIGH |
| 3 | Buzzer | Piezo, J3 pin 14 |
| 0 | Button | PRG, active LOW, pullup needed |
| 17 | OLED SDA | Internal I2C, not on headers |
| 18 | OLED SCL | Internal I2C, not on headers |
| 21 | OLED RST | J2 pin 16 |
| 1 | Battery ADC | 390k/100k divider |
| 36 | Vext control | Active LOW, P-channel MOSFET |

**Free for future:** GPIO 2,4,5,6,7 (J3), GPIO 47,48 (J2)
**Do not use:** GPIO 33,34,37,38 (SPI flash), 26 (SubSPI), 45,46 (strapping),
  8-14 (LoRa SX1262), 43,44 (UART0)

## Zig 0.16 quirks

- `callconv(.c)` not `.C` — lowercase in 0.16
- `@as(u3, @truncate(x))` required for shift amounts — u8 no longer coerces
- `asm volatile ("")` not `asm volatile ("" ::: "memory")`
- `std.fmt.bufPrint` replaces `bufPrintIntToSlice`
- `b.createModule` + `b.addLibrary` (not `addStaticLibrary`)
- `b.graph.environ_map.get("KEY")` for env vars in build.zig
- Comptime blocks cannot return slices to comptime memory in globals —
  use fixed-size arrays with sentinel values and separate count constant

## What to do

- Add features in `src/main.zig` — all application logic lives here
- Add C functions as `extern fn` declarations at the top
- Add OUI entries to `src/ouis.txt` — format: `XX:XX:XX` one per line
- After Zig changes: `./build-zig.sh && idf.py build`
- After sdkconfig changes: `idf.py set-target esp32s3` then `idf.py build`

## What NOT to do

- Do NOT use @cImport for ESP-IDF headers (will break on transitive includes)
- Do NOT use ReleaseSmall optimization (breaks GNU ld linking)
- Do NOT add malloc/free in Zig (use FixedBufferAllocator or static arrays)
- Do NOT change pin definitions without updating the pin map doc in main.zig
- Do NOT add dependencies to main/CMakeLists.txt REQUIRES without testing
- Do NOT run idf.py before build-zig.sh (linker will fail on missing libargus.a)
- Do NOT use upstream Zig (no Xtensa target)
- Do NOT delete zig-cache/ during a build (breaks incremental compilation)

## Known issues

1. **I2C/OLED not yet connected.** oledUpdate() is a placeholder. The display
   buffer is drawn in memory but not sent to the physical SSD1306. To complete:
   add extern fn for i2c_master_write(), send SSD1306 init sequence, then
   send oled_buf in 8 pages.

2. **Buzzer uses blocking busy-wait.** Fine for 50-200ms alert chirps.
   For longer tones, switch to ESP-IDF LEDC PWM. Add `extern fn` for
   ledc_timer_config and ledc_set_duty.

3. **No BLE/WiFi scanning yet.** NimBLE extern fns and WiFi promiscuous
   callback are the next features to add. The architecture supports them —
   add extern fns, create FreeRTOS tasks (from C side or Zig extern),
   push detections into the tracker table.

4. **LoRa not used.** The SX1262 is idle. Future: LoRa mesh for multi-unit
   coordination. Pins 8-14 are reserved but not configured.

5. **No GPS.** NEO-6M can be added via Vext (GPIO 36) and UART. Add extern fn
   for uart driver, parse NMEA sentences in Zig.

## File listing

```
argus-zig/
├── AGENTS.md              ← this file
├── README.md              Public project overview
├── BUILD.md               Toolchain setup and build instructions
├── CMakeLists.txt          ESP-IDF project root (commented)
├── build-zig.sh            Zig build script (commented)
├── main/
│   ├── CMakeLists.txt       ESP-IDF component (commented)
│   └── main.c               C entry point (commented)
├── src/
│   ├── main.zig             All application logic (heavily commented)
│   ├── ouis.txt             MAC OUI database (31 Flock Safety prefixes)
│   └── build.zig            Alternative zig build (reference only)
├── zig-out/
│   └── libargus.a           Built static library (77 KB)
└── build/                   ESP-IDF build artifacts (gitignored)
```
