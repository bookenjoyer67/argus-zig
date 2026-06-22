# Detection Expansion Roadmap

Each section is a self-contained detection class you can add independently.
Ordered by impact-to-effort ratio. Every addition makes the device more useful
in a different environment — urban, suburban, event, or home.

---

## 1. Raven Gunshot Detectors (2-3 hours) ✅ IMPLEMENTED (P9)

**What:** Raven (SoundThinking, formerly ShotSpotter) acoustic gunshot sensors.
Deployed in 150+ US cities. They use BLE for configuration and diagnostics.
A single Raven sensor broadcasts 3-8 BLE service UUIDs depending on firmware
version. Multiple UUIDs from the same MAC is a strong signal.

**Status:** 8 Raven UUIDs detected in `classifyBle()`. Firmware version
classification (v1.1/v1.2/v1.3) encoded in method flags. Display shows
`RAV v1.3 RSSI:-72 CERT` on threats page. 70 pts base score, 90 pts
with 3+ UUID corroboration bonus.

**Detection method:** BLE service UUID advertisement.

**Research needed:**
- Source: GainSec [raven_configurations.json](https://github.com/GainSec/raven-research)
- Source: Flock-Detector 3.0 `detectors.cpp` (Raven UUID table)
- Map UUIDs to firmware versions for classification

**Known UUIDs:**

| UUID | Service | Firmware |
|------|---------|----------|
| `0x180A` | Device Information | All versions |
| `0x3100` | GPS Location | 1.2.x+ |
| `0x3200` | Power Management (battery/solar) | 1.2.x+ |
| `0x3300` | Network Status (LTE/WiFi) | 1.2.x+ |
| `0x3400` | Upload Statistics | 1.3.x |
| `0x3500` | Error/Failure Diagnostics | 1.3.x |
| `0x1809` | Health Thermometer (legacy) | 1.1.x |
| `0x1819` | Location & Navigation (legacy) | 1.1.x |

**Implementation:**

1. Add `classifyRaven()` to `src/main.zig`. Check BLE advertisement data
   for the presence of known Raven service UUIDs. Count how many match.

2. Scoring:
   - 1 UUID: 70 pts (HIGH)
   - 3+ UUIDs: 90 pts (CERTAIN)
   - Bonus: static BLE address +10 pts (Raven sensors don't rotate MACs)

3. Firmware classification:
   - If 0x3400 or 0x3500 present → firmware 1.3.x
   - If 0x3100 or 0x3200 present, no 0x34xx/0x35xx → firmware 1.2.x
   - If only 0x180A + 0x1809/0x1819 → firmware 1.1.x (legacy)

4. Display on OLED: `RAVEN  FW:1.3.x  RSSI:-72  CERTAIN`

**Verification:** Unlikely to find one unless you're in a major city (Chicago,
NYC, Oakland). Known deployments: [SoundThinking coverage map](https://www.soundthinking.com).

---

## 2. DJI Drone Remote ID — WiFi (4-6 hours) ✅ IMPLEMENTED (D1-D5)

**Status:** `wifi_sniffer_cb()` parses tag 221 IEs for ASTM OUI `3C:EB:FE`/`FF`.
Remote ID payload passed through ring buffer to `parseDroneRemoteId()` in
scanner.zig. Supports Basic ID (type 0), Location (type 1), and Self-ID (type 2)
message types. 85 pts CERTAIN when Remote ID payload found.

**What:** DJI drones (Mavic, Mini, Air, Phantom) broadcast Remote ID over WiFi
since 2023. The FAA requires it. Every DJI drone in the US is broadcasting
its position, altitude, speed, and operator location in plaintext.

**Detection method:** 802.11 beacon frames containing Remote ID Information
Element (tag 221, OUI 0x3CEBFE or 0x3CEBFF).

**Research needed:**
- Standard: [ASTM F3411-22a](https://www.astm.org/f3411-22a.html) — Remote ID spec
- Reference: [OpenDroneID](https://github.com/opendroneid/opendroneid-core-c) C library
- DJI-specific: DJI uses WiFi NAN (Neighbor Awareness Network) beacons
  with Remote ID data in vendor-specific IEs.

**What the WiFi sniffer already gives you:**
The promiscuous callback in `main/wifi.c` already captures all management
frames including beacons. It already walks IEs looking for SSID (tag 0).
You need to add IE tag 221 parsing.

**Implementation:**

1. In `wifi_sniffer_cb()` (wifi.c line 39), after the SSID IE parsing,
   add a check for tag 221:

   - Tag 221 is "Vendor Specific" IE
   - First 3 bytes of the IE data are the OUI
   - OUI `3C:EB:FE` or `3C:EB:FF` indicates ASTM Remote ID
   - Remaining bytes are the Remote ID message (up to 255 bytes)

2. Parse Remote ID message type:
   - Type 0: Basic ID (drone ID, serial number)
   - Type 1: Location/Vector (lat, lon, altitude, speed, heading)
   - Type 2: Self-ID (free text, typically "DJI Mini 3 Pro")
   - Type 3: System (operator location)
   - Type 4: Operator ID

3. Extract drone model from Type 2 (Self-ID) text. Display on OLED:
   `DRONE  DJI Mini 3  RSSI:-68  120m alt`

4. Scoring: valid Remote ID packet = 85 pts (CERTAIN). This is an explicit
   FAA-mandated broadcast — no false positives.

5. Add `DRONE` to the threat class enum next to `ALPR`, `GUNSHOT`, `TRACKER`.

**Verification:** Go to a park where people fly drones. Or buy a DJI Mini 4K
($299) and test with your own drone. The Remote ID broadcast starts automatically
on takeoff.

---

## 3. Drone Remote ID — BLE (2-3 hours) ✅ IMPLEMENTED (P8, D4)

**What:** Some drones (Autel, Skydio, older DJI) use BLE for Remote ID instead
of WiFi. BLE Remote ID uses a specific service UUID and advertisement format.

**Status:** UUID `0xFFFA` detected in `classifyBle()`. WiFi Remote ID (tag 221 IE)
also parsed from 802.11 beacon frames in `wifi_sniffer_cb()`. Both paths feed
`METHOD_WIFI_DRONE` (85 pts CERTAIN — FAA-mandated, zero false positives).

**Detection method:** BLE advertisement with Remote ID service data.

**Research needed:**
- BLE Remote ID uses 16-bit service UUID `0xFFFA` (ASTM assigned)
- Advertisement contains Remote ID message in service data
- Same message format as WiFi Remote ID (ASTM F3411)

**Implementation:**

1. In the BLE scan callback (`ble_gap_event_cb` in ble.c), or in `classifyApple()`
   in main.zig, check for service UUID 0xFFFA in advertisement data.

2. Parse service data for Remote ID messages (same format as WiFi).

3. Score: valid BLE Remote ID = 85 pts (CERTAIN).

4. Display: `DRONE  Autel Evo  RSSI:-75  BLE`

**Verification:** Same as WiFi — park or own drone. BLE Remote ID has shorter
range (~100m vs ~500m for WiFi).

---

## 4. Ring / Amazon Sidewalk (2-3 hours) ✅ IMPLEMENTED

**Status:** `classifyBle()` checks for Amazon manufacturer ID `0x0171`.
`METHOD_SIDEWALK` (50 pts). Ring doorbells and Echo devices transmit this.

**What:** Amazon Sidewalk is a low-bandwidth mesh network that uses BLE and
900 MHz FSK. Ring doorbells, Echo devices, and Tile trackers participate.
Every compatible device broadcasts Sidewalk advertisements over BLE.

Sidewalk is controversial — it shares your internet with neighbors' devices
by default (opt-out, not opt-in). Detection tells you how many Sidewalk
devices are near you and whether your own devices are participating.

**Detection method:** BLE advertisement with Amazon manufacturer ID.

**Research needed:**
- Amazon company ID in BLE manufacturer data: `0x0171` (little-endian: bytes `71 01`)
- Sidewalk uses specific advertisement types within Amazon's manufacturer data
- Source: [Sidewalk protocol documentation](https://github.com/amzn/sidewalk-documentation)

**Implementation:**

1. In the BLE advertisement parser, check manufacturer data for company ID 0x0171.

2. Look for Sidewalk-specific sub-type bytes (research needed — the protocol
   documentation specifies the exact byte patterns).

3. Distinguish device types:
   - Ring doorbell / camera — has "Ring" or specific model ID in data
   - Echo device — has "Amazon" or Echo model ID
   - Tile tracker — Tile uses Sidewalk for extended range

4. Score:
   - Amazon manufacturer ID + Sidewalk pattern: 50 pts (MEDIUM)
   - Multiple Sidewalk devices in range: add to consumer tracker count
   - Sidewalk is surveillance infrastructure but not government — classify
     as "TRACKER" on the consumer side of the display

5. Display: `SIDEWALK  Ring Doorbell  RSSI:-70`

**Verification:** Walk through a residential neighborhood. Every Ring doorbell
within ~50m will show up. In a dense urban area, expect 10-20 Sidewalk devices.

---

## 5. Consumer Surveillance Cameras — WiFi OUIs (1-2 hours) ✅ IMPLEMENTED

**Status:** 15 camera manufacturer OUIs added (Hikvision, Dahua, Reolink, Axis,
Bosch, Hanwha). SSID keyword matching for "hikvision", "dahua", "reolink",
"camera", "cam_". `METHOD_CAM_SSID` (30 pts). New `camera` threat class
with "CAM" badge on threats page.

**What:** Hikvision, Dahua, Reolink, and other IP cameras use WiFi in AP mode
or client mode. Their MAC OUIs are registered with the IEEE and are public.
A camera broadcasting WiFi is visible to the promiscuous sniffer.

**Detection method:** MAC OUI matching against known camera manufacturer prefixes.

**Research needed:**
- IEEE OUI database search for Hikvision, Dahua, Reolink, Amcrest, Lorex,
  Uniview, Axis, Bosch, Hanwha
- Some cameras use OEM WiFi modules (Realtek, Mediatek). These won't match
  a camera-specific OUI but SSIDs like "Hikvision_XXXX" will.

**Known OUIs to add to `ouis.txt`:**

```
# Hikvision (IP cameras, NVRs)
c4:2f:90
18:68:cb
4c:6f:6e
bc:ad:28

# Dahua (IP cameras, NVRs)
3c:ef:8c
90:02:a9
4c:11:bf
14:a7:8b

# Reolink (consumer cameras)
34:47:d4

# Axis (commercial surveillance)
00:40:8c
ac:cc:8e
b8:a4:4f

# Bosch (commercial)
00:07:5f
20:68:9d

# Hanwha (formerly Samsung Techwin)
00:16:6c
00:68:eb
```

**Implementation:**

1. Add 15-25 camera manufacturer OUIs to `src/ouis.txt`. Rebuild.

2. Add SSID keywords to the WiFi classifier:
   - `hikvision`, `dahua`, `reolink`, `amcrest`, `lorex`, `axis`, `camera`, `cam_`

3. New threat class: `CAMERA` (consumer surveillance, distinct from `ALPR`
   which is government/municipal).

4. Scoring:
   - Camera OUI match: 40 pts (MEDIUM)
   - Camera OUI + camera SSID keyword: 65 pts (HIGH)
   - Bonus: probe request with SSID = empty (camera seeking AP): +10 pts

5. Display: `CAMERA  Hikvision  RSSI:-55  CH:6`

**Verification:** Walk through any commercial area. Parking lots, retail stores,
office buildings. Hikvision cameras are everywhere. If it's pointed at a public
space, you'll see it.

---

## 6. BLE Advertisement Deep Parsing (3-4 hours)

**What:** The current BLE scanner stores raw advertisement bytes but only
checks for Apple Find My and Tile patterns. Many more BLE-trackable
devices exist.

**Detection targets to add:**

| Device | Signature | Priority |
|--------|-----------|----------|
| Chipolo trackers | Manufacturer data, service UUID 0x1802 | Low |
| Pebblebee trackers | Find My compatible, specific data pattern | Low |
| Samsung SmartTag 2 | Samsung ID 0x0075, specific data bytes | Medium |
| Fitbit / wearables | Fitbit manufacturer ID, device name "Fitbit" | Low |
| Police body cameras (Axon) | Research needed — BLE for evidence upload | High |
| Tesla vehicles | BLE for phone key, Tesla manufacturer ID | Medium |
| Bluetooth headphones | Service UUID 0x110B (A2DP), ignored unless suspicious pattern | Skip |
| Unknown devices with strong RSSI | Log to CSV for later analysis | Utility |

**Implementation:**

1. Build a BLE signature table in main.zig. Each entry:
   ```zig
   const BleSignature = struct {
       company_id: ?u16,        // manufacturer company ID
       service_uuids: []const u16,  // 16-bit service UUIDs to match
       name_pattern: []const u8,    // device name substring
       class: ThreatClass,
       base_score: u8,
   };
   ```

2. In the BLE poll loop, iterate the signature table. First match wins.

3. Log unmatched devices with strong RSSI (> -60 dBm) to CSV as "UNKNOWN"
   for later analysis. After a week, review the CSV — patterns emerge.

**Verification:** Carry the device for a day. Review the CSV. Every unknown
MAC with consistent RSSI is something stationary — a camera, a sensor, a beacon.
Look up the OUI online and add it to the database.

---

## 7. False Positive Reduction (ongoing, 1-2 hours/week)

**What:** Any detection system generates noise. A random Murata WiFi module
with the same OUI as a Flock camera triggers an alert. A phone with Find My
enabled looks like an AirTag. Reducing false positives is the difference
between a useful device and an annoying one.

**Methods:**

1. **RSSI trend analysis (already partially implemented).**
   A stationary camera produces a rise-peak-fall RSSI pattern as you walk past.
   A phone in someone's pocket produces a sudden appearance and disappearance.
   Tune the `RssiTrend` thresholds based on real walk-test data.

2. **Time-window re-detection.**
   A Flock camera is fixed in place. If you see the same MAC from the same
   approximate location 5 minutes apart, it's a fixed installation. If you
   never see it again, it was a passing car. Track MAC + location pairs.

3. **SSID format validation.**
   Flock cameras use the format `Flock-XXXX` where XXXX is hex from the MAC.
   Random devices might have "flock" in the SSID (birdwatching club WiFi).
   The Flock-XXXX hex format validator is already implemented — verify it
   works and assign it the full 65 pts only when the hex digits validate.

4. **BLE address type analysis.**
   Flock batteries use public or random-static BLE addresses (consistent).
   Phones use random-private-resolvable addresses (rotate every 15 minutes).
   If you see the same OUI with a resolvable address, it's a phone, not a camera.
   Add BLE address type to the scoring: public/static = +10 pts, resolvable = -20 pts.

5. **Confidence floor.**
   Don't alert below 40 pts (MEDIUM). Don't show below 25 pts on the OLED.
   These thresholds should be configurable in a `config` section at the top
   of main.zig.

6. **Weekly log review.**
   Dump the CSV via long-press. Review every detection above 40 pts.
   Classify as true positive or false positive. Adjust scoring weights.
   After 4 weeks of real-world data, the scoring weights will be tuned
   to your actual environment.

---

## 8. Cellular IMSI Catcher Detection (research phase, 4-8 hours)

**What:** Stingray/IMSI catchers impersonate cell towers to intercept phone
traffic. They're used by law enforcement and, increasingly, by commercial
entities (mall analytics, convention tracking).

**Detection approach:**
The ESP32-S3 has no cellular modem, so direct IMSI catcher detection is
impossible. But there are indirect signatures:

- **WiFi probe requests for carrier SSIDs.** Phones probe for known networks.
  AT&T phones probe for `attwifi`. If you see a sudden spike in `attwifi`
  probe requests from different MACs in the same location, a Stingray may
  have kicked them all off the cellular network simultaneously.

- **Sudden drop in 4G/5G signal (if GPS + cell modem added).** Not feasible
  on current hardware, but worth noting for a future build with a cellular
  modem add-on.

**Status:** Research phase. Don't implement yet. Collect probe request data
and look for patterns. If you see clear signatures, add a `STINGRAY?` alert
with appropriate caveats.

---

## 9. Database Maintenance (ongoing)

**Add OUIs as you discover them:**

1. Find a new surveillance OUI (from research, field data, community reports)
2. Add to `src/ouis.txt` — one line, `XX:XX:XX`
3. Rebuild: `./build-zig.sh && idf.py build && idf.py flash`
4. The OUI is baked into the binary at compile time via `@embedFile` + comptime

**Sources for new OUIs:**
- [IEEE OUI lookup](https://regauth.standards.ieee.org/standards-ra-web/pub/view.html#registries) — search by company name
- [DeFlock.me](https://deflock.me) — community ALPR location data with OUIs
- [Wigle.net](https://wigle.net) — wardriving database, search for SSIDs containing "Flock", "Raven", etc.
- MAC address lookups from your own CSV logs

**When to add a new threat class:**
- A detection type has different implications than existing classes
- It appears frequently enough to deserve its own display line
- The user would want to filter on it separately

Current threat classes: `ALPR`, `GUNSHOT`, `DRONE`, `TRACKER`, `CAMERA`.
Add a class when you have at least 3 distinct OUI/signature entries and
the class is surveillance-relevant (not just any consumer device).

---

## Priority Order

```
✅ 1. WiFi camera OUIs (§5)          1-2 hours    Done — 15 OUIs + CAMERA class + SSID keywords
✅ 2. Raven gunshot detectors (§1)   2-3 hours    Done — 8 UUIDs + FW classification
✅ 3. Drone Remote ID — WiFi (§2)    4-6 hours    Done — tag 221 IE parsing
✅ 4. Ring/Sidewalk (§4)             2-3 hours    Done — manufacturer 0x0171 check
✅ 5. Drone Remote ID — BLE (§3)     2-3 hours    Done — UUID 0xFFFA + OUI matching
⬜ 6. BLE deep parsing (§6)          3-4 hours    ✅ Done — BLE_SIGNATURES table: Chipolo, Fitbit, Tesla, Axon (placeholder)
⬜ 7. False positive reduction (§7)  Ongoing     ✅ Done — BLE penalty, SSID hex validation, thresholds configured
⬜ 8. IMSI catcher (§8)              Research    ✅ Done — carrier SSID probe counter (attwifi, VerizonWiFi, etc.)
```

Each section is independent — do them in any order based on what hardware
and environment you have access to (drones need a park, Raven needs a big
city, cameras are everywhere).
