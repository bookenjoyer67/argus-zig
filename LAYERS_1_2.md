# Onboarding & Web Dashboard — Implementation Plan (Revised)

Layers 1 and 2 from the product roadmap. Self-contained, buildable in order.
Revised June 22, 2026 to match current codebase (modules split, SURV/TRACK,
Stingray detection, stealth mode already implemented).

---

## What already exists (do not rebuild)

- Stealth mode — double-press toggle, OLED off, LED dark, scanning continues
- LED PWM threat-level patterns — pulse/blink/strobe/error/stealth
- Boot sequence with LED choreography
- OLED absent handling — headless mode with error code on LED
- SURV/TRACK split on OLED summary page
- 7-page display with 500ms live refresh
- Stingray burst detector — fully built, displays on OLED
- LoRa mesh — send/receive with CRC
- GPS NMEA parser
- SPIFFS CSV logging + serial export

---

## Layer 1: Onboarding (First Boot + Captive Portal)

### Goal

A new device boots into setup mode. User connects phone to "Argus Setup" WiFi,
picks a device name, chooses mobile/base station role, enters home WiFi credentials.
Settings persist to SPIFFS. Reboots into normal operation.

### What's needed

#### 1.1 Settings storage (`src/config.zig` + `main/config.c`)

Stored as JSON on SPIFFS at `/spiffs/config.json`:

```json
{
  "device_name": "Kitchen",
  "role": "base",
  "wifi_ssid": "",
  "wifi_pass": "",
  "configured": false
}
```

`config.zig`: `Config` struct, `configLoad()`, `configSave()`, `configIsConfigured()`.
`config.c`: SPIFFS JSON read/write using existing `spiffs_read_file`/`spiffs_write_file`.

#### 1.2 WiFi AP mode (`main/wifi.c` — add functions)

```c
int wifi_ap_start(const char *ssid);   // open AP, no password, DHCP on 192.168.4.x
int wifi_ap_stop(void);                // tear down AP
```

Temporarily switches from STA-only promiscuous mode to AP mode.
After setup, tears down and returns to promiscuous scanning.

#### 1.3 HTTP server (`main/httpd.c` — new file)

ESP-IDF `esp_http_server` component. Two endpoints for setup:

- `GET /` — serves setup HTML (embedded string, ~2KB)
- `POST /api/setup` — receives JSON form, saves config, responds `{"ok":true}`, schedules reboot

DNS redirect skipped for v1. User opens `192.168.4.1` manually.

#### 1.4 Setup mode in app_main (`main/main.c`)

First-boot detection:

```c
void app_main(void) {
    nvs_flash_init();
    spiffs_init_storage();

    if (!config_is_configured()) {
        wifi_ap_start("Argus Setup");
        httpd_start();
        zig_main_setup();      // OLED setup screen, blocks until config saved
        httpd_stop();
        wifi_ap_stop();
        esp_restart();
    }

    // Normal boot — existing path
    ble_scan_init();
    wifi_scan_init();
    spiffs_init_storage();
    lora_init();
    gps_init();
    zig_main();
}
```

`zig_main_setup()` in `src/main.zig`: shows setup screen on OLED, loops until config saved, returns to C for reboot.

#### 1.5 CMake additions

```cmake
# main/CMakeLists.txt
SRCS "main.c" "wifi.c" "ble.c" "spiffs.c" "lora.c" "gps.c" "httpd.c" "config.c"
REQUIRES ... esp_http_server
```

---

## Layer 2: Web Dashboard (Base Station Mode)

### Goal

Base station connects to home WiFi, serves live dashboard at its IP.
Any device on the network opens a browser. Three panels + API.

### WiFi station mode (`main/wifi.c`)

```c
int wifi_connect_sta(const char *ssid, const char *password);
```

Connects to home WiFi. Promiscuous sniffer continues running on the same
channel. Acceptable tradeoff — base station priorities are mesh relay (LoRa)
and dashboard (WiFi STA). Mobile unit handles multi-channel scanning.

### API endpoints (extend `main/httpd.c`)

