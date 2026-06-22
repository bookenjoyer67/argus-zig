# Competitive Analysis — Argus vs Existing Projects

June 2026. Comparing against active, maintained projects in the
surveillance-detection and adjacent spaces.

---

## The Field

| Project | Platform | Language | Focus | Active users |
|---------|----------|----------|-------|-------------|
| **Flock-You** | XIAO ESP32-S3 | C++/Arduino | WiFi Flock detection only | ~1,100 stars |
| **Flock-Detector 3.0** | XIAO ESP32-S3 | C++/Arduino | WiFi + BLE, confidence scoring, GPS, OLED | ~65 stars |
| **GhostESP** | ESP32 (various) | C/Arduino | General WiFi/BLE wardriving, pentesting | ~1,500+ stars |
| **DeFlock.me** | Web | JS/Python | Crowdsourced ALPR camera map | Public web app |
| **Meshtastic** | ESP32/nRF52 | C++ | LoRa mesh messaging + telemetry | 50,000+ nodes |
| **Flipper Zero** | STM32 | C | General purpose RF tool | 100,000+ units |
| **Argus** | Heltec V3 ESP32-S3 | Zig + C | WiFi + BLE + LoRa surveillance mesh | 1 (you) |

---

## Feature Matrix

| Feature | Flock-You | Flock-Det 3.0 | GhostESP | DeFlock | Meshtastic | Argus |
|---------|-----------|--------------|----------|---------|------------|-------|
| WiFi Flock detection | ✓ | ✓ | — | — | — | ✓ |
| BLE Flock detection | — | ✓ | — | — | — | ✓ |
| Raven/ShotSpotter | — | ✓ | — | — | — | ✓ |
| Drone Remote ID | — | — | — | — | — | ✓ |
| Amazon Sidewalk | — | — | — | — | — | ✓ |
| Consumer cameras | — | — | — | — | — | ✓ |
| AirTag/Tile/Samsung | — | — | ✓ | — | — | ✓ |
| Stingray/IMSI catcher | — | — | — | — | — | ✓ |
| Confidence scoring | — | ✓ | — | — | — | ✓ |
| OLED display | — | ✓ | — | — | — | ✓ |
| Web dashboard | — | — | ✓ | ✓ | — | ✓ |
| LoRa mesh | — | — | — | — | ✓ | ✓ |
| GPS | — | ✓ | ✓ | ✓ | ✓ | ✓ |
| CSV export | — | ✓ | ✓ | — | — | ✓ |
| OTA updates | — | — | ✓ | — | ✓ | — |
| Stealth mode | — | — | — | — | — | ✓ |
| Threat-level LED | — | — | — | — | — | ✓ |
| Multi-page OLED UI | — | ✓ | — | — | — | ✓ |
| Camera heatmap | — | — | — | ✓ | — | Planned |
| Onboarding/setup | — | — | ✓ | — | ✓ | ✓ |
| Open source | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| License | ? | ? | GPLv3 | ? | GPLv3 | AGPLv3 |

---

## What Argus has that nobody else has

### 1. All-in-one detection breadth
Nobody else detects Flock ALPR, Raven gunshot sensors, drone Remote ID,
Amazon Sidewalk, and consumer cameras on one device. Flock-You is WiFi-only.
Flock-Detector adds BLE but stops there. Argus covers the full surveillance
spectrum.

### 2. LoRa mesh for distributed surveillance mapping
This is the biggest differentiator. No other surveillance detection project
uses LoRa. Meshtastic has mesh but doesn't do surveillance detection.
Combining the two — mobile units reporting camera locations to a base station
over LoRa — is novel. After a week of driving, the base station has a map of
every camera in your city without cloud, subscription, or cellular.

### 3. Web dashboard
GhostESP has a web UI, but it's for device control, not a live threat
dashboard. DeFlock is a web app but relies on manual submissions. Argus is
automatic — cameras appear on the map from mesh detections without human
intervention.

### 4. Stingray detection
Indirect, probabilistic, but nobody else does it. The carrier probe burst
analyzer is unique in this space.

### 5. Pure-Zig hardware optimization
Nobody else uses Zig. The binary size comparison tells the story: 360KB
vs 530KB+ for equivalent C++ Arduino. The comptime OUI database and
fixed-allocation tracker table are design choices possible only in Zig.

### 6. Stealth mode + threat-level LED
Practical carry features. GhostESP has a screen-off mode but Argus's
double-press toggle and LED-only threat communication (you know the threat
level without looking at the screen) are absent from every competitor.

---

## What Argus is missing

### 1. Community / user base
Flock-You: 1,100 stars, 149 forks. Meshtastic: 50,000+ nodes deployed.
GhostESP: active community with Discord. Argus: one user. This isn't a
code problem — it's a distribution problem. Pre-built binaries, a web
flasher, and a getting-started guide would change this.

