# Detection Status

What's implemented and what's left from DETECTION.md.
Last updated: June 22, 2026

---

## Complete

### Flock Safety ALPR Cameras
- 33 MAC OUI prefixes (original 31 + 2 newer deployments)
- WiFi promiscuous sniffer captures management and data frames
- SSID "Flock-XXXX" format validation with hex digit check
- Camera sleep-cycle awareness — detection window depends on camera duty cycle
- Scoring: OUI match 40 pts, SSID prefix 50 pts, Flock-XXXX format 65 pts

### Raven / ShotSpotter Gunshot Sensors
- 8 BLE service UUIDs (0x180A, 0x3100, 0x3200, 0x3300, 0x3400, 0x3500, 0x1809, 0x1819)
- Multi-UUID counting — 3+ UUIDs scores higher
- Firmware version classification: 1.1.x, 1.2.x, 1.3.x
- Hardware verified: detected on walk test June 21

### Drone Remote ID
- WiFi: ASTM F3411 tag 221 IE parsing with OUI check (3C:EB:FE/FF)
- BLE: service UUID 0xFFFA in signature table
- Message types: Basic ID, Location, Self-ID
- Drone OUIs: DJI (3), Autel, Skydio, Parrot (2), Yuneec
- Scoring: WiFi Remote ID 85 pts (CERTAIN), BLE Remote ID 60 pts

### Amazon Sidewalk (Ring / Echo / Tile)
- BLE manufacturer ID 0x0171
- Tracker type = .camera (counts toward camera counter)
- Ring/Blink WiFi OUIs: 3 entries in ouis.txt
- Camera SSID keyword "ring" added

### Consumer Surveillance Cameras
- 12 manufacturer OUIs: Hikvision, Dahua, Reolink, Axis, Bosch, Hanwha
- 6 smart camera OUIs: Google Nest (3), Arlo (2), Wyze (1)
- SSID keyword matching: hikvision, dahua, reolink, amcrest, camera, cam_, ring
- Case-insensitive matching
- Separate .camera threat class from .flock_camera

### BLE Tracker Classification
- Data-driven BLE_SIGNATURES table — 8 entries
- Apple Find My: 0x4C00 + type 0x12, payload length >= 22 for AirTag vs iPhone
- Tile: service UUID 0xFEED
- Samsung SmartTag: manufacturer ID 0x0075
- Chipolo: service UUID 0x1802
- Fitbit: manufacturer ID 0x0059
- Tesla phone key: service UUID 0x1530
- Adding a new signature is one table row

### Scoring & False Positive Guards
- Multi-method corroboration: +20 pts when 2+ methods agree
- Strong RSSI bonus: +10 pts above -50 dBm
- Randomized MAC penalty: -20 pts for locally-administered addresses
- Static MAC bonus: +10 pts
- SSID Flock-XXXX hex format validation (full 65 pts only with valid hex)
- Confidence thresholds: MED=40, HIGH=70, CERT=85
- Noise rejection: devices with methods==0 not stored in tracker table
- CSV dedup: only log on first detection, not every sighting
- History bars: rightmost=recent, leftmost=oldest

### RSSI Trend Tracking
- 5-value ring buffer per tracker entry (rssi_history)
- detectRssiTrend() identifies rise-peak-fall pattern
- +10 pts bonus for stationary device signature

### IMSI Catcher / Stingray Detection ✓
- Carrier probe SSID counting: attwifi, VerizonWiFi, xfinitywifi, T-Mobile, etc.
- 5-second bucket rotation with rolling 60-second baseline
- Spike detection: bucket exceeds 3x average, confirmed by second spike within 30s
- STINGRAY? alert flag with auto-clear after 5 minutes
- Display on summary page banner and surveillance page row
- CSV event logging
- Probabilistic — indirect detection, flagged with caveat
- See STINGRAY.md for algorithm details

### Display / UX
- 7 OLED pages with 500ms live refresh on all pages
- Summary: SURV + TRACK counters (.wifi_device excluded from SURV)
- Surveillance page: filtered to .flock_camera, .drone, .raven, .camera only
- Proximity page: big RSSI, trend arrow, distance word, bar
- History page: 5-bar chart, 12-min buckets, proper ordering
- Trackers page: AirTag/Tile/Samsung/FindMy list
- LED threat-level patterns (sleep/scan/clear/aware/watched/targeted/error)
- Battery voltage + percentage bar
- GPS status display
- Stealth mode: double-press toggle, OLED off, LED dark, scanning continues
- Boot sequence: LED choreography → ARGUS logo → Scanning... → summary

### Persistence
- SPIFFS CSV detection log (detections.csv)
- Session counters survive reboot
- CSV export via long-press button over serial

### GPS
- NEO-6M UART driver on GPIO 4/5, 9600 baud
- NMEA parsing: $GPGGA and $GPRMC
- GPS coordinates logged with detections
- GPS status shown on summary page

### LoRa Mesh
- SX1262 driver: full opcode set, SPI, BUSY polling, calibration
- Mesh packet: 14-byte format with CRC
- meshSend() on high-confidence detection
- meshRecv() with CRC validation and tracker table integration

---

## Not Yet Done

### Priority 1

**Drone model text display.** Self-ID text captured but discarded with `_ = txt`.
Store model name for display on proximity and threats pages.
- File: `src/scanner.zig` line 529
- Effort: 30 min

**Real-world tuning.** Scores are reasonable defaults but need field calibration.
Carry the device, review CSV, adjust weights.
- Effort: ongoing

### Priority 2

**Raven threshold tuning.** Single 0x180A UUID triggers 70 pts but is generic.
Consider requiring 2+ Raven-specific UUIDs before scoring.
- Effort: 30 min

**WiFi channel coverage.** Currently channels 1, 6, 11 only. Full 1-13 scan
with adaptive dwell times would catch more cameras.
- Effort: 2 hours

### Priority 3

**Web dashboard.** Base station mode with WiFi AP, HTTP server, live dashboard.
Planned in LAYERS_1_2.md. Not started.
- Effort: 24 hours

**OTA updates.** ESP-IDF OTA via GitHub Releases. Requires second partition table.
- Effort: 4 hours

---

## Threat Classes

```
.flock_camera   — Flock Safety ALPR (OUI + SSID corroboration)
.wifi_device    — WiFi device with known surveillance OUI
.drone          — Drone Remote ID (ASTM F3411, WiFi or BLE)
.raven          — Raven/ShotSpotter gunshot sensor (BLE UUIDs)
.camera         — Consumer/commercial surveillance camera (OUI + SSID)
.airtag         — Apple AirTag / Find My accessory
.tile           — Tile tracker
.samsung        — Samsung SmartTag
.findmy         — Generic Find My device
.unknown        — Unclassified (filtered from table, not stored)
```

Stingray detection is not a TrackerType — it's an alert flag with special display handling.

---

## OUI Database

73 MAC OUI prefixes in `src/ouis.txt`, parsed at compile time:

```
33 Flock Safety
 3 Ring/Blink
 3 Google Nest
 2 Arlo
 1 Wyze
 6 Drone (DJI/Autel/Skydio/Parrot/Yuneec)
12 Surveillance cameras (Hikvision/Dahua/Reolink/Axis/Bosch/Hanwha)
13 Other surveillance
```

Adding an OUI: edit the text file, rebuild. No code changes needed.