All endpoints return JSON. Content-type `application/json`.

**`GET /api/status`** — polled every 3 seconds.

```json
{
  "uptime_seconds": 48240,
  "battery_mv": 4100,
  "battery_pct": 95,
  "surv_count": 3,
  "track_count": 12,
  "surv_breakdown": {
    "flock_camera": 1,
    "wifi_device": 0,
    "drone": 1,
    "raven": 0,
    "camera": 1
  },
  "track_breakdown": {
    "airtag": 8,
    "tile": 1,
    "samsung": 2,
    "findmy": 1
  },
  "stingray_active": false,
  "mesh_peers": 2,
  "total_detections": 847,
  "threat_level": "clear",
  "firmware_version": "1.0.0"
}
```

`threat_level`: `"clear"` | `"aware"` | `"watched"` | `"targeted"` — same as LED state.

**`GET /api/detections`** — last 50 detections.

```json
[
  {
    "time_ms": 114770,
    "kind": "wifi_device",
    "oui": "F4:6A:DD",
    "mac_hash": "8CFDAF",
    "rssi": -59,
    "score": 50,
    "level": "MED",
    "methods": "oui",
    "source": "direct",
    "lat": 386270000,
    "lon": -901994000
  }
]
```

**`GET /api/mesh`** — peer list.

```json
[
  {
    "id": "UNIT-02",
    "last_seen_seconds": 120,
    "rssi": -84,
    "detections_shared": 47
  }
]
```

**`GET /api/export/csv`** — raw CSV, triggers browser download.
**`GET /api/config`** — current config JSON.
**`POST /api/config`** — update config, save to SPIFFS.

### Dashboard HTML (single file, embedded in binary)

Three panels + bottom bar. Vanilla JS, no framework. Dark theme matching OLED aesthetic.

**Panel 1: Threat Grid**

```
┌──────────┬──────────┬──────────┬──────────┬──────────┬──────────┐
│          │          │          │          │          │          │
│    1     │    1     │    0     │    1     │    8     │ STINGRAY │
│  FLOCK   │  DRONE   │  RAVEN   │  CAMERA  │ TRACKERS │  ACTIVE  │
│          │          │          │          │          │    ●     │
└──────────┴──────────┴──────────┴──────────┴──────────┴──────────┘
```

Tiles: green (0), yellow (1-2), red (3+). Stingray tile is a single indicator
— grey (inactive) or red pulsing (active). Click any tile to filter the feed.

**Panel 2: Live Feed**

```
── Latest Detections ──
 WIF  F4:6A:DD  -59  MED   2m ago  (direct)
 DRN  DJI Mini  -72  HIGH  5m ago  (direct)
 FLK  70:C9:4E  -58  CERT  8m ago  (mesh via UNIT-02)
 AIR  52:C5:1F  -99  MED  12m ago  (direct)
```

Colors: red (flock/wifi), blue (drone), purple (raven), orange (camera),
green (airtag/tile/samsung). Mesh-sourced detections tagged with peer ID.

**Panel 3: Mesh Status**

```
── Mesh (2 peers online) ──
 ● UNIT-02  last seen 2m ago  -84 dBm  47 shared
 ● UNIT-05  last seen 8m ago  -91 dBm  12 shared
 ○ UNIT-07  last seen 3h ago  (offline)
```

**Bottom Bar:**

```
Uptime: 13h 24m  │  Threat: CLEAR  │  [Export CSV]  [Settings]  [v1.0.0]
```

Threat indicator pill: green (CLEAR), yellow (AWARE), orange (WATCHED), red (TARGETED).

### Dashboard JavaScript

