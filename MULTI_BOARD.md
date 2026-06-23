# Multi-Board Support — Implementation Plan

Add support for ESP32 boards beyond the Heltec V3. First target: Lilygo T-Deck.
Architecture introduces a hardware abstraction layer so the detection engine
runs unchanged across boards. Only display, input, and audio backends differ.

**Status:** Plan. Not yet implemented.

---

## Why the T-Deck

| Feature | Heltec V3 | T-Deck |
|---------|-----------|--------|
| Display | 128×64 OLED (I2C, SSD1306) | 320×240 TFT (SPI, ST7789) |
| Input | 1 button (GPIO) | 55-key QWERTY keyboard (I2C) + trackball |
| Audio | Piezo buzzer (GPIO) | I2S speaker (MAX98357) |
| LoRa | SX1262 (SPI, GPIO 8-14) | SX1262 (SPI, diff pins) |
| Storage | SPIFFS (1MB) | microSD (FAT, gigabytes) |
| Battery | JST 1.25mm, 2000mAh | JST 2.0mm, 2000mAh |
| Enclosure | None (bare PCB) | Injection-molded case, belt clip |
| Price | $15 | $55 |

Same ESP32-S3. Same SX1262. Same Zig toolchain. Same detection engine.
Only the peripherals differ.

---

## Architecture

### Current codebase (as of June 22, 2026)

```
main/main.c     364L   ← app_main, OLED I2C driver, GPIO wrappers, LEDC PWM, ADC
main/ble.c      504L   ← NimBLE scanning + ring buffer + NUS GATT peripheral
main/wifi.c     285L   ← WiFi promiscuous sniffer + ring buffer + channel hop
main/lora.c     404L   ← SX1262 driver (full opcodes)
main/spiffs.c   146L   ← SPIFFS mount, CSV append/export
main/gps.c       57L   ← NEO-6M UART driver
main/httpd.c    276L   ← HTTP server, setup + dashboard routes
main/config.c   131L   ← SPIFFS JSON config read/write
main/ota.c      153L   ← OTA update handler

src/main.zig   1022L   ← Entry, main loop, extern fns, OUI_DB (vendor + category)
src/scanner.zig 798L   ← Classifiers, scoring, NMEA, CSV, Stingray burst detector
src/display.zig 804L   ← SSD1306 driver, 8-page UI (inc. All Devices), LED alerts
src/mesh.zig    376L   ← LoRa mesh: CRC-8, heartbeats, dedup, camera map, peer table
src/api.zig     244L   ← Dashboard JSON API: status, detections, mesh, config, cameras
src/config.zig   30L   ← Device config struct

src/ouis.txt    126L   ← OUI prefixes + vendor/category section headers
web/dashboard.html 446L ← Dashboard HTML/CSS/JS
web/setup.html   102L   ← Onboarding page
```

### Target architecture

```
src/main.zig        ← main loop, uses Board interface
src/scanner.zig     ← untouched (798L, board-agnostic)
src/mesh.zig        ← untouched (376L, board-agnostic)
src/api.zig         ← untouched (244L)

src/hal/
├── display.zig     ← shared drawing primitives (font table, drawStr, drawBar)
├── ssd1306.zig     ← SSD1306 I2C driver (extracted from display.zig)
├── st7789.zig      ← ST7789 SPI driver (new for T-Deck)
├── input.zig       ← common input trait
├── keyboard.zig    ← T-Deck I2C keyboard reader (new)
├── button.zig      ← GPIO button (extracted from main.zig)
├── audio.zig       ← common audio trait
├── speaker.zig     ← I2S speaker driver (new)
└── buzzer.zig      ← piezo buzzer (extracted from main.zig)

src/boards/
├── board.zig       ← common traits: Display, Input, Audio, Storage
├── heltec_v3.zig   ← SSD1306 128×64, GPIO button, piezo buzzer, SPIFFS
└── tdeck.zig       ← ST7789 320×240, I2C keyboard, I2S speaker, microSD
```

### Board selection

A `BOARD` env var selects the target at build time:

```bash
./build-zig.sh                  # Heltec V3 (default)
BOARD=tdeck ./build-zig.sh      # T-Deck
```

**How it actually wires up.** The active build is `build-zig.sh` invoking
`zig build-lib -OReleaseSafe` directly (NOT `zig build`), so the `zig build`
style `-Dboard=...` option is *not* available. Board selection is done by
mapping the chosen board file to a named Zig module on the CLI:

```bash
BOARD="${BOARD:-heltec_v3}"
$ZIG build-lib ... \
    --dep board \
    -Mroot=main.zig \
    -Mboard=boards/$BOARD.zig
```

`src/main.zig` then does `const board = @import("board");` and the linker/comptime
picks up the right file. (Note: `src/build.zig` exists but is **stale and unused** —
it sets `.ReleaseSmall` and uses `@cImport` include paths, both forbidden by
AGENTS.md — so do NOT wire board selection there.)

**C side.** `main/*.c` files that branch on board (e.g. `lora.c`) need the macro
actually defined. Pass it through CMake / idf.py as a compile definition, e.g.
`idf.py -DBOARD=tdeck build` mapped to `-DBOARD_TDECK` in `main/CMakeLists.txt`.
The Zig module map alone does not reach the C compiler.

Each board file exports: `PIN_LED`, `initDisplay()`, `readInput()`, `playTone()`, `initStorage()`.

---

## Abstraction traits

### Display

```zig
pub const Display = struct {
    width: u16,
    height: u16,
    clear: *const fn () void,
    update: *const fn () void,
    drawPixel: *const fn (x: u16, y: u16, on: bool) void,
};
```

Heltec: SSD1306 I2C, 128×64, 1-bit framebuffer in RAM (1024 bytes).
T-Deck: ST7789 SPI, 320×240, 16-bit color. A full framebuffer is 320×240×2 =
~150KB. The ESP32-S3 has 512KB SRAM, but the T-Deck also carries **8MB PSRAM**,
so the **recommended** approach is a full framebuffer allocated in PSRAM (via
`heap_caps_malloc(..., MALLOC_CAP_SPIRAM)`) and flushed over SPI/DMA — no scaling
hacks needed. Fallback options if PSRAM is avoided: draw directly via SPI
per-primitive, or use a 160×120 SRAM framebuffer with 2× integer scaling.

### Input

```zig
pub const InputEvent = union(enum) {
    key: u8,           // keyboard key (ASCII)
    button_press,
    button_hold: u32,  // ms held
    trackball_up, trackball_down, trackball_left, trackball_right,
    trackball_click,
    none,
};
```

Heltec: polls GPIO 0.
T-Deck: reads keys over I2C from the onboard ESP32-C3 keyboard (bus SDA=18,
SCL=8; key INT=46) and samples the four trackball GPIOs (G01=3, G02=2, G03=15,
G04=1) plus the center-click line.

### Audio

```zig
pub const Audio = struct {
    playTone: *const fn (freq_hz: u16, dur_ms: u16) void,
    stop: *const fn () void,
};
```

Heltec: GPIO 3 piezo via blocking busy-wait toggle.
T-Deck: I2S MAX98357 via DMA. PCM samples from flash. Non-blocking.

### Storage

```zig
pub const Storage = struct {
    append: *const fn (path: [*:0]const u8, line: [*:0]const u8) i32,
    read: *const fn (path: [*:0]const u8, buf: [*]u8, max: u32) i32,
    export_csv: *const fn () void,
};
```

Heltec: SPIFFS, ~1MB, same functions as current `spiffs_*`.
T-Deck: microSD, FAT via ESP-IDF `fatfs`. Same function signatures.

---

## T-Deck specifics

