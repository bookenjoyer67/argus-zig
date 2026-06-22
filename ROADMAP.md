# Features — Argus Surveillance Tracker Scanner

All phases implemented. Zero external parts needed for basic operation.

---

## Detection Coverage

| Feature | Method | Hardware | Status |
|---------|--------|----------|--------|
| **Flock Safety ALPR cameras** | WiFi promiscuous OUI + SSID matching (31 OUIs) | None | ✓ |
| **AirTag / Find My** | BLE manufacturer 0x4C00 + type 0x12 | None | ✓ |
| **Tile trackers** | BLE service UUID 0xFEED | None | ✓ |
| **Samsung SmartTag** | BLE manufacturer 0x0075 | None | ✓ |
| **Drone Remote ID** | BLE UUID 0xFFFA + drone OUIs (ASTM F3411) | None | ✓ |
| **Raven gunshot sensors** | BLE service UUID set (0x180A/0x3100-0x3500) | None | ✓ |
| **Amazon Ring/Blink cameras** | WiFi OUI matching | None | ✓ |
| **Google Nest cameras** | WiFi OUI matching | None | ✓ |
| **Arlo cameras** | WiFi OUI matching | None | ✓ |
| **Wyze cameras** | WiFi OUI matching | None | ✓ |
| **GPS tagging** | NEO-6M UART NMEA parsing | NEO-6M ($5) | ✓ |

## System Features

| Feature | Details | Status |
|---------|---------|--------|
| **OLED display** | 128x64 SSD1306, 7-page UI, 5x7 font | ✓ |
| **Confidence scoring** | Multi-method corroboration, 0-100 score, alert escalation | ✓ |
| **Battery monitor** | GPIO 1 ADC, 390k/100k divider, voltage bar | ✓ |
| **SPIFFS logging** | CSV detection log at /spiffs/detections.csv, session persistence | ✓ |
| **LoRa mesh** | SX1262 915 MHz, broadcast detection packets (needs 2nd unit) | ✓ |
| **LED alerts** | Blink patterns by confidence: 1=MED, 3=HIGH, 5=CERTAIN | ✓ |
| **Serial CSV export** | Long-press PRG button → CSV dump over USB | ✓ |

## UI Pages (7 total, button-cycled)

| Page | Title | Content |
|------|-------|---------|
| 1/7 | **Summary** | ALPR/DRN/BLE/RAV counts, battery bar, OUI db size, GPS status |
| 2/7 | **Threats** | Recent tracker list: MAC, type, RSSI, score level badge |
| 3/7 | **Proximity** | Nearest threat: RSSI gauge, type, score, GPS coordinates |
| 4/7 | **History** | 5-bar chart: detections over last 60 minutes |
| 5/7 | **BLE** | BLE-only tracker list (AirTag, Tile, Samsung, drone) |
| 6/7 | **Stats** | Uptime, unique detections, WiFi frames, battery voltage |
| 7/7 | **System** | Firmware version, flash size, GPS fix status, battery |

## OUI Database

50 MAC OUI prefixes baked in at compile time:
- 33 Flock Safety ALPR camera prefixes
- 8 drone manufacturer prefixes (DJI, Autel, Skydio, Parrot, Yuneec)
- 9 surveillance camera prefixes (Ring/Blink, Nest, Arlo, Wyze)

Edit `src/ouis.txt` and rebuild to add more — no code changes needed.

## Source Structure

```
src/
├── main.zig         (581 lines) — entry point, main loop, extern fns, OUI db
├── display.zig      (581 lines) — SSD1306 driver, 7-page UI, LED alerts
├── scanner.zig      (392 lines) — detection classifiers, scoring, NMEA parser, logging
├── mesh.zig         ( 72 lines) — LoRa mesh packet send/receive
├── ouis.txt         ( 50 lines) — MAC OUI database
└── build.zig        ( 53 lines) — reference build script (not used)
```

## Binary Size History

| Phase | Binary | Features added |
|-------|--------|---------------|
| P0 | 245 KB | OLED driver |
| P1 | 550 KB | BLE scanning (NimBLE) |
| P2 | 948 KB | WiFi promiscuous |
| P3 | 967 KB | 7-page display + battery (3MB partition) |
| P4 | ~985 KB | Confidence scoring |
| P5 | 997 KB | SPIFFS persistence |
| P6 | 1021 KB | LoRa SX1262 driver |
| P7 | 1035 KB | GPS NMEA parser |
| P8 | 1038 KB | Drone Remote ID |
| P9 | 1041 KB | Raven gunshot detection |
| **Final** | **1041 KB** | **67% free on 3MB** |

## Known Limitations

1. **LoRa mesh needs a second Heltec V3** for end-to-end test. SX1262 driver initializes but TX/RX not verified solo.
2. **No buzzer** — LED blink patterns provide visual alerts instead.
3. **GPS needs NEO-6M module connected** — shows "NOFIX" without hardware.
4. **Battery reading** uses deprecated ADC API — migrate to `esp_adc/adc_oneshot.h` in future ESP-IDF version.
5. **No WiFi/Bluetooth coexistence tuning** — both radios active simultaneously, no power-saving.
6. **sdkconfig must be manually patched after `set-target`** — Kconfig choice resolution prevents `CONFIG_BT_NIMBLE_ENABLED` from being set via `sdkconfig.defaults`. Run `python3 tools/patch-sdkconfig.py`.

## Future Ideas

- **Multi-unit mesh triangulation** — two or more units share GPS-tagged detections for ALPR camera geolocation
- **GPX/KML export** — dump GPS-tracked detections as importable map files
- **Web dashboard** — ESP32-S3 WiFi AP mode serving a live threat map
- **BLE long-range (Coded PHY)** — extended range scanning for distant trackers
- **Audio spectrum analysis** — I2S microphone for gunshot acoustic detection (complement Raven BLE)
- **OLED sleep mode** — dim/bright cycle for extended battery life
- **OTA firmware updates** — over-the-air flashing via WiFi