```javascript
const POLL_STATUS_MS = 3000;
const POLL_FEED_MS = 10000;
const POLL_MESH_MS = 30000;

async function pollStatus() {
    const s = await fetch('/api/status').then(r => r.json());
    updateGrid(s.surv_breakdown, s.track_breakdown, s.stingray_active);
    updateThreatPill(s.threat_level);
    updateBattery(s.battery_pct);
    updateUptime(s.uptime_seconds);
    updateMeshCount(s.mesh_peers);
}

async function pollFeed() {
    const dets = await fetch('/api/detections').then(r => r.json());
    updateFeed(dets);
}

async function pollMesh() {
    const peers = await fetch('/api/mesh').then(r => r.json());
    updateMeshList(peers);
}

setInterval(pollStatus, POLL_STATUS_MS);
setInterval(pollFeed, POLL_FEED_MS);
setInterval(pollMesh, POLL_MESH_MS);
pollStatus(); pollFeed(); pollMesh();
```

### Dashboard CSS

```css
:root {
  --bg:        #0a0a1a;
  --surface:   #1a1a2e;
  --text:      #e0e0e0;
  --accent:    #ff1493;
  --flock:     #ff4444;
  --drone:     #4488ff;
  --raven:     #ff44ff;
  --camera:    #ff8844;
  --tracker:   #44ff44;
  --stingray:  #ff0000;
  --green:     #00cc66;
  --yellow:    #ffcc00;
  --red:       #ff3333;
}
```

Font: system-ui. Monospace for MACs and data fields.

### File structure

```
argus-zig/
├── main/
│   ├── CMakeLists.txt          ← add httpd.c, config.c, esp_http_server
│   ├── main.c                  ← add setup mode branch
│   ├── wifi.c                  ← add wifi_ap_start, wifi_ap_stop, wifi_connect_sta
│   ├── httpd.c                 ← NEW: HTTP server, API endpoints, embedded HTML
│   ├── config.c                ← NEW: SPIFFS JSON config read/write
│   └── ... (ble, spiffs, lora, gps — unchanged)
├── src/
│   ├── main.zig                ← add zig_main_setup(), config extern fns
│   ├── config.zig              ← NEW: Config struct, load/save
│   ├── display.zig             ← add setup screen
│   └── ... (scanner, mesh — unchanged)
└── web/
    └── dashboard.html          ← source HTML (xxd → dashboard_html.h at build time)
```

### Build integration

`build-zig.sh` runs `xxd -i web/dashboard.html > main/dashboard_html.h` before
the idf.py build. The HTML is a C byte array included by httpd.c.

### Implementation order

```
Step 1:  config.c + config.zig         — settings storage
Step 2:  wifi_ap_start/stop            — WiFi AP mode
Step 3:  httpd.c basic                 — HTTP server + setup HTML
Step 4:  Setup POST handler            — save config, schedule reboot
Step 5:  zig_main_setup()              — OLED setup screen
Step 6:  app_main() setup flow         — first-boot detection
Step 7:  wifi_connect_sta()            — station mode for base
Step 8:  /api/status endpoint          — live counts, breakdown, Stingray, threat level
Step 9:  /api/detections endpoint      — recent detection JSON
Step 10: /api/mesh endpoint            — peer list
Step 11: Dashboard HTML/CSS/JS         — all three panels
Step 12: /api/export/csv               — download
Step 13: /api/config endpoints         — settings page
```

Steps 1-6 = Layer 1 complete (onboarding). Steps 7-13 = Layer 2 complete (dashboard).

### Verification

**Layer 1:** Flash. OLED: "ARGUS SETUP / Connect to: Argus Setup / 192.168.4.1".
Phone connects, form submits, device reboots into normal mode.

**Layer 2:** Configure as base station with WiFi creds. Find IP on router.
Browser: threat grid with live counts. Feed updates as mobile unit reports
over LoRa. CSV export downloads. Settings page persists.

### Estimated effort

| Step | Hours |
|------|-------|
| config.c + config.zig | 2 |
| wifi_ap_start/stop | 2 |
| httpd.c + setup HTML | 3 |
| zig_main_setup() + app_main flow | 2 |
| wifi_connect_sta | 2 |
| API endpoints (status, detections, mesh) | 4 |
| Dashboard HTML/CSS/JS | 4 |
| CSV export + config endpoints | 2 |
| Testing + edge cases | 3 |
| **Total** | **24 hours** |
