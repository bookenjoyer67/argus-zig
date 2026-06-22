# AGENTS.md — Argus Surveillance Tracker Scanner

## Project

Passive BLE/WiFi surveillance detection for Heltec WiFi LoRa 32 V3 (ESP32-S3).
Zig + ESP-IDF. Zero external parts for basic operation. AGPLv3.

**Status:** Detection engine feature-complete. Raven, ALPR, drone Remote ID,
consumer cameras, Amazon Sidewalk, and tracker classification all working.
Hardware-tested. UX refinements active. Web dashboard (base station) working.
WiFi channel hopping (mobile) and a BLE GATT passkey-paired phone interface
(`web/ble.html`, hosted on GitHub Pages) shipped.

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
main/ble.c               ← NimBLE passive scan + ring buffer + NUS GATT peripheral
                           (passkey-paired phone stream)
main/wifi.c              ← WiFi promiscuous sniffer (802.11, Remote ID IE) + channel
                           hopping (mobile role) + AP/STA for setup & dashboard
main/lora.c              ← SX1262 LoRa driver (SPI, full opcode set)
main/spiffs.c            ← SPIFFS mount, CSV append/export
main/gps.c               ← NEO-6M UART driver
main/main.c (oled/gpio)  ← I2C OLED driver + GPIO wrappers + battery ADC + LED PWM

src/main.zig     998L    ← Entry point, main loop, extern fns, OUI_DB (vendor/category), tracker table,
                           src/main.zig    1020L    ← Entry point, main loop, extern fns, OUI_DB (vendor + category)
                           src/scanner.zig  768L    ← BLE/WiFi classifiers, scoring, NMEA parser, CSV logging,
                                                      BLE_SIGNATURES table, Stingray burst detector, OUI-only cap
                           src/display.zig  804L    ← SSD1306 driver, 5x7 font, 8-page UI (inc. All Devices), LED alerts
                           src/mesh.zig     376L    ← LoRa mesh: CRC-8, heartbeats, dedup, camera map, peer table
                           src/api.zig      242L    ← Dashboard API endpoints (/api/status, /api/detections, /api/mesh, /api/cameras)
                           src/config.zig    30L    ← Device config struct, SPIFFS load/save

                           main/httpd.c     276L    ← ESP-IDF HTTP server, setup page handler, dashboard routes
                           main/config.c    131L    ← SPIFFS JSON config read/write (C helpers)
                           main/main.c      364L    ← app_main, OLED I2C, GPIO wrappers, LEDC PWM, battery ADC
                           main/lora.c      404L    ← SX1262 LoRa driver (full opcode set)

web/dashboard.html 433L  ← Base-station dashboard (theme, map, vanilla JS polling)
web/ble.html       339L  ← BLE phone client (Web Bluetooth, hosted on GitHub Pages)
web/flash.html           ← Web flasher (esp-web-tools, hosted on GitHub Pages)
web/setup.html     102L  ← Onboarding setup page

