# Detection Status

What's implemented and what's left from DETECTION.md.
Last updated: June 21, 2026

---

## Complete

### §1 — Raven Gunshot Detectors
- 8 BLE service UUIDs recognized (0x180A, 0x3100, 0x3200, 0x3300, 0x3400, 0x3500, 0x1809, 0x1819)
- Multi-UUID counting — 3+ UUIDs from same MAC scores higher
- Firmware version classification: 1.1.x (legacy UUIDs), 1.2.x (GPS/Power/Network), 1.3.x (Upload/Error)
- Flags: RAVEN_FW_1_1, RAVEN_FW_1_2, RAVEN_FW_1_3 stored in method bitmask
- Scoring: 70 pts base, FW version flags for display

### §2 — Drone Remote ID (WiFi)
- 802.11 tag 221 (Vendor Specific IE) parsed in wifi.c
- ASTM OUI check: 3C:EB:FE and 3C:EB:FF
- Remote ID payload captured, passed to Zig via `rid_out`/`rid_len_out`
- Message types parsed: Type 0 (Basic ID), Type 1 (Location), Type 2 (Self-ID)
- Scoring: 85 pts (CERTAIN) — FAA-mandated broadcast, zero false positives
- Drone OUIs in ouis.txt: DJI (60:60:1f, e4:7f:b2, 34:d2:62), Autel (e8:1f:84), Skydio (58:ed:0e), Parrot (a0:14:3d, 90:03:b7), Yuneec (c8:8e:db)

### §3 — Drone Remote ID (BLE)
- Service UUID 0xFFFA in BLE_SIGNATURES table
- Scoring: 60 pts via METHOD_DRONE

### §4 — Ring / Amazon Sidewalk
- Amazon company ID 0x0171 in BLE_SIGNATURES table
- METHOD_SIDEWALK flag (50 pts)
- Ring/Blink camera OUIs in ouis.txt: 74:c2:46, 40:b4:cd, 68:54:fd

### §5 — Consumer Surveillance Cameras
- 12 camera manufacturer OUIs in ouis.txt: Hikvision, Dahua, Reolink, Axis, Bosch, Hanwha
- Additional smart camera OUIs: Google Nest (3), Arlo (2), Wyze (1)
- SSID keyword matching (case-insensitive): hikvision, dahua, reolink, camera, cam_
- METHOD_CAM_SSID flag (30 pts)
- Camera threat class separate from ALPR

### §6 — BLE Signature Table
- Data-driven classification — 8 entries in BLE_SIGNATURES table
- Adding a new BLE device type is one line in the table, no new parsing code
- Current signatures: Apple Find My, Tile, Samsung SmartTag, Drone Remote ID BLE, Amazon Sidewalk, Chipolo, Fitbit, Tesla

### §7 — Scoring & False Positive Guards (partial)
- Multi-method corroboration bonus (+20 pts when 2+ methods agree)
- Strong RSSI bonus (+10 pts above -50 dBm)
- Randomized MAC penalty (-20 pts for locally-administered addresses)
- Static MAC bonus (+10 pts)
- SSID Flock-XXXX hex format validation (full 65 pts only with valid hex)
- Confidence thresholds: MED=40, HIGH=70, CERT=85
- Carrier probe SSID counting for IMSI catcher research (carrier_probes counter)
- Camera SSID keywords are case-insensitive

### §8 — IMSI Catcher Research
- Carrier SSID probe counting active: attwifi, VerizonWiFi, xfinitywifi, T-Mobile, vodafone, EE WiFi, Orange, o2wifi
- `carrier_probes` counter increments on each unique carrier SSID observed
- Data collection only — no detection alerts yet

### §9 — Database Maintenance
- 73 OUIs in ouis.txt (up from 31)
- New entries: Flock Safety (2 new), consumer cameras (12), smart cameras (6), drones (6), Ring (3)
- Compiled at build time via @embedFile + comptime
- Adding an OUI: edit ouis.txt, rebuild, done

---

## Not Yet Done

### Priority 1 — Finish What's Started

**Drone model text display.** ✅ DONE
The Remote ID parser now stores the Self-ID text ("DJI Mini 3 Pro") in `drone_model_buf`.
Displayed on Threats page ("DRN Mini3Pro") and Proximity page (model name below type badge).
- File: `src/scanner.zig` line 515, `src/display.zig` lines 387, 433
- Effort: 30 minutes

**Raven threshold fix.** ✅ DONE
Confirmed Raven now requires 2+ service UUIDs (was 1). Single 0x180A (Device Info)
alone is too generic. Single UUID gets METHOD_RAVEN_LOW at 40 pts MED instead of 70 pts HIGH.
16/16 u16 method flag bits now allocated.
- File: `src/scanner.zig` lines 218, 121
- Effort: 15 minutes

### Priority 2 — False Positive Reduction

**RSSI trend tracking.**
A stationary camera produces rise-peak-fall as you approach and pass. A moving phone appears suddenly at close range. Track last 3-5 RSSI values per device, detect the pattern, add +15 pts confidence bonus.
- File: `src/scanner.zig`, new field in TrackerEntry
- Effort: 2 hours

**Time-window re-detection.**
Same MAC + same approximate location 5+ minutes apart = fixed installation. Different location every time = mobile device. Track MAC + location hash pairs for re-detection scoring.
- File: `src/scanner.zig`
- Effort: 2 hours

**Real-world tuning.**
Carry the device for a week. Review CSV logs. Adjust scoring weights based on actual false positive rates. Every environment is different — the current weights are reasonable defaults but need field data.
- Effort: ongoing, 1 hour/week

### Priority 3 — Edge Cases

**BLE advertisement parsing robustness.**
The current parser iterates AD structures linearly. Some BLE devices use scan response data (separate from advertisement data). NimBLE may or may not combine them before calling the callback. Verify on real hardware.
- Effort: 1 hour investigation

**WiFi channel coverage.**
Currently scans channels 1, 6, 11 only. Flock cameras may use other channels. Full 1-13 channel scan with adaptive dwell times would catch more.
- Effort: 2 hours

**Raven threshold tuning.**
1 UUID = 70 pts (HIGH). In practice, a single 0x180A (Device Information) service UUID is generic and appears on many non-Raven devices. Consider requiring 2+ Raven-specific UUIDs before scoring.
- Effort: 30 minutes

---

## What's Been Added Since Initial Commit

| Date | Change |
|------|--------|
| Initial | 31 Flock OUIs, basic BLE (AirTag/Tile), SSD1306 framebuffer, buzzer/LED/button |
| +1 day | WiFi promiscuous sniffer, BLE NimBLE integration, LoRa SX1262 driver, GPS UART, SPIFFS logging, 7 OLED pages, confidence scoring, mesh protocol |
| +2 days | Module split (main/scanner/display/mesh), 42 new OUIs, BLE_SIGNATURES table, Raven UUIDs + FW classification, Drone Remote ID (WiFi + BLE), Amazon Sidewalk, camera SSID keywords, carrier probe counting, NMEA GPRMC parsing, randomized MAC penalty, CSV GPS coordinates |

---

## Quick Wins (30 min or less each)

- Add 3 more camera OUIs to ouis.txt (find them on Wigle.net or IEEE OUI lookup)
- Change buzzer alert pattern for CERTAIN detections (edit `alertByScore` in display.zig)
- Add a new camera SSID keyword (edit `cam_keywords` in scanner.zig line 241)
- Add a new BLE signature to BLE_SIGNATURES table (scanner.zig line 80)
- Change confidence score weights (edit `computeScore` in scanner.zig line 111)
