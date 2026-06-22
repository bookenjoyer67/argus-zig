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
main/ble.c      128L   ← NimBLE scanning + ring buffer
main/wifi.c     285L   ← WiFi promiscuous sniffer + ring buffer
main/lora.c     404L   ← SX1262 driver (full opcodes)
main/spiffs.c   131L   ← SPIFFS mount, CSV append/export
main/gps.c       57L   ← NEO-6M UART driver
main/httpd.c    276L   ← HTTP server, setup + dashboard routes
main/config.c   131L   ← SPIFFS JSON config read/write

src/main.zig   1020L   ← Entry, main loop, extern fns, OUI_DB (vendor + category)
src/scanner.zig 768L   ← Classifiers, scoring, NMEA, CSV, Stingray burst detector
src/display.zig 804L   ← SSD1306 driver, 8-page UI (inc. All Devices), LED alerts
src/mesh.zig    376L   ← LoRa mesh: CRC-8, heartbeats, dedup, camera map, peer table
src/api.zig     242L   ← Dashboard JSON API: status, detections, mesh, config, cameras
src/config.zig   30L   ← Device config struct

src/ouis.txt     96L   ← 73 OUI prefixes with vendor name comments
web/dashboard.html 186L ← Dashboard HTML/CSS/JS
web/setup.html    80L   ← Onboarding page
```

### Target architecture

```
src/main.zig        ← main loop, uses Board interface
src/scanner.zig     ← untouched (768L, board-agnostic)
src/mesh.zig        ← untouched (376L, board-agnostic)
src/api.zig         ← untouched (242L)

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

Build-time flag:

```bash
./build-zig.sh                  # Heltec V3 (default)
BOARD=tdeck ./build-zig.sh      # T-Deck
```

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
T-Deck: ST7789 SPI, 320×240, 16-bit color. No framebuffer — 150KB doesn't fit
in 512KB SRAM. Draw directly via SPI per-primitive, or use 160×120 framebuffer
with 2× integer scaling.

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
T-Deck: reads I2C keyboard matrix (addr 0x55) + trackball quadrature.

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

### Display: ST7789 over SPI

- SPI3_HOST: DC=GPIO8, CS=GPIO9, RST=GPIO18, BL=GPIO45
- No framebuffer — draw directly
- Text at 2× scale using existing 5×7 glyph table (10×14 effective on display)
- Single dashboard layout replaces the 8-page cycle

### Input: I2C keyboard

- Controller at I2C address 0x55
- 55-key matrix read via register read
- Trackball: quadrature encoder, up/down/left/right/click

### Audio: I2S speaker

- MAX98357: BCLK=GPIO7, LRCLK=GPIO6, DOUT=GPIO5
- PCM samples: 8-bit unsigned, 8kHz, stored in flash
- Tones: startup chime, alert patterns, Geiger clicks (~16KB total)

### LoRa: SX1262 on different SPI pins

- Same chip as Heltec. Pins: NSS=10, SCK=11, MOSI=12, MISO=13, BUSY=14, RST=15, DIO1=16
- `main/lora.c` uses `#define` for all pins — add `#ifdef BOARD_TDECK`

### Storage: microSD

- SPI: CS=17, shares MOSI/MISO/SCK with display
- FAT filesystem, `/sdcard/detections.csv`
- Same `spiffs_append_line()` API, different backend

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

- `src/scanner.zig` — detection engine (768L, board-agnostic)
- `src/mesh.zig` — LoRa mesh: CRC-8, heartbeats, dedup, camera map (376L)
- `src/api.zig` — dashboard API (242L)
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

### Phase 1: Refactor Heltec into abstraction (4 hours)
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
15. Build system: `BOARD=tdeck`
16. Flash and test

### Total: ~14 hours

---

## What you get

One codebase, two board targets. Same detection engine, same mesh protocol.
Heltec for pocket carry. T-Deck for belt carry — full keyboard, color dashboard.
Both mesh together over LoRa. The T-Deck form factor turns Argus from a dev
board into a product you'd actually carry every day.