All pin numbers below are taken from the official Lilygo
[`examples/UnitTest/utilities.h`](https://github.com/Xinyuan-LilyGO/T-Deck/blob/master/examples/UnitTest/utilities.h).

### Prerequisite: peripheral power gate

- **`BOARD_POWERON = GPIO10` must be driven HIGH before using any peripheral.**
  The TFT, LoRa radio, and microSD are behind this power gate — skip it and the
  whole SPI bus appears dead. Set it first in board init.

### Shared SPI bus

- One SPI bus is shared by TFT + microSD + LoRa: **MOSI=41, MISO=38, SCK=40**.
  Each peripheral has its own CS. Bus must be set up once and shared.

### Display: ST7789 over SPI

- CS=GPIO12, DC=GPIO11, backlight (BL)=GPIO42 (no dedicated RST — soft reset in
  the init sequence). Uses the shared SPI bus above.
- Recommended: full framebuffer in PSRAM (see Display trait). Fallback: draw
  direct, or 160×120 + 2× scale using the existing 5×7 glyph table.
- Single dashboard layout replaces the 8-page cycle.
- NOTE: the I2C bus (SDA=18, SCL=8) must NOT be confused with TFT pins — earlier
  drafts of this doc collided DC/RST with the I2C lines.

### Input: I2C keyboard + GPIO trackball

- Keyboard is a **separate onboard ESP32-C3** running its own firmware, exposed
  as an I2C slave on **SDA=GPIO18, SCL=GPIO8** (keyboard INT=GPIO46). Read keys
  via I2C; do not bit-bang a matrix.
- Trackball is **4 plain GPIOs** (not an I2C encoder):
  G01=GPIO3, G02=GPIO2, G03=GPIO15, G04=GPIO1, plus a center-click line.
- Touch panel INT=GPIO16 (capacitive controller on the same I2C bus) — optional.

### Audio: I2S speaker

- MAX98357: **WS/LRCLK=GPIO5, BCK=GPIO7, DOUT=GPIO6**.
- PCM samples: 8-bit unsigned, 8kHz, stored in flash.
- Tones: startup chime, alert patterns, Geiger clicks (~16KB total).
- (The board also has an ES7210 mic ADC: MCLK=48, LRCK=21, SCK=47, DIN=14 —
  not needed for Argus, listed for completeness.)

### LoRa: SX1262 on different SPI pins

- Same chip as Heltec, on the shared SPI bus. Pins:
  **CS/NSS=9, SCK=40, MOSI=41, MISO=38, BUSY=13, RST=17, DIO1=45**.
  (For reference, Heltec V3 is NSS=8, SCK=9, MOSI=10, MISO=11, RST=12, BUSY=13,
  DIO1=14 — matching the `#define`s in `main/lora.c`.)
- `main/lora.c` uses `#define` for all pins — wrap them in `#ifdef BOARD_TDECK`.

### Storage: microSD

- **CS=GPIO39**, shares MOSI/MISO/SCK (41/38/40) with TFT and LoRa.
- FAT filesystem (ESP-IDF `fatfs`), `/sdcard/detections.csv`.
- Same `spiffs_append_line()` API, different backend.

### Battery

- ADC on **GPIO4** (`BOARD_BAT_ADC`).

---

## T-Deck display layout

The 8-page Heltec OLED UI becomes a single color dashboard:

```
┌──────────────────────────────────────────────────────┐
│  ARGUS  ████ 4.1V                  GPS: 38.6270 GPS │
│──────────────────────────────────────────────────────│
│                                                      │
│   SURVEILLANCE                      TRACKERS         │
│   ┌──────────┬──────────┐    ┌──────────┬──────────┐│
│   │    1     │    2     │    │    8     │    1     ││
│   │   FLOCK  │  CAMERA  │    │  AIRTAG  │   TILE   ││
│   ├──────────┼──────────┤    ├──────────┼──────────┤│
│   │    0     │  1 active│    │    2     │    1     ││
│   │  DRONE   │ STINGRAY │    │ SAMSUNG  │  FINDMY  ││
│   └──────────┴──────────┘    └──────────┴──────────┘│
│                                                      │
│   Latest                          [MESH: 2 peers]    │
│   FLK 70:C9:4E  -58  CERT  2m ago                   │
│   DRN DJI Mini  -72  HIGH  5m ago                   │
│   AIR 52:C5:1F  -99  MED  12m ago                   │
│                                                      │
│  [1]Surv [2]Track [3]All [4]Log [5]Mesh [6]System   │
└──────────────────────────────────────────────────────┘
```

Keyboard 1-6 switches views. Trackball scrolls. Enter for detail.
Tab toggles stealth. Space dumps CSV.

---

## What stays unchanged

- `src/scanner.zig` — detection engine (798L, board-agnostic)
- `src/mesh.zig` — LoRa mesh: CRC-8, heartbeats, dedup, camera map (376L)
- `src/api.zig` — dashboard API (244L)
- `main/ble.c` — NimBLE scanning
- `main/wifi.c` — WiFi promiscuous sniffer
- `main/lora.c` — SX1262 driver (pin mapping only changes via `#ifdef`)
- `main/spiffs.c` — storage backend (same API, different impl for T-Deck)

## What changes

- `src/main.zig` — main loop uses Board interface instead of hardcoded GPIO
- `src/display.zig` — split: drawing primitives stay, SSD1306 driver extracted, page layout becomes board-aware
- Pin definitions — move to `src/boards/heltec_v3.zig`
- Build scripts — `BOARD` env var
- `main/lora.c` — `#ifdef` for T-Deck pin mapping

---

## Implementation order

### Phase 1: Refactor Heltec into abstraction (6–8 hours)
This is the largest and riskiest phase. `src/display.zig` is 804L with a
hardcoded `PIN_LED` (line 7) and an 8-page UI tightly bound to the 128×64
SSD1306 page-addressing model; cleanly separating drawing primitives from the
driver from the (now board-aware) page layout is non-trivial. Budget accordingly.
1. Create `src/hal/` with ssd1306.zig, button.zig, buzzer.zig — extracted from current files
2. Create `src/boards/board.zig` — trait definitions
3. Create `src/boards/heltec_v3.zig` — wires existing drivers
4. Rewire `src/main.zig` to use board interface
5. Verify Heltec V3 builds identically to before

### Phase 2: T-Deck display (4 hours)
6. Write ST7789 driver (`src/hal/st7789.zig`)
7. Font rendering at 2× scale
8. Single-page dashboard layout
9. Color palette

### Phase 3: T-Deck input, audio, storage (4 hours)
10. I2C keyboard reader + trackball
11. Keyboard-to-action mapping
12. I2S speaker driver with PCM samples
13. microSD storage adapter

### Phase 4: T-Deck LoRa + build system (2 hours)
14. `#ifdef BOARD_TDECK` in lora.c
15. Build system: `BOARD=tdeck` (Zig module map + C `-DBOARD_TDECK` via CMake)
16. Flash and test

### Total: ~16–18 hours

---

## What you get

One codebase, two board targets. Same detection engine, same mesh protocol.
Heltec for pocket carry. T-Deck for belt carry — full keyboard, color dashboard.
Both mesh together over LoRa. The T-Deck form factor turns Argus from a dev
board into a product you'd actually carry every day.

---

## Web Flasher Integration

Multi-board support changes the web flasher flow. A user with a T-Deck needs
different .bin files than a user with a Heltec V3. The flasher must know which
board is plugged in.

### Release structure

Each GitHub Release contains per-board subdirectories:

```
v1.0.0/
├── heltec-v3/
│   ├── bootloader.bin
│   ├── partition-table.bin
│   └── argus-zig.bin
├── tdeck/
│   ├── bootloader.bin
│   ├── partition-table.bin
│   └── argus-zig.bin
```

The `build-zig.sh` script builds for one board at a time (set via `BOARD` env var).
A release script builds all boards sequentially and collects artifacts:

```bash
#!/bin/bash
# build-all.sh — build all supported boards for a release

BOARD=heltec_v3 ./build-zig.sh
idf.py build
cp build/bootloader/bootloader.bin release/heltec-v3/
cp build/partition_table/partition-table.bin release/heltec-v3/
cp build/argus-zig.bin release/heltec-v3/

idf.py fullclean

BOARD=tdeck ./build-zig.sh
idf.py build
cp build/bootloader/bootloader.bin release/tdeck/
cp build/partition_table/partition-table.bin release/tdeck/
cp build/argus-zig.bin release/tdeck/
```

### Flasher UI flow

```
Open flasher page
     │
     ▼
┌─────────────────────────────┐
│ Select your board:          │
│ ┌─────────────────────────┐ │
│ │ Heltec WiFi LoRa 32 V3 ▼│ │
│ │ Lilygo T-Deck            │ │
│ └─────────────────────────┘ │
│                             │
│ [Connect Device]            │
│ [Flash Firmware] (disabled) │
└─────────────────────────────┘
     │ user picks board + clicks Connect
     ▼
  WebSerial picker → user selects CP2102 (or T-Deck's USB-UART)
     │
     ▼
  esptool-js auto-detects chip (ESP32-S3)
     │
     ▼
  Flash button enabled
     │ user clicks Flash
     ▼
  Fetches .bin files from:
    https://github.com/bookenjoyer67/argus-zig/releases/download/v1.0.0/{board}/
     │
     ▼
  Progress bar → "Done — device rebooting"
```

### Why this matters

Without this, the flasher can only flash Heltec firmware. A T-Deck user
would get a Heltec build that can't drive the ST7789 display, can't read
the keyboard, and crashes on the wrong LoRa pins.

With the board picker, the same flasher page works for every supported board.
Someone buying a T-Deck gets the same one-click experience as someone buying
a Heltec.

### Board detection (nice-to-have)

esptool-js can read the ESP32's MAC address and flash size, but it can't
tell which board it's on — the chip is the same ESP32-S3 regardless. The
board picker dropdown is the reliable approach.

A future enhancement: the flasher could read the eFuse MAC and suggest a
board based on known MAC ranges (Lilygo vs Heltec use different MAC pools),
but this is fragile and not worth the complexity for v1.
