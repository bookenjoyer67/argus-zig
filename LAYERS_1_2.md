# Onboarding & Web Dashboard — Implementation Plan

Layers 1 and 2 from the product roadmap. Self-contained, buildable in order.
Each section is a working milestone.

---

## Layer 1: Onboarding (First Boot + Captive Portal)

### Goal

A new device boots into setup mode. User connects phone to "Argus Setup" WiFi,
picks a device name, chooses mobile/base station role, and optionally enters
home WiFi credentials. Settings persist to SPIFFS. After setup, device reboots
into normal operation.

### What exists already

- SPIFFS read/write (`spiffs_read_file`, `spiffs_write_file` in `main/spiffs.c`)
- WiFi AP mode (ESP-IDF `esp_wifi` is already initialized in `main/wifi.c`)
- OLED display
- Button input

### What to build

#### 1.1 Settings storage (`src/config.zig` — new file)

Settings stored as JSON on SPIFFS at `/spiffs/config.json`:

```json
{
  "device_name": "Kitchen",
  "role": "base",
  "wifi_ssid": "",
  "wifi_pass": "",
  "configured": false
}
```

**Implementation:**

```zig
pub const DeviceRole = enum { mobile, base };

pub const Config = struct {
    device_name: [32]u8 = undefined,
    role: DeviceRole = .mobile,
    wifi_ssid: [32]u8 = undefined,
    wifi_pass: [64]u8 = undefined,
    configured: bool = false,
};
```

- `configLoad()` — read from SPIFFS, parse JSON, populate Config struct
- `configSave()` — serialize Config to JSON string, write to SPIFFS
- `configIsConfigured()` — check if `configured == true`

**Dependencies:** SPIFFS must be mounted before calling these. The `spiffs_init_storage()` call in `app_main()` already handles this.

#### 1.2 Captive portal WiFi AP (`main/wifi.c` — add functions)

Two new C functions in wifi.c:

```c
// Start WiFi in AP mode for setup (no password, open network)
int wifi_ap_start(const char *ssid);

// Stop AP mode and return to station-only (for promiscuous sniffer)
int wifi_ap_stop(void);
```

**Implementation notes:**
- Use `esp_wifi_set_mode(WIFI_MODE_AP)` instead of `WIFI_MODE_STA`
- Configure AP with `wifi_config_t.ap.ssid = "Argus Setup"`, no password, channel 1
- The existing `esp_netif_create_default_wifi_ap()` handles the IP stack
- DHCP server assigns addresses in 192.168.4.x range
- After setup completes, call `wifi_ap_stop()` then re-init as station for promiscuous

#### 1.3 HTTP server for captive portal (`main/httpd.c` — new file)

ESP-IDF's `esp_http_server` component. Two endpoints:

**`GET /`** — serves the setup HTML page (single string, ~2KB).

**`POST /api/setup`** — receives JSON form data, saves config, returns `{"ok": true}`.

```c
#include "esp_http_server.h"

// Start HTTP server on port 80
int httpd_start(void);

// Stop the server
void httpd_stop(void);
```

**Setup HTML page** (embedded as a C string):

```html
<!DOCTYPE html>
<html>
<head>
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Argus Setup</title>
  <style>
    body { font-family: system-ui; background: #0a0a1a; color: #e0e0e0;
           max-width: 400px; margin: 2rem auto; padding: 1rem; }
    h1 { color: #ff1493; }
    label { display: block; margin: 1rem 0 0.25rem; }
    input, select { width: 100%; padding: 0.5rem; background: #1a1a2e;
                    color: #fff; border: 1px solid #ff1493; border-radius: 4px; }
    button { margin-top: 1.5rem; padding: 0.75rem 2rem;
             background: #ff1493; color: #fff; border: none; border-radius: 4px;
             font-size: 1rem; cursor: pointer; }
    .note { font-size: 0.8rem; color: #888; margin-top: 0.25rem; }
  </style>
</head>
<body>
  <h1>Argus Setup</h1>
  <form id="setup">
    <label>Device Name</label>
    <input name="name" placeholder="Kitchen" required>
    <div class="note">Shown on OLED and mesh network</div>

    <label>Role</label>
    <select name="role">
      <option value="mobile">Mobile (pocket, battery powered)</option>
      <option value="base">Base Station (home, plugged in, web dashboard)</option>
    </select>

    <label>WiFi Network (base station only)</label>
    <input name="wifi_ssid" placeholder="MyHomeWiFi">
    <input name="wifi_pass" type="password" placeholder="Password">

    <button type="submit">Save & Start</button>
  </form>
  <script>
    document.getElementById('setup').onsubmit = async (e) => {
      e.preventDefault();
      const form = new FormData(e.target);
      const data = Object.fromEntries(form);
      const res = await fetch('/api/setup', {
        method: 'POST',
        headers: {'Content-Type': 'application/json'},
        body: JSON.stringify(data)
      });
      if (res.ok) {
        document.body.innerHTML = '<h1>✓ Saved!</h1><p>Rebooting...<br>Reconnect to your device in a moment.</p>';
      }
    };
  </script>
</body>
</html>
```

