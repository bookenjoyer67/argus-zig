# Argus — Surveillance Tracker Scanner

Passive BLE/WiFi surveillance detection for the Heltec WiFi LoRa 32 V3.
Written in Zig + ESP-IDF. Pocket-sized. Zero external parts needed.

## What it does

Scans for tracking and surveillance devices in real time:

- **Apple AirTag / Find My** — BLE advertisement pattern detection
- **Tile** — service UUID 0xFEED matching
- **Samsung SmartTag** — manufacturer ID signature
- **Flock Safety ALPR cameras** — 31 MAC OUI prefixes (WiFi promiscuous mode, pending)
- **Raven gunshot detectors** — BLE service UUIDs (pending)
- **Drone Remote ID** — ASTM F3411 WiFi + BLE (pending)

Alerts via buzzer chirp and LED blink. OLED shows device type, RSSI proximity,
and detection history. All detections logged to SPIFFS with GPS coordinates
(when GPS module is attached).

## Why this exists

Flock Safety operates the largest private surveillance network in the US.
Over 5,000 municipalities have sold their streets to automated license plate
readers that photograph every passing car. Raven/ShotSpotter microphones
blanket urban neighborhoods. AirTags are abused for stalking.

This device tells you when you're being watched. It costs $15 in parts.
No subscription. No cloud. No phone required.

## Hardware

| Part | Required? | Cost |
|------|-----------|------|
| Heltec WiFi LoRa 32 V3 (ESP32-S3) | Yes | $15 |
| Piezo buzzer (GPIO 3) | Optional | $1 |
| LiPo battery (JST 1.25mm) | Optional | $8 |
| NEO-6M GPS module (Vext) | Optional | $5 |

Zero external parts needed for basic operation — onboard LED blinks on detection.

## How it works

```
BLE advertisements        WiFi management frames
        │                         │
        ▼                         ▼
┌───────────────────────────────────────┐
│ NimBLE scan callback / WiFi callback  │  FreeRTOS tasks (C)
│ (ESP-IDF, C)                          │
├───────────────────────────────────────┤
│ Lock-free ring buffer                 │  ISR-safe queue
├───────────────────────────────────────┤
│ Tracker table + OUI matcher           │  Zig — this file
│ Confidence scoring                    │
├───────────────────────────────────────┤
│ OLED display / Buzzer / LED          │  Zig peripheral drivers
│ SPIFFS logging                        │
└───────────────────────────────────────┘
```

ESP-IDF provides FreeRTOS, NimBLE, WiFi stack, and SPIFFS.
All application logic — the tracker table, OUI database, display driver,
alert system, and confidence scoring — is in Zig (`src/main.zig`).

A thin C entry point (`main/main.c`) initializes ESP-IDF subsystems
and calls `zig_main()`. Control never returns to C.

## Binary size

| Language | Size | Delta |
|----------|------|-------|
| C++ (Arduino, NimBLE + U8g2 + WiFi) | 900 KB | baseline |
| C++ (Arduino, NimBLE + U8g2, no WiFi) | 530 KB | — |
| **Zig (ESP-IDF, pure SSD1306 + NimBLE)** | **228 KB** | current |
| Zig (ESP-IDF, release) | ~350 KB | estimated full build |

Savings come from:
- Pure-Zig SSD1306 driver replaces U8g2 (500KB → 2KB)
- `@embedFile` + comptime OUI parsing (no runtime filesystem)
- No Arduino framework overhead
- ReleaseSafe optimization (no panic strings, no monomorphization bloat)

## Project structure

```
argus-zig/
├── README.md               ← this file
├── BUILD.md                ← toolchain setup and build instructions
├── CMakeLists.txt           ESP-IDF project root
├── build-zig.sh            Builds libargus.a from Zig source
├── main/
│   ├── CMakeLists.txt       ESP-IDF main component
│   └── main.c               Thin C entry point → zig_main()
├── src/
│   ├── main.zig             All application logic
│   ├── ouis.txt             MAC OUI database (31 entries)
│   └── build.zig            Alternative build (not used; see BUILD.md)
├── zig-out/
│   └── libargus.a           Compiled Zig static library
└── build/                   ESP-IDF build output (idf.py build)
```

## License

AGPLv3.
You can use it, modify it, and sell devices running it,
as long as you share your changes under the same license.

## Credits

- **@NitekryDPaul** — WiFi promiscuous detection research, 30-OUI Flock Safety target list, addr1-receiver technique
- **Michael / DeFlockJoplin** — Wildcard-probe-request signature, 31st OUI (82:6b:f2)
- **colonelpanichacks** — Flock-You firmware (C++ reference implementation)
- **zmattmanz** — Flock-Detector 3.0 (confidence scoring, Raven UUIDs, RSSI trend)
- **kassane** — Zig ESP-IDF integration, zig-espressif-bootstrap toolchain
- **recamshak** — esp32-baremetal-zig (SVD-generated register definitions)

## Related projects

- [Flock-You](https://github.com/colonelpanichacks/flock-you) — C++ Flock Safety detector (Seeed XIAO ESP32-S3)
- [Flock-Detector 3.0](https://github.com/zmattmanz/flock-detection) — C++ multi-method confidence scoring
- [DeFlock](https://deflock.me) — Crowdsourced ALPR location data
- [zig-esp-idf-sample](https://github.com/kassane/zig-esp-idf-sample) — Zig + ESP-IDF reference
- [esp32-baremetal-zig](https://github.com/kassane/esp32-baremetal-zig) — Pure Zig ESP32 HAL
