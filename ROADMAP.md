# Development Roadmap — Argus

Status as of June 22, 2026. Checked = done, blank = not started.

---

## Phase 0: Visual Output ✓

OLED I2C driver, SSD1306 init sequence, framebuffer transmit.
Device boots and displays text on the physical OLED.

## Phase 1: BLE Scanning ✓

NimBLE passive scanning, Apple Find My / Tile / Samsung SmartTag detection.
Tracker table with fixed allocation. Buzzer alerts on new detection.

## Phase 2: WiFi Promiscuous Mode ✓

802.11 frame parsing, OUI matching, SSID extraction, probe request IE walking.
Flock Safety ALPR camera detection. Flock-XXXX format validation.
Remote ID tag 221 parsing for drone detection.

## Phase 3: Multi-Page Display ✓

7 OLED pages with 500ms live refresh:
- Summary (SURV/TRACK counters)
- Surveillance (ALPR/drone/raven/camera filtered)
- Proximity (RSSI readout + trend arrow + distance word)
- History (5-bar chart, 12-min buckets)
- Trackers (AirTag/Tile/Samsung list)
- Stats (uptime, totals)
- System (heap, flash, battery)

## Phase 4: Confidence Scoring ✓

Multi-method corroboration, RSSI bonus, randomized MAC penalty, static MAC bonus.
Confidence thresholds: MED 40, HIGH 70, CERT 85. Alert escalation by score.

Score weight table:
```
MAC OUI:          40 pts    SSID Flock-XXXX:  65 pts
SSID prefix:      50 pts    BLE name:         45 pts
Manufacturer ID:  60 pts    Find My:          70 pts
Raven UUID:       70 pts    Tile UUID:        45 pts
Drone BLE:        60 pts    WiFi Drone:       85 pts
Sidewalk:         50 pts    Cam SSID:         30 pts
Multi-method:    +20 pts    Strong RSSI:     +10 pts
Static MAC:      +10 pts    Random MAC:      -20 pts
RSSI trend:      +10 pts
```

## Phase 5: Persistence ✓

SPIFFS CSV logging (detections.csv), session counters survive reboot.
CSV export via long-press button over serial.

## Phase 6: LoRa Mesh ✓

SX1262 driver (full opcode set, SPI, BUSY polling, calibration).
meshSend() on high-confidence detection, meshRecv() with CRC validation.
14-byte packet format. Base station + mobile unit architecture supported.

## Phase 7: GPS ✓

NEO-6M UART driver, NMEA $GPGGA + $GPRMC parsing.
GPS coordinates logged with detections. GPS status on summary page.

## Phase 8: Drone Remote ID ✓

ASTM F3411 WiFi tag 221 + BLE UUID 0xFFFA. Drone OUIs in database.
Message type parsing (Basic ID, Location, Self-ID).

## Phase 9: Raven Gunshot Detection ✓

8 BLE service UUIDs, firmware version classification, hardware verified.

---

## Remaining Work

### Short term

- [x] Drone model text display — Self-ID text captured but discarded
- [x] Real-world scoring weight tuning — OUI-only cap, field data ongoing
- [ ] OUI database maintenance — add as new prefixes are discovered
- [x] Raven threshold tuning — 2+ UUIDs = confirmed, 1 UUID = low confidence
- [x] Stingray burst detector implementation (see STINGRAY.md)
- [x] WiFi channel hopping (mobile role) — 1-11 adaptive dwell; EU 1-13 by
      extending HOP_CHANNELS in main.zig
- [x] Stealth mode (double-press toggle, OLED off, silent scanning, BLE adv off)
- [x] UX enhancements (threat-level LED patterns, boot sequence, LEDC PWM)
- [x] Non-Flock camera surfacing — category-aware OUI cap (camera/drone OUIs →
      MEDIUM), vendor/category OUI_DB built from ouis.txt sections (CAMERA_DETECTION.md, Approach B)

### Medium term

- [x] Web dashboard + onboarding (see LAYERS_1_2.md) — base-station httpd,
      config, api, Threats/Map/Mesh tabs, Leaflet camera map, configurable
      base location (see DASHBOARD_MAP.md)
- [x] BLE phone interface — NUS GATT passkey-paired stream (SC+MITM, NVS
      bonds) + web/ble.html Web Bluetooth client hosted on GitHub Pages
- [ ] Captive portal DNS redirect
- [ ] Geiger mode on proximity page (audio clicks proportional to RSSI)
- [ ] MAC ignore list for persistent false positives

### Long term

- [ ] OTA firmware updates via GitHub Releases
- [ ] Community OUI database with PR-based contributions
- [ ] Web flasher (esptool-js) for no-toolchain flashing
- [ ] 3D-printable enclosure
