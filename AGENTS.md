# AGENTS.md — Argus Surveillance Tracker Scanner

## Project

Passive BLE/WiFi surveillance detection for Heltec WiFi LoRa 32 V3 (ESP32-S3).
Zig + ESP-IDF. Zero external parts for basic operation. AGPLv3.

**Status:** Detection engine feature-complete. Raven, ALPR, drone Remote ID,
consumer cameras, Amazon Sidewalk, and tracker classification all working.
Hardware-tested. UX refinements active. Web dashboard pending.

## Build

```bash
cd ~/argus-zig
./build-zig.sh                    # Zig → zig-out/libargus.a
source ~/esp/esp-idf/export.sh    # ESP-IDF env
idf.py build                      # ESP-IDF → build/argus-zig.bin
idf.py -p /dev/ttyUSB0 flash monitor
```

Two-stage: Zig compiles to static library, idf.py links it with ESP-IDF components.
Always run build-zig.sh first.

## Toolchain

- **Zig fork:** `~/zig-xtensa/zig` (zig-espressif-bootstrap 0.16.0-xtensa)
- **ESP-IDF:** `~/esp/esp-idf` (v5.4)
- Upstream Zig at `~/.local/bin/zig` does NOT have Xtensa. Use the fork.

## Architecture

```
main/main.c              ← app_main: NVS init, starts BLE/WiFi/LoRa/GPS/SPIFFS
main/ble.c               ← NimBLE passive scanning + ring buffer
main/wifi.c              ← WiFi promiscuous sniffer (802.11 parsing, Remote ID IE)
main/lora.c              ← SX1262 LoRa driver (SPI, full opcode set)
main/spiffs.c            ← SPIFFS mount, CSV append/export
main/gps.c               ← NEO-6M UART driver
main/main.c (oled/gpio)  ← I2C OLED driver + GPIO wrappers + battery ADC

src/main.zig     590L    ← Entry point, main loop, extern fns, OUI db, tracker table
src/scanner.zig  600L+   ← BLE/WiFi classifiers, scoring, NMEA parser, CSV logging,
                           BLE_SIGNATURES table, carrier probe counter, Stingray burst detector
src/display.zig  720L+   ← SSD1306 driver, 5x7 font, 7-page UI, LED alerts
src/mesh.zig      72L    ← LoRa mesh packet send/receive, CRC

src/ouis.txt      96L    ← 73 MAC OUI prefixes (@embedFile + comptime parsed)
```

## Key design decisions

**extern fn instead of @cImport** — ESP-IDF v5.4 headers are deeply nested and
break on transitive includes. Declare only the functions used; linker resolves them.

**ReleaseSafe not ReleaseSmall** — ReleaseSmall produces dangling symbol refs
GNU ld can't resolve. ReleaseSafe is ~20KB larger but links correctly.

**Pure-Zig SSD1306** — ~2KB vs 500KB for U8g2. Only need 5x7 text on 128x64.

**comptime OUI parsing** — @embedFile + comptime loop. No SPIFFS, no runtime parse.
Edit ouis.txt, rebuild, done.

**Fixed tracker table** — [MAX_TRACKERS] static array. No heap, no fragmentation.

**C modules for hardware, Zig for logic** — C handles NimBLE, WiFi stack, LoRa SPI,
I2C, SPIFFS, GPS UART, ADC. Zig handles classification, scoring, display, mesh,
CSV logging, UX. extern fn boundary is the API.

## OLED page map

0. Summary — SURV count, TRACK count, OUI db size, battery, GPS status, Stingray alert
1. Surveillance — ALPR, drone, raven, camera rows with MAC/RSSI/score
2. Proximity — big RSSI readout, trend arrow, distance word, bar. 500ms live refresh
3. History — 5-bar chart, 12-min buckets, rightmost=recent
4. Trackers — AirTag, Tile, Samsung, FindMy rows with MAC/RSSI
5. Stats — session uptime, detection totals
6. System — heap, flash, battery V, tracker table usage

Stingray alert overlays on summary page and appears as a row on page 1 when active.

## Button

| Gesture | Action |
|---------|--------|
| Short press | Next page |
| Hold 1-2s | CSV dump over serial |
| Hold 5s+ | Factory reset (clear SPIFFS + reboot) |

## Pin map (Heltec V3)

GPIO 35: LED (onboard white, active HIGH)
GPIO 3:  Buzzer (piezo, J3 pin 14)
GPIO 0:  Button (PRG, active LOW, pullup)
GPIO 17: OLED SDA (I2C, internal)
GPIO 18: OLED SCL (I2C, internal)
GPIO 21: OLED RST (J2 pin 16)
GPIO 1:  Battery ADC (390k/100k divider)
GPIO 36: Vext control (active LOW)

Free: GPIO 2,4,5,6,7 (J3), GPIO 47,48 (J2)
Reserved: GPIO 33,34,37,38 (SPI flash), 26 (SubSPI), 45,46 (strapping),
          8-14 (LoRa SX1262), 43,44 (UART0)

## Zig 0.16 quirks

- `callconv(.c)` not `.C`
- `@as(u3, @truncate(x))` for shift amounts
- `asm volatile ("")` not `asm volatile ("" ::: "memory")`
- `std.fmt.bufPrint` not `bufPrintIntToSlice`
- `b.createModule` + `b.addLibrary` in build.zig
- `b.graph.environ_map.get("KEY")` for env vars
- Comptime blocks: use fixed arrays + sentinel values + separate count const

## What to do

- Add features in `src/` — logic lives across main/display/scanner/mesh
- Add C functions as `pub extern fn` in `src/main.zig`
- Add OUIs to `src/ouis.txt` — one `XX:XX:XX` per line
- Add BLE signatures to `BLE_SIGNATURES` table in `src/scanner.zig` line ~80
- After Zig changes: `./build-zig.sh && idf.py build`

## What NOT to do

- Do NOT use @cImport for ESP-IDF headers
- Do NOT use ReleaseSmall (GNU ld symbol issues)
- Do NOT malloc/free in Zig (static arrays or FixedBufferAllocator)
- Do NOT change pins without updating this file
- Do NOT run idf.py before build-zig.sh
- Do NOT use upstream Zig (no Xtensa)

## Known issues

1. **Buzzer blocks during tone.** Fine for chirps <200ms. For longer tones,
   switch to LEDC PWM.

2. **BLE scan and WiFi promiscuous share the radio.** ESP32 coexistence
   handles this but scan intervals may shift under heavy WiFi traffic.

3. **No web dashboard yet.** Base station mode planned (see LAYERS_1_2.md).
   Currently USB serial export only.

4. **Stingray detection is probabilistic.** Indirect detection via carrier
   probe burst analysis. Cannot confirm — only flag as STINGRAY? with caveat.

5. **256-byte I2C buffer limit.** SSD1306 framebuffer is 1024 bytes sent in
   four 256-byte chunks. ESP-IDF I2C driver has a 256-byte hardware limit.

## Documentation

```
AGENTS.md          ← this file
README.md          ← public project overview
BUILD.md           ← toolchain setup + build instructions
RESOURCES.md       ← learning resources for contributors
ROADMAP.md         ← development phases and status (partially out of date)
DETECTION.md       ← detection expansion plan (research + implementation)
DETECTION_STATUS.md ← what's implemented vs pending from DETECTION.md
FIXES.md           ← walk test issues found June 21 + fixes
HARDWARE_TEST.md   ← hardware test results June 21
STINGRAY.md        ← Stingray/IMSI catcher detection plan
LAYERS_1_2.md      ← onboarding + web dashboard implementation plan
```