### 2. OTA firmware updates
GhostESP and Meshtastic both support OTA. Flash once, update forever.
Argus requires USB-C and PlatformIO/ESP-IDF. For a device you carry
around, OTA is table stakes for adoption beyond the developer.

### 3. GPS auto-logging without manual export
Flock-Detector writes GPS-tagged CSV to microSD. Argus writes to SPIFFS
and requires a long-press to dump over serial. For a walking/driving
device, seamless GPS logging that you retrieve later is expected.

### 4. Pre-built binaries / web flasher
Meshtastic's web flasher (flasher.meshtastic.org) is the gold standard —
plug in USB, open a website, click Flash, done. GhostESP has similar.
Nobody needs to install PlatformIO or ESP-IDF. Argus requires both Zig
and ESP-IDF toolchains.

### 5. Native mobile app + push
Meshtastic has iOS and Android apps. GhostESP has one. Argus now has a
**BLE phone interface** for mobile units — `web/ble.html`, a passkey-paired
Web Bluetooth client (hosted on GitHub Pages) that streams live status,
detections, mesh peers, and a camera/GPS map while channel hopping keeps
running. Gaps that remain: it's Android/desktop-Chrome only (iOS Safari has
no Web Bluetooth), it's not a native app, and there's no push notification,
background sync, or "you walked past 3 cameras today" summary.

### 6. External antenna support
The Heltec V3 has an IPEX connector for the LoRa antenna but the WiFi
antenna is a PCB trace. Competitors with external SMA connectors get
better range. Flock-You specifically recommends an external 2.4 GHz
antenna. Argus is limited to the onboard PCB antenna for WiFi.

### 7. Battery life optimization
Meshtastic nodes run for days on a single charge. GhostESP has power
management. Argus has the LED PWM dimming but no deep sleep between
scan cycles. BLE and WiFi are running continuously. A duty-cycled
mobile mode (scan 2s, sleep 8s) would multiply battery life.

### 8. MicroSD storage
Flock-Detector and GhostESP use microSD for logs. Argus uses SPIFFS
(limited to ~1MB). For a device that might log thousands of detections
over weeks, microSD is more practical.

### 9. Enclosure / product design
Flipper Zero ships in a custom injection-molded case with a color screen
and D-pad. Every Meshtastic board has 3D-printable cases. Argus is a
bare PCB with wires hanging off it. Even a simple 3D-printed snap case
would make it feel like a product.

---

## What Argus does worse

| Area | Better implementation | Project |
|------|----------------------|---------|
| WiFi channels | Full 1-13 scan vs Argus 1-11 (US default; EU 1-13 by config) | Flock-Detector 3.0 |
| BLE scanning | BLE address type analysis for scoring | Flock-Detector 3.0 |
| GPS logging | Auto-named CSV files on microSD | Flock-Detector 3.0 |
| Mesh UI | Phone app with map, message history | Meshtastic |
| Setup | One-click web flasher, no toolchain | Meshtastic, GhostESP |
| Power | Deep sleep, duty-cycled scanning | Meshtastic |

---

## What to build next (priority ranked by competitive gap)

1. **Pre-built binaries + web flasher** — biggest adoption blocker. Without
   this, Argus stays a personal project. esptool-js + GitHub Pages = ~4 hours.

2. **OTA firmware updates** — second biggest blocker. Nobody reflashes over
   USB-C after the first time if they don't have to. ESP-IDF OTA + GitHub
   Releases = ~4 hours.

3. **Battery life optimization** — duty-cycled scanning for mobile mode.
   BLE scan 2s on / 8s off, WiFi promiscuous 1s on / 9s off. Turns 8-hour
   battery into 40-hour battery. = ~3 hours.

4. **External WiFi antenna** — hardware change, not code. An IPEX-to-SMA
   pigtail + $3 2.4 GHz dipole. Doubles WiFi detection range. = $5, 10 minutes.

5. **3D-printable case** — makes it feel real. Heltec V3 dimensions are
   public. A snap-fit two-piece case with cutouts for OLED, button, antenna.
   = ~4 hours in CAD.

6. **WiFi channel hopping** — DONE. Mobile units now hop 1-11 with adaptive
   dwell (500ms on 1/6/11, 200ms on others); base stays locked for the
   dashboard STA link. Extend `HOP_CHANNELS` to 12/13 for EU regulatory domains.

7. **Mobile push notifications** — when base station detects a camera,
   push to phone via a simple mechanism (Telegram bot, ntfy.sh, or a
   polling dashboard open on the phone). = ~3 hours.

---

## Summary

Argus has the broadest detection coverage and the only LoRa mesh in the
surveillance-detection space. The detection engine is competitive with or
better than every existing project. The hardware UX (OLED, LED, button) is
competitive. The base web dashboard is unique, and mobile units now expose
the same live view over a passkey-paired BLE phone interface while WiFi
channel hopping keeps running.

The gaps are not in what the device detects — it's in distribution, battery
life, and OTA updates. These are the things that separate a personal project
from a product people actually use.
