# Development Roadmap — Argus

Each phase produces a flashable, testable firmware. No phase depends on
future phases. Build on what works.

---

## Phase 0: Visual Output (current + 1-2 hours)

**Goal:** See something on the physical OLED.

The framebuffer code exists. The I2C driver doesn't.

**Steps:**
1. Add `extern fn` declarations for ESP-IDF I2C driver:
   - `i2c_master_bus_config` — configure I2C on GPIO 17/18
   - `i2c_master_probe` — check if SSD1306 responds at 0x3C
   - `i2c_master_transmit` — send command/data bytes
2. Send SSD1306 init sequence (25-30 bytes of config commands)
3. Implement `oledUpdate()` — transmit 1024-byte framebuffer in 8 pages
4. Test: "ARGUS TRACKER" appears on the physical OLED

**Files:** `src/main.zig` — replace `oledUpdate()` placeholder

**Verification:** OLED shows the summary page. Button cycles pages (even if
there's only one page, you see it redraw).

---

## Phase 1: BLE Scanning (3-6 hours)

**Goal:** Detect AirTags, Tiles, and Find My devices. Display them on OLED.

This is the first real surveillance detection feature.

**Steps:**
1. Add `extern fn` declarations for NimBLE:
   - `nimble_port_init` — initialize NimBLE stack
   - `NimBLEDevice::init("Argus")` — set device name
   - `NimBLEScan::start(duration)` — start scan
   - `NimBLEScan::getResults()` — get discovered devices
2. Create a FreeRTOS task (from C in `main.c`, or via `xTaskCreate` extern)
   that runs BLE scans in a loop:
   - Scan for 2 seconds
   - Process results
   - Sleep for 1 second
   - Repeat
3. Parse BLE advertisement data:
   - Apple Find My: manufacturer data `0x4C 0x00` + type `0x12`
   - Tile: service UUID `0xFEED`
   - Samsung SmartTag: manufacturer ID `0x0075`
4. Push detections into the tracker table
5. Display active tracker count on OLED
6. Buzz on new detection (two ascending chirps — already implemented)

**Files:**
- `src/main.zig` — BLE scan processing, advertisement parsing, display updates
- `main/main.c` — optional: create BLE task here, or do it in Zig via extern

**Verification:** Walk past an AirTag (or a friend's iPhone with Find My enabled).
OLED shows "AIR TAG -62 dBm". Buzzer chirps. LED blinks.

---

## Phase 2: WiFi Promiscuous Mode (4-8 hours)

**Goal:** Detect Flock Safety ALPR cameras via WiFi OUI matching.

This is the Flock-You port — the original project's core feature.

**Steps:**
1. Add `extern fn` for ESP-IDF WiFi promiscuous mode:
   - `esp_wifi_set_promiscuous(true)`
   - `esp_wifi_set_promiscuous_filter(&filter)` — mgmt frames only
   - `esp_wifi_set_promiscuous_rx_cb(&callback)` — our callback
2. Write the WiFi sniffer callback in Zig (runs in ISR context):
   - Extract `addr2` (transmitter) and `addr1` (receiver) from 802.11 frame
   - Filter multicast (addr1 = FF:FF:FF:FF:FF:FF)
   - Filter randomized MACs (byte 0, bit 1 set)
   - Check against `KNOWN_OUIS` via `matchOui()`
   - Check SSID for "Flock" pattern in probe requests
3. Push matches into a lock-free ring buffer (callback can't allocate or block)
4. Drain ring buffer in main loop, add to tracker table
5. Display WiFi detections on OLED alongside BLE detections
6. Add WiFi-specific detection methods to confidence scoring:
   - OUI match: 40 pts
   - SSID "Flock-XXXX" format: 65 pts
   - RSSI > -50: +10 pts

**Files:** `src/main.zig` — WiFi callback, ring buffer, SSID parsing, display

**Verification:** Drive/walk past a known Flock camera. OLED shows:
"FLOCK SAFETY  OUI: 70:c9:4e  RSSI: -58  CERTAIN". Buzzer escalates
by confidence (1 beep MEDIUM, 3 beeps HIGH, 5 beeps CERTAIN).

---

## Phase 3: Multi-Page Display (2-3 hours)

**Goal:** The 7 OLED screens from the original Argus design.

**Steps:**
1. Add page definitions:
   - Page 0: Threat summary (ALPR count, tracker count, battery)
   - Page 1: Active threats list (MAC, type, RSSI, age)
   - Page 2: RSSI proximity gauge for nearest threat
   - Page 3: Detection history (bar chart, last hour)
   - Page 4: BLE tracker list (AirTags, Tiles, etc.)
   - Page 5: Session stats (uptime, total detections)
   - Page 6: System status (heap, flash, battery V)
2. Button short press cycles pages
3. Auto-switch to proximity page on new detection
4. Add battery voltage reading via `analogRead(1)` and display bar

**Files:** `src/main.zig` — display pages, button logic

**Verification:** Button cycles through 7 screens. New detection auto-shows
proximity gauge. Battery bar updates.

---

## Phase 4: Confidence Scoring (2-4 hours)

**Goal:** Multi-method corroboration. Reduce false positives.

Port the scoring system from Flock-Detector 3.0.

**Steps:**
1. Add scoring to tracker entries:
   ```zig
   score: u8,          // 0-100
   methods: MethodFlags,  // bitmask of which methods triggered
   ```
2. Implement weighted scoring:
   - MAC OUI: 40 pts
   - SSID pattern: 50 pts
   - SSID Flock-XXXX format: 65 pts
   - BLE device name: 45 pts
   - Manufacturer ID 0x09C8: 60 pts
   - Raven UUID (1): 70 pts
   - Raven UUID (3+): 90 pts
   - Find My pattern: 70 pts
3. Bonuses:
   - Multi-method (+20 if 2+ methods agree)
   - Strong RSSI (+10 if > -50 dBm)
   - Static BLE address (+10)
4. Alert escalation by score:
   - 40-69: MEDIUM — single beep
   - 70-84: HIGH — 3 fast beeps
   - 85+: CERTAIN — 5 rapid beeps
5. Display confidence level on OLED

**Files:** `src/main.zig` — scoring logic, alert escalation, display

**Verification:** A real Flock camera scores 85+ (CERTAIN). A random Murata
BLE module scores 40 (MEDIUM). Multiple methods on same MAC stack.

---

## Phase 5: Persistence (1-2 hours)

**Goal:** Detection history survives power cycles.

**Steps:**
1. Add `extern fn` for SPIFFS:
   - `spiffs_mount` — mount SPIFFS partition
   - `spiffs_write` / `spiffs_read` — file I/O
2. Log detections to CSV on SPIFFS:
   ```csv
   timestamp,class,oui,mac,rssi,score,level,methods
   ```
3. Save session stats (lifetime counters) on clean shutdown
4. Restore on boot
5. Export via USB serial: `pio device monitor` shows CSV dump on button hold

**Files:** `src/main.zig` — SPIFFS integration, CSV logging

**Verification:** Power cycle the device. Lifetime counters persist.
Previous session is saved.

---

## Phase 6: LoRa Mesh (4-8 hours)

**Goal:** Multiple Argus units share detections.

**Requires:** Second Heltec V3 (or a friend with one).

**Steps:**
1. Add `extern fn` for SX1262 LoRa via RadioLib or ESP-IDF:
   - Initialize SX1262 on SPI (GPIO 8-14 are hardwired)
   - Set frequency 915 MHz (US) or 868 MHz (EU)
   - Set spreading factor 9, bandwidth 125 kHz
2. Define mesh packet format:
   ```
   [type:1B][node:1B][class:1B][lat:4B][lon:4B][oui:3B][rssi:1B][crc:1B] = 16B
   ```
3. Broadcast on detection (TX)
4. Listen always (RX), display peer detections with "MESH" tag
5. Heartbeat every 60s with battery level
6. "Mesh peers: N" on OLED

**Files:** `src/main.zig` — LoRa driver, mesh protocol

**Verification:** Two units. Unit A detects a camera. Unit B's OLED shows
"MESH: ALPR at 38.6270, -90.1994 (via Unit A)." Heartbeats appear on
mesh status page.

---

## Phase 7: GPS (2-3 hours)

**Goal:** Tag every detection with coordinates.

**Requires:** NEO-6M GPS module ($5).

**Steps:**
1. Wire NEO-6M to Vext (power) and UART (GPIO 4/5)
2. Add `extern fn` for UART driver
3. Parse NMEA sentences ($GPGGA, $GPRMC) in Zig
4. GPS powers on via Vext (GPIO 36) during reads, off otherwise
5. Tag detections with lat/lon in tracker table
6. Display coordinates on OLED
7. Export GPX/KML on USB

**Files:** `src/main.zig` — GPS NMEA parser, Vext power control

**Verification:** Walk outside. OLED shows GPS fix. Detection CSV has
coordinates. Import into Google Earth: red pins on every camera location.

---

## Phase 8: Drone Remote ID (2-3 hours)

**Goal:** Detect drones via ASTM F3411 Remote ID.

**Steps:**
1. Parse WiFi Remote ID packets (802.11 beacon containing Remote ID info)
2. Parse BLE Remote ID advertisements (service UUID 0xFFFA)
3. Add drone OUIs to `ouis.txt`
4. Display on OLED: "DRONE  RSSI: -72  DJI Mini 3"

**Files:** `src/main.zig` — Remote ID parser, `ouis.txt` — drone OUIs

---

## Phase 9: Raven Gunshot Detection (2-3 hours)

**Goal:** Detect Raven/ShotSpotter gunshot sensors.

**Steps:**
1. Add Raven BLE service UUIDs to the scanner:
   - 0x180A (Device Info)
   - 0x3100 (GPS Location)
   - 0x3200 (Power Management)
   - 0x3300 (Network Status)
   - 0x3400 (Upload Statistics) — firmware 1.3.x
   - 0x3500 (Error Diagnostics) — firmware 1.3.x
2. Classify firmware version from UUID set
3. Display on OLED: "RAVEN  FW: 1.3.x  RSSI: -65"

**Files:** `src/main.zig` — Raven UUID matching

---

## Priority Order

Do these in this exact sequence — each builds on the last:

1. **Phase 0** — OLED I2C driver (unlocks visual feedback for everything else)
2. **Phase 1** — BLE scanning (first real feature, testable immediately)
3. **Phase 2** — WiFi promiscuous (the core Flock-You port)
4. **Phase 3** — Multi-page display (necessary for showing all the data from 1+2)
5. **Phase 4** — Confidence scoring (makes 1+2 useful, not just noisy)
6. **Phase 5** — Persistence (detections survive reboot)
7. **Phase 6+** — Do whichever matters most to you

---

## Quick Wins (30 minutes each, any order)

These don't depend on anything:

- Add 5 more OUI entries to `ouis.txt` — rebuild, they're baked in
- Change buzzer alert pattern — edit `alertNew()` function
- Change LED blink timing — find "Heartbeat LED" in `zig_main()`
- Add a new display string — search `oledDrawStr` in drawSummary()
- Rename the device on OLED — change "ARGUS TRACKER" string in drawSummary()