**POST handler** (in httpd.c):

```c
static esp_err_t setup_handler(httpd_req_t *req) {
    char buf[512];
    int len = httpd_req_recv(req, buf, sizeof(buf) - 1);
    if (len <= 0) return ESP_FAIL;
    buf[len] = '\0';

    // Parse JSON, save to SPIFFS
    config_save_json(buf);

    // Respond
    const char *resp = "{\"ok\":true}";
    httpd_resp_set_type(req, "application/json");
    httpd_resp_send(req, resp, strlen(resp));

    // Schedule reboot after response is sent
    // (use a FreeRTOS timer or task to delay 500ms then esp_restart())

    return ESP_OK;
}
```

**DNS redirect for captive portal:** Most phones check for a captive portal by requesting a known URL. To intercept this:

1. Start a DNS server on port 53 (ESP-IDF has no built-in DNS server — use a minimal UDP listener that responds with the AP's IP for all queries)
2. Alternatively: ESP-IDF example `protocols/http_server/captive_portal` shows the pattern

For a v1, skip the DNS redirect and just tell the user "connect to Argus Setup WiFi, then open 192.168.4.1 in your browser." The captive portal auto-detection is nice-to-have, not required.

#### 1.4 Setup mode orchestration (modify `main/main.c` and `src/main.zig`)

**In `app_main()`:**

```c
void app_main(void) {
    nvs_flash_init(); // (existing)
    spiffs_init_storage(); // (existing)

    if (!config_is_configured()) {
        // First boot — enter setup mode
        printf("Argus: First boot — entering setup mode\n");
        wifi_ap_start("Argus Setup");
        httpd_start();
        // zig_main_setup() — runs OLED setup screen, waits for config
        zig_main_setup();
        // zig_main_setup returns after config saved
        httpd_stop();
        wifi_ap_stop();
        esp_restart(); // reboot into normal mode
    }

    // Normal boot
    printf("Argus: Normal boot — %s mode\n", config_get_role() == ROLE_BASE ? "base" : "mobile");
    if (config_get_role() == ROLE_BASE) {
        wifi_connect_sta(config_get_ssid(), config_get_pass());
        httpd_start(); // serve web dashboard
    }
    ble_scan_init();
    wifi_scan_init(); // promiscuous sniffer
    lora_init();
    gps_init();
    zig_main();
}
```

**In `src/main.zig`:**

Add `export fn zig_main_setup() callconv(.c) void` — shows "ARGUS SETUP / Connect to WiFi: / Argus Setup / Then open 192.168.4.1" on OLED. Loops until config is saved (checks `configIsConfigured()` each iteration). When done, returns to C for reboot.

#### 1.5 CMake changes

Add to `main/CMakeLists.txt`:
```
SRCS "main.c" "wifi.c" "ble.c" "spiffs.c" "lora.c" "gps.c" "httpd.c" "config.c"
REQUIRES ... esp_http_server
```

Add `config.c` — SPIFFS-based JSON config read/write.

---

## Layer 2: Web Dashboard (Base Station Mode)

### Goal

When the device is configured as a base station, it connects to home WiFi
and serves a live web dashboard. Any device on the same network can open
the dashboard in a browser.

### Pages

| Route | Content |
|-------|---------|
| `GET /` | Dashboard HTML (threats + mesh + map) |
| `GET /api/status` | JSON: uptime, battery, mesh peers, threat counts |
| `GET /api/detections` | JSON: last 50 detections with full metadata |
| `GET /api/mesh` | JSON: peer list with last seen and RSSI |
| `GET /api/export/csv` | Plain text: full CSV log from SPIFFS |
| `GET /api/config` | JSON: current config |
| `POST /api/config` | JSON: update config, save to SPIFFS |

### 2.1 API endpoints (extend `main/httpd.c`)

**`/api/status`** — most important endpoint. Polled every 3 seconds by the dashboard.

```json
{
  "uptime_seconds": 48240,
  "battery_mv": 4100,
  "battery_pct": 95,
  "threats": {
    "alpr": 3,
    "drone": 1,
    "tracker": 12,
    "camera": 7,
    "raven": 0
  },
  "mesh_peers": 2,
  "wifi_rssi": -42,
  "total_detections": 847,
  "free_heap_kb": 187,
  "firmware_version": "1.0.0"
}
```

**Implementation:**
- Read tracker table from Zig (via extern fn or shared memory)
- Format JSON string using `snprintf`
- Set content-type to `application/json`

**`/api/detections`** — recent detection history.

```json
[
  {
    "timestamp": "2026-06-21T14:32:17Z",
    "class": "alpr",
    "oui": "70:c9:4e",
    "mac_hash": "a3f2b1",
    "rssi": -58,
    "channel": 6,
    "score": 85,
    "level": "CERTAIN",
    "methods": "oui+ssid_fmt",
    "source": "direct",
    "lat": 38.6270,
    "lon": -90.1994
  }
]
```

**Implementation:**
- Load last 50 lines from `/spiffs/detections.csv`
- Parse each line, format as JSON array
- Or: maintain an in-memory ring buffer of the last 50 detections in Zig, expose via extern fn

**`/api/mesh`** — peer information.

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

### 2.2 Dashboard HTML

Single HTML file, ~15KB gzipped, embedded in the binary. Three panels:

**Panel 1: Threat Grid**

```
┌──────────┬──────────┬──────────┬──────────┬──────────┐
│          │          │          │          │          │
│    3     │    1     │    0     │   12     │    7     │
│   ALPR   │  DRONE   │  RAVEN   │ TRACKER  │  CAMERA  │
│          │          │          │          │          │
└──────────┴──────────┴──────────┴──────────┴──────────┘
```

Each tile:
- Background: green (0), yellow (1-2), red (3+)
- Count in large font
- Label below
- Click tile → scrolls to filtered detection list

**Panel 2: Live Feed**

```
── Latest Detections (auto-refresh 3s) ──
 ALPR  70:c9:4e  -58 dBm  CERTAIN  2m ago  38.6270,-90.1994
 DRONE DJI Mini  -72 dBm  HIGH     5m ago  38.6281,-90.1987
 ALPR  3c:91:80  -63 dBm  HIGH     8m ago  38.6275,-90.2001
```

Rows animate in (slide from top). Newest at top. "2m ago" updates live.
Colors: red for ALPR, orange for camera, blue for drone, green for tracker.

**Panel 3: Mesh Status**

```
── Mesh (2 peers online) ──
 ● UNIT-02  last seen 2m ago  -84 dBm
 ● UNIT-05  last seen 8m ago  -91 dBm
 ○ UNIT-07  last seen 3h ago  (offline)
```

**Bottom bar:**

```
Uptime: 13h 24m  |  Battery: 95%  |  [Export CSV]  [Settings]  [v1.0.0]
```

### 2.3 Dashboard JavaScript

Vanilla JS, no framework. Single `<script>` block in the HTML.

```javascript
// Poll /api/status every 3 seconds
// Poll /api/detections every 10 seconds
// Poll /api/mesh every 30 seconds

async function poll() {
    const status = await fetch('/api/status').then(r => r.json());
    updateThreatGrid(status.threats);
    updateMeshPeers(status.mesh_peers);
    updateBattery(status.battery_pct, status.battery_mv);
    updateUptime(status.uptime_seconds);
}

async function pollDetections() {
    const dets = await fetch('/api/detections').then(r => r.json());
    updateFeed(dets);
}

setInterval(poll, 3000);
setInterval(pollDetections, 10000);
poll(); pollDetections();
```

**Key behaviors:**
- Threat tiles animate when count changes (CSS transition on background-color)
- New detections slide in with a brief highlight (CSS animation, 1s fade)
- Offline peers go grey after 5 minutes without heartbeat
- Export CSV triggers a download via `window.open('/api/export/csv')`
- Settings opens a modal with the same form as the setup page

### 2.4 Dashboard CSS

Dark theme matching the OLED's aesthetic. Colors:

```css
:root {
  --bg:         #0a0a1a;
  --surface:    #1a1a2e;
  --text:       #e0e0e0;
  --accent:     #ff1493;   /* hot pink — matches OLED */
  --alpr:       #ff4444;   /* red */
  --drone:      #4488ff;   /* blue */
  --tracker:    #44ff44;   /* green */
  --camera:     #ff8844;   /* orange */
  --raven:      #ff44ff;   /* purple */
  --green:      #00cc66;
  --yellow:     #ffcc00;
  --red:        #ff3333;
}
```

Font: system-ui (uses device's native font, no download). Monospace for MAC addresses and data.

### 2.5 File structure (new and modified)

```
argus-zig/
├── main/
│   ├── CMakeLists.txt          ← add httpd.c, config.c
│   ├── main.c                  ← add setup mode logic
│   ├── wifi.c                  ← add wifi_ap_start, wifi_ap_stop, wifi_connect_sta
│   ├── httpd.c                 ← NEW: HTTP server, API endpoints, embedded HTML
│   ├── config.c                ← NEW: SPIFFS JSON config read/write
│   └── ... (ble, spiffs, lora, gps — unchanged)
├── src/
│   ├── main.zig                ← add zig_main_setup(), config extern fns
│   ├── config.zig              ← NEW: Config struct, load/save
│   ├── display.zig             ← add setup screen page
│   └── ... (scanner, mesh — unchanged)
└── web/
    └── dashboard.html          ← source HTML (embedded into httpd.c at build time)
```

### 2.6 Build integration

The dashboard HTML should be embedded into the C binary at build time:

**Option A:** `xxd -i web/dashboard.html > main/dashboard_html.h` — converts HTML to a C byte array. Run in build-zig.sh before the idf.py build.

**Option B:** Use Zig's `@embedFile` to embed the HTML directly in the Zig code, then expose it to C via an extern fn that returns a pointer and length.

Option A is simpler and doesn't require cross-language data passing.

### 2.7 WiFi Station Connect (for base station dashboard access)

New function in `main/wifi.c`:

```c
int wifi_connect_sta(const char *ssid, const char *password);
```

This connects the Heltec to a home WiFi network as a station. The base station needs this so other devices on the same network can reach the dashboard. Uses `esp_wifi_set_mode(WIFI_MODE_STA)`, `esp_wifi_set_config()`, `esp_wifi_connect()`.

**Dual-mode operation:** The base station runs WiFi in station-only mode (connected to home router) while the promiscuous sniffer runs in parallel. ESP-IDF supports this — `esp_wifi_set_mode(WIFI_MODE_STA)` and the sniffer callback still works.

Wait — there's a conflict. The promiscuous sniffer needs `WIFI_MODE_STA` and doesn't connect. The web dashboard needs `WIFI_MODE_STA` and does connect. Can they coexist?

Yes. ESP-IDF supports this pattern: connect to an AP AND run promiscuous sniffer simultaneously. The sniffer receives ALL frames on the current channel, including those not addressed to the station. The station connection just adds the ability to send/receive TCP traffic. The sniffer callback is unaffected.

**However**, the sniffer only sees frames on the channel the WiFi radio is tuned to. If connected to a home AP on channel 6, the sniffer only sees channel 6 traffic. The existing channel-hopping logic in the promiscuous sniffer would disconnect from the AP. 

**For the base station**, this is acceptable — the base station is stationary and mostly interested in mesh relay (LoRa) and web dashboard (WiFi STA). The mobile unit does the multi-channel scanning.

**Alternative:** The base station could use a separate ESP32 board connected via UART to handle the dashboard, keeping the Heltec's WiFi radio fully dedicated to promiscuous scanning. But that's overkill for v1.

### 2.8 Implementation order

```
Step 1:  config.c + config.zig      — settings storage, load/save from SPIFFS
Step 2:  wifi_ap_start/stop         — WiFi AP mode for setup
Step 3:  httpd.c basic              — start HTTP server, serve static HTML string
Step 4:  Setup HTML + POST handler  — captive portal page, save config
Step 5:  zig_main_setup()           — OLED setup screen, wait for config
Step 6:  app_main() setup flow      — first-boot detection, reboot cycle
Step 7:  wifi_connect_sta()         — station mode for base station
Step 8:  /api/status endpoint       — live threat counts, battery, uptime
Step 9:  /api/detections endpoint   — recent detection JSON
Step 10: /api/mesh endpoint         — peer list
Step 11: Dashboard HTML complete    — all three panels, CSS, JS polling
Step 12: /api/export/csv            — download CSV
Step 13: /api/config endpoints      — settings page
```

Steps 1-6 = Layer 1 complete. Steps 7-13 = Layer 2 complete.

### 2.9 Verification

**Layer 1 test:**
1. Flash fresh device (no SPIFFS config)
2. OLED shows "ARGUS SETUP / Connect to: Argus Setup / 192.168.4.1"
3. Phone sees "Argus Setup" WiFi network
4. Connect, open 192.168.4.1
5. Fill form, click Save & Start
6. Device reboots
7. OLED shows normal summary screen with chosen device name

**Layer 2 test:**
1. Configure device as base station with home WiFi credentials
2. After reboot, find its IP on your router (or it shows on OLED)
3. Open browser to that IP
4. See threat grid with live counts
5. Detection feed updates when mobile unit reports over LoRa
6. CSV export downloads correctly
7. Settings page saves and persists across reboots

### 2.10 Estimated effort

| Step | Hours |
|------|-------|
| config.c + config.zig | 2 |
| wifi_ap_start/stop | 2 |
| httpd.c basic + setup HTML | 3 |
| zig_main_setup() + app_main flow | 2 |
| wifi_connect_sta | 2 |
| API endpoints (status, detections, mesh) | 4 |
| Dashboard HTML/CSS/JS | 4 |
| CSV export + config endpoints | 2 |
| Testing + edge cases | 3 |
| **Total** | **24 hours** |

Roughly a weekend if focused. A week at casual pace.