src/ouis.txt      96L    ← surveillance OUIs + vendor/category section headers (@embedFile + comptime)
tools/release.sh         ← build + idf.py merge-bin + gh release (cuts a prebuilt firmware)
.github/workflows/pages.yml ← deploys web/* to GitHub Pages; pulls the release binary into web/firmware/
```

## Key design decisions

**extern fn instead of @cImport** — ESP-IDF v5.4 headers are deeply nested and
break on transitive includes. Declare only the functions used; linker resolves them.

**ReleaseSafe not ReleaseSmall** — ReleaseSmall produces dangling symbol refs
GNU ld can't resolve. ReleaseSafe is ~20KB larger but links correctly.

**Pure-Zig SSD1306** — ~2KB vs 500KB for U8g2. Only need 5x7 text on 128x64.

**comptime OUI parsing** — @embedFile + comptime loop builds `OUI_DB`
(prefix + vendor name + category) from ouis.txt. No SPIFFS, no runtime parse.
Edit ouis.txt, rebuild, done.

**OUI-only WiFi cap (category-aware)** — An OUI match tells you the chip, not
the device. Flock Safety is identified by its `Flock-XXXX` SSID, not its OUI:
the "Flock" OUI lists circulating online are all commodity module vendors
(Liteon/Espressif/USI/SiLabs/Samsung/Nintendo/Meraki) that appear in countless
home devices, so they are filed as `generic` and cap at 25 — tracked and logged
but silent. A `Flock-XXXX` SSID classifies as `.flock_camera` regardless of OUI.
Camera/drone-manufacturer chips rarely appear outside surveillance products, so
they cap at 50 (MEDIUM): surfaced as `.camera`/`.drone`, shown on the
surveillance page with an LED pulse and broadcast over the LoRa mesh (no buzzer
is fitted). Category comes from the ouis.txt section the OUI sits under — keyword
`commodity` → generic, `camera`/`surveillance` → camera, `drone`/`remote id` →
drone (see CAMERA_DETECTION.md).

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
7. Devices — every OUI-matched device by vendor name + RSSI + "?", any score
   (visibility page: no alerts, no SURV counter; OUI-only/commodity hits live here)

Stingray alert overlays on summary page and appears as a row on page 1 when active.

## Phone & web interface

Three surfaces, all fed by the same Zig state via `api.zig` JSON renderers:

- **Base dashboard** — `web/dashboard.html`, embedded in flash and served by
  `main/httpd.c` only in base role (joins home WiFi). Threats/Map/Mesh tabs,
  Leaflet camera map, CSV export at `/api/export/csv`, config + location POST.
- **BLE phone client** — `web/ble.html`, a Web Bluetooth client hosted on
  GitHub Pages (NOT served by the device — Web Bluetooth requires HTTPS).
  Connects to the NUS GATT service in `main/ble.c`, pairs via a passkey shown
  on the OLED (Secure Connections + MITM, bonds persisted to NVS), and streams
  tagged JSON. Mobile-friendly; keeps WiFi channel hopping running.
- **Setup page** — `web/setup.html`, served over the "Argus Setup" AP on first
  boot until onboarding POSTs config and reboots.

BLE stream framing: each message is `<tag><json>\n` where tag ∈ S/D/M/C/G
(status/detections/mesh/cameras/config). The Zig main loop renders in its own
task (single owner of tracker state) and `main/ble.c` chunks the bytes into
MTU-sized notifications. Phone commands arrive on the RX characteristic.

Bonds persist via `tools/nimble_ref_sdkconfig.txt` (`CONFIG_BT_NIMBLE_NVS_PERSIST`)
because `sdkconfig` is gitignored and regenerated by `tools/patch-sdkconfig.py`.

## Releases & web flasher

End users flash from a browser — no toolchain. `web/flash.html` is an
esp-web-tools page (Web Serial, desktop Chrome/Edge) hosted on GitHub Pages.

Cut a release: `tools/release.sh [tag]` runs `./build-zig.sh`, `idf.py build`,
`idf.py merge-bin -o argus-merged.bin`, then `gh release create`. The Pages
workflow (`.github/workflows/pages.yml`) triggers on `release: published`,
`gh release download`s `argus-merged.bin` into `web/firmware/`, and deploys —
so the flasher fetches the binary same-origin (no CORS). `web/firmware/manifest.json`
points esp-web-tools at the merged image (ESP32-S3, offset 0).

## Button

| Gesture | Action |
|---------|--------|
| Short press | Next page |
| Double press | Toggle stealth mode (OLED off, BLE advertising off) |
| Hold 1-2s | CSV dump over serial |
| Hold 5s+ | Factory reset (clear SPIFFS + reboot) |

During BLE pairing the OLED shows a 6-digit passkey screen to enter on the phone.

## Pin map (Heltec V3)

GPIO 35: LED (onboard white, active HIGH)
GPIO 3:  Free (was piezo buzzer — no buzzer fitted; alerts are LED-only)
GPIO 0:  Button (PRG, active LOW, pullup)
GPIO 17: OLED SDA (I2C, internal)
GPIO 18: OLED SCL (I2C, internal)
GPIO 21: OLED RST (J2 pin 16)
GPIO 1:  Battery ADC (390k/100k divider)
GPIO 36: Vext control (active LOW)

Free: GPIO 2,3,4,5,6,7 (J3), GPIO 47,48 (J2)
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
- Add OUIs to `src/ouis.txt` under a `# Section` header — the nearest preceding
  comment sets the vendor name; a header keyword (flock/drone/remote id/camera/
  surveillance/commodity) sets the running category that drives the OUI-only
  score cap. NOTE: "Flock" OUI lists are commodity modules — file new chip-vendor
  OUIs as `commodity` (generic), not flock; Flock is detected by SSID
- Add BLE signatures to `BLE_SIGNATURES` table in `src/scanner.zig` line ~80
- Add BLE stream commands in the `main.zig` RX dispatch (tagged S/D/M/C/G,
  rendered by `api.zig`); WiFi channels live in `HOP_CHANNELS` in `main.zig`
- After Zig changes: `./build-zig.sh && idf.py build`

## What NOT to do

- Do NOT use @cImport for ESP-IDF headers
- Do NOT use ReleaseSmall (GNU ld symbol issues)
- Do NOT malloc/free in Zig (static arrays or FixedBufferAllocator)
- Do NOT change pins without updating this file
- Do NOT run idf.py before build-zig.sh
- Do NOT use upstream Zig (no Xtensa)

## Known issues

1. **No buzzer fitted.** Alerts are LED-only via LEDC PWM (threat-level
   brightness patterns). GPIO 3 is free if a piezo is ever added.

2. **BLE scan and WiFi promiscuous share the radio.** ESP32 coexistence
   handles this but scan intervals may shift under heavy WiFi traffic. An
   active BLE GATT connection (phone client) also competes with the passive
   scan; a relaxed connection interval keeps scan windows usable.

3. **Web dashboard is base-station only.** `main/httpd.c` serves it when the
   role is base (joined to home WiFi). Mobile units expose state over BLE
   (`web/ble.html`) instead. CSV export is available at `/api/export/csv`
   (base) and over USB serial (long press).

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
CAMERA_DETECTION.md ← non-Flock camera detection plan (OUI category-aware cap)
FIXES.md           ← walk test issues found June 21 + fixes
HARDWARE_TEST.md   ← hardware test results June 21
STINGRAY.md        ← Stingray/IMSI catcher detection plan
LAYERS_1_2.md      ← onboarding + web dashboard implementation plan
```
