# T-Deck Expansion Exploration

Author: Hermes  
Date: 2026-06-23  
Status: analysis — no code written  

## What's already built

The T-Deck hardware drivers are done and known-working:

| Subsystem | Driver | Status |
|-----------|--------|--------|
| Keyboard | `main/keyboard.c` — I2C slave MCU at 0x55, returns ASCII per keypress | Built, init succeeds |
| Speaker | `main/speaker.c` — MAX98357A I2S0, square-wave tone synthesis | Built, init succeeds |
| SD card | `main/sdcard.c` — FATFS over shared SPI2, mounted at `/sdcard` | Built, init succeeds |
| Display | ST7789 320×240 16-bit color | 7 views, keys 1-7 + trackball |
| Input | `src/boards/tdeck.zig:118-162` — keyboard + trackball polled per main loop | Working |

The input handler currently maps:
- Keys `1`-`7` → jump to page (Dashboard through System)
- Key `d`/`D` → CSV dump to serial
- Trackball up/down → prev/next page
- Center-click → stealth toggle

## 1. On-device labeling

**What:** Walk through a neighborhood, tap a key to tag each detection by category or threat level. The T-Deck becomes a ground-truth survey tool — no laptop, no phone, no cloud. All tags saved to SD card as structured CSV.

**How it works now:** The display shows detections as passive lists. No interaction with individual entries beyond viewing them.

**What to build:**

### 1A. Label mode toggle

A dedicated key (e.g., `l` or `8`) enters "label mode." In this mode, the Detection view (page 1, Surveillance) and Devices view (page 5) become interactive:

- Highlight/selection cursor on the current row
- Trackball up/down moves cursor between rows
- Number keys apply a tag to the selected entry
- Tag is immediately visible on-screen and written to SD

### 1B. Tag taxonomy

A minimal tag set that covers the surveillance mapping use case:

| Key | Tag | Meaning |
|-----|-----|---------|
| `1` | CONF | Confirmed surveillance device (verified visually) |
| `2` | FALSE | False positive (not surveillance — e.g., a router that shares an OUI) |
| `3` | UNKN | Unknown/unverified (tag to revisit) |
| `4` | MUNI | Municipal/government infrastructure (ALPR, ShotSpotter, city camera) |
| `5` | PRIV | Private/commercial (Ring doorbell, store camera) |
| `0` | Clear tag |

### 1C. Storage format

Tags written to `/sdcard/tags.csv`:

```
unix_time_ms,mac,oui,kind,score,rssi,lat,lon,tag
1719177600123,AABBCCDDEEFF,Flock,flock_camera,85,-42,38117300,-90199400,CONF
1719177620456,112233445566,Samsng,samsung,70,-55,38117300,-90199400,FALSE
```

One line per tag event. Append-only. Survives reboot. The MAC+kind+position provides everything needed to build a surveillance map later.

### 1D. Data volume estimate

A one-hour walk through a dense commercial district with ~100 unique detections tagged at ~20 bytes per row is about 2KB. A 32GB microSD holds millions of tagged detections — effectively unlimited.

### 1E. SD card interaction

`sd_append_line()` already exists in `sdcard.c`. Need a Zig-side extern:

```zig
pub extern fn sd_append_line(path: [*]const u8, line: [*]const u8) i32;
```

The Zig labeling code would format a CSV line and call this.

### 1F. UI approach

Two options:

**Minimal:** Overlay a one-line tag indicator on the existing Surveillance/Devices views. Selection is just a highlight on the row. Tag keypress immediately updates the display. No new view page needed. Uses existing 7-page layout.

**Full:** New "Label" view (page 8) with a scrollable list showing all recent detections, their current tags, and a small status bar at the bottom showing the active tag set. Trackball scrolls, keyboard tags.

The minimal approach is lower risk and keeps within the existing architecture. Can always graduate to a full view later.

## 2. Active alerting with the speaker

**What:** The speaker already plays tones via `spk_tone(freq, ms, vol)`. Currently used only for startup chime and threat-tier beeps (low/medium/high/critical). Expand to:

- **Per-type tone signatures** — drone gets a different tone than raven, Flock different than camera. You hear what's nearby before looking at the screen.
- **Rising urgency** — same threat type at score 40 is a low beep. At score 85 it's a rapid warble.
- **Stingray siren** — continuous alarm pattern when stingray detection is active.

**What already exists:**

```c
// tdeck.zig:98-113 — called from main loop on rising threat tier
pub fn alert(score: u8) void {
    if (score >= scanner.SCORE_CERT) {
        // triple beep 1568Hz
    } else if (score >= scanner.SCORE_HIGH) {
        // double beep 1175Hz
    } else if (score >= scanner.SCORE_MED) {
        // single beep 880Hz
    }
}
```

This only triggers on tier change, not per-detection.

**What to build:**

### 2A. Per-kind tone map

| Kind | Base frequency | Character |
|------|---------------|-----------|
| `.flock_camera` | 2000 Hz | Sharp, urgent — ALPR is active scanning |
| `.drone` | 1200 Hz | Mid-high — drone overhead, look up |
| `.raven` | 800 Hz | Low, rumbling — acoustic sensor grid |
| `.camera` | 1600 Hz | Standard alert |
| `.airtag/.tile/.samsung/.findmy` | 600 Hz | Low tracking tone |
| `.stingray` | 2200 Hz pulsing | Highest urgency |

### 2B. Score-to-pattern mapping

| Score | Pattern |
|-------|---------|
| ≥ CERT (85) | Rapid 3-pulse, 100ms on, 50ms off, repeat 3x |
| ≥ HIGH (70) | Double beep, 100ms each, 60ms gap |
| ≥ MED (40) | Single 120ms beep |
| < MED | Silent (don't alert on background noise) |

### 2C. Rate limiting

Don't beep on every raw detection — that's hundreds per minute. Only alert when:
- A new detection enters the table (first sighting)
- Score crosses a threshold (was LOW, now MED)
- Stingray alert activates

Heartbeat and known-revisit detections are silent. This keeps the speaker useful rather than annoying.

### 2D. Implementation approach

Add to the main loop's detection processing: after `trackDevice()` returns `true` (new entry), check the score, compute tone, call `board.alert(score)` with an additional `kind` parameter or a separate `board.alertKind(kind, score)` function. The tdeck.zig alert function already exists and can be extended with the tone map. Heltec's alert is a no-op (no speaker) so no change needed there.

### 2E. Stealth mode consideration

In stealth mode, the speaker is silent — same as the LED. `spk_tone()` is blocking, so the alert function should check `main.stealth_mode` before firing. Already handled: the existing `alert()` is called from the main loop which gates on `!stealth_mode`.

## 3. Base station mode

**What:** Leave a T-Deck plugged in at home (USB-C power, no battery concerns). It runs 24/7 as the mesh aggregation point. All mobile Heltecs relay detections via LoRa; the T-Deck logs everything to SD and serves a richer web dashboard with historical data.

**What already exists:**

- SD card write (`sd_append_line`) for append-only CSV
- Web dashboard (`web/dashboard.html`) served over WiFi in base role
- `/api/cameras`, `/api/status`, `/api/detections`, `/api/mesh` endpoints
- LoRa mesh: heartbeats + detection relay between units

**What to build:**

### 3A. Continuous SD card logging

Every detection that enters the tracker table (local or mesh-relayed) gets logged to `/sdcard/detections.csv`:

```
unix_time_ms,mac,oui,kind,score,rssi,source,lat,lon
```

This is already partially done — `scanner.logCsv()` writes to SPIFFS via serial. The SD path just changes the destination. A ring buffer in RAM (e.g., 4KB) accumulates lines; the SD write happens every N lines or every M seconds to avoid SD card wear from per-detection writes.

### 3B. Historical API endpoint

A new `/api/history?from=...&to=...&kind=...` endpoint that reads from the SD card CSV and returns matching rows as JSON. Allows the web dashboard to show "last 24 hours," "last week," "all time" views.

Constraints:
- SD card read over SPI is slow (~1-2 MB/s)
- FATFS `fseek()` + `fread()` works but scanning a 10MB CSV takes seconds
- Solution: index file (`/sdcard/detections.idx`) that stores byte offsets for each hour. Reader seeks to the right position and streams from there.

### 3C. Richer web dashboard

The dashboard currently shows live data only — what's in the tracker table right now. Add:

- **Timeline view** — bar chart of detections per hour, color-coded by kind
- **Export** — download any date range as CSV (already have `/api/export/csv` for SPIFFS, extend to SD)
- **Camera heatmap** — Leaflet heatmap layer of all camera positions seen in the last week
- **Peer list** — which mobile units are currently online, last heard, battery level (already in `/api/mesh`)

### 3D. Base vs mobile distinction

The device already has `config_role_is_base()` — when set to base role:
- WiFi connects to home network (STA mode, not AP)
- HTTP server serves dashboard on the LAN
- LoRa stays in continuous RX (never transmits detections, only heartbeats)
- SD card logging is always-on

When mobile:
- WiFi channel-hops passively (promiscuous sniffer)
- LoRa transmits detections ≥ SCORE_MED
- BLE phone stream is active
- SD card logging is optional (battery life concern)

The T-Deck makes a better base station than the Heltec because of SD card storage, richer display for at-a-glance monitoring, and speaker for audible alerts on new threats.

## 4. On-device settings

**What:** Type WiFi credentials, device name, role, GPS coords directly on the T-Deck keyboard. No setup webpage. No phone. The device is self-contained.

**What already exists:**

- `web/setup.html` — captive portal served over AP on first boot. User joins "Argus Setup" WiFi and types config in a browser.
- `main/config.c` — reads/writes JSON config to `/spiffs/config.json`. Fields: name, role, ssid, password, lat, lon.
- `src/config.zig` — Zig wrapper for the C config.

**What to build:**

### 4A. Setup mode on the keyboard

On first boot (no config found), instead of the captive portal, the T-Deck shows a keyboard-driven setup flow on the color display:

1. **Device name** — type a name, Enter to confirm
2. **Role** — press `1` for mobile, `2` for base
3. **WiFi SSID** — type SSID
4. **WiFi password** — type password (masked with `*` on screen)
5. **Location** — enter lat/lon manually, or `g` to use GPS if available

Each step shows the current input buffer and a prompt. Backspace to correct. Enter to advance. Escape to go back.

### 4B. Settings editor for existing config

Once configured, a "Settings" view (new page 8) shows current values and allows editing individual fields without resetting everything. Key `s` jumps to settings. Key `8` could also map here (the current page count is 7, and the keyboard supports at least 10 number keys + letters).

### 4C. Implementation approach

Two files:
- `src/settings.zig` — display rendering + input handling for the settings UI
- Extend `src/boards/tdeck.zig` input handler to route keypresses to settings mode when active

The current `initSetup()` function in tdeck.zig calls `drawSetup()` which shows the captive portal instructions. Replace with a keyboard-driven setup flow.

### 4D. Password input

Keyboard input for passwords: each keypress appends to a buffer, display shows `*` for each character. Backspace (the T-Deck keyboard likely has one) removes last character. Enter commits.

### 4E. Fallback to web setup

Keep the captive portal as a fallback. If the user holds a key (like `w`) during boot, fall back to web setup. Or add a "Web Setup" option on the settings screen that restarts the AP. This way both paths exist and nothing is lost.

## 5. Detection playback

**What:** Scroll through the last N hours of detections on the color screen. Filter by type. Sort by score or time. The Heltec's 128×64 OLED can only show a snapshot of 3-4 entries. The T-Deck's 320×240 screen can show 8-10 rows with rich detail.

**What already exists:**

- Tracker table (`src/main.zig:407`): `[MAX_TRACKERS]TrackerEntry` — live data only, no history
- SPIFFS CSV log via serial dump (not random-access)
- SD card append-only CSV on T-Deck

**What to build:**

### 5A. In-memory history ring buffer

A separate ring buffer in RAM that stores the last ~200 detection entries as they arrive. Each entry is a compact struct (~32 bytes):

```zig
const HistoryEntry = struct {
    mac: [6]u8,
    kind: display.TrackerType,
    rssi: i8,
    score: u8,
    time_ms: u32,
    tag: u8,  // user-applied tag (from labeling), 0 = none
};
```

200 entries × 16 bytes = 3.2KB. Negligible. The buffer wraps; oldest entries fall off.

### 5B. Filtered/sorted view

New view (page 9): "History." Shows the ring buffer entries with:

- **Filter keys**: `f` = Flock, `d` = drone, `r` = raven, `c` = camera, `t` = tracker, `a` = all
- **Sort toggle**: key `s` cycles sort by time (newest first, default) or score (highest first)
- **Trackball**: scroll through entries
- **Keyboard `0`-`9`**: jump to decile of the list

The view shows 8 rows with:
```
HH:MM  KIND  OUI   RSSI  SCORE  TAG
14:23  FLOCK F9:AB  -42   85    CONF
14:22  DRONE 3C:12  -55   70
14:18  CAM   8A:7B  -61   55    PRIV
```

### 5C. Scrollable list

The T-Deck trackball provides up/down for free (already used for page navigation). In the History view, up/down scrolls the list instead. A scrollbar on the right edge shows position.

### 5D. SD card as backing store

Eventually the ring buffer won't be enough (200 entries = ~10 minutes in a dense area). The SD card CSV provides the backing store. The history view can load older entries from SD on demand ("load more" at the bottom, or automatic load when scrolling past the ring buffer's oldest entry). This is a phase-2 optimization — ring buffer alone is enough for v1.

## 6. Manual override (reclassification)

**What:** The classifier gets it wrong sometimes — calls a drone a generic WiFi device, or flags a router as a camera. Hit a key to reclassify. The correction feeds back into future classifications.

**What already exists:**

- `scanner.classifyWiFi()` and `scanner.classifyBLE()` — heuristic classifiers
- `trackDevice()` — upserts detection with kind from classifier result
- `display.TrackerType` — enum of all kinds
- `main.trackers[i].kind` — mutable after creation

**What to build:**

### 6A. Override UI

In labeling mode (from direction 1), add reclassification keys:

| Key | Action |
|-----|--------|
| `shift+1` | Override to `.flock_camera` |
| `shift+2` | Override to `.drone` |
| `shift+3` | Override to `.raven` |
| `shift+4` | Override to `.camera` |
| `shift+5` | Override to `.wifi_device` |
| `shift+0` | Clear override (revert to classifier result) |

The T-Deck keyboard doesn't have a shift key in the traditional sense — but each keypress returns ASCII. Capital letters vs lowercase could serve as the shift signal: `1` = tag, `!` = reclassify. Or use a dedicated key like `r` to enter "reclassify mode" followed by a number.

### 6B. Override storage

Two layers:

1. **Volatile override** — the `TrackerEntry.kind` is changed immediately. This affects the current session: display, alerts, mesh broadcasts. The entry now behaves as the corrected type.

2. **Persistent override list** — written to `/sdcard/overrides.csv`:
```
mac,original_kind,override_kind
AABBCCDDEEFF,wifi_device,flock_camera
112233445566,camera,wifi_device
```

### 6C. Feedback loop

On boot, load the override list from SD into a comptime-accessible or runtime lookup. When `classifyWiFi()` or `classifyBLE()` returns a result, check the override list before accepting the classification. If the MAC is in the overrides, use the corrected kind.

Implementation: a hash map of MAC → kind, stored in a small fixed buffer (~64 entries). On classifier output:

```zig
if (overrideMap.get(mac)) |corrected_kind| {
    result.kind = corrected_kind;
}
```

This means the device learns. A camera misclassified as generic WiFi gets corrected once, and every subsequent sighting uses the correct kind.

### 6D. Risk

Manual overrides are permanent until cleared. A user could mis-tag a benign device as a threat and get persistent false alerts. Mitigation:
- "Clear overrides" option in settings
- Override list is human-readable CSV — can be edited on a computer
- Display shows a small `[OVR]` marker on overridden entries so the user knows the kind is manual

## Prioritization

Not all six need to be built at once. Order by what unlocks the most capability with the least new code:

| Order | Direction | New code | Builds on | Unlocks |
|--------|-----------|----------|-----------|---------|
| 1 | Active alerting | ~40 lines Zig | Existing speaker driver, alert function | Immediate: you hear threats without looking |
| 2 | On-device labeling | ~150 lines Zig, ~20 lines C | Existing SD card driver, keyboard, display | Ground-truth mapping, no laptop needed |
| 3 | Detection playback | ~120 lines Zig | History ring buffer, existing display views | Scroll through past detections on-device |
| 4 | Manual override | ~80 lines Zig | Labeling, override storage | Fixes classifier mistakes permanently |
| 5 | On-device settings | ~200 lines Zig | Keyboard input, config system | Self-contained setup, no phone/browser |
| 6 | Base station mode | ~200 lines C/Zig, HTML | SD card, web dashboard, LoRa mesh | 24/7 logging, richer dashboard |

Active alerting is first because the speaker driver already works, the `alert()` function already exists and is called from the main loop, and it requires zero new infrastructure. It's a tone-map inside an existing function.

Labeling is second because SD card writes already work, the keyboard already works, and tags are just CSV lines. It gives the device a capability no phone app or web dashboard can match: one-handed, eyes-up tagging while walking.

## Open questions

1. **Keyboard layout** — the T-Deck has a full QWERTY keyboard. Is the top row numeric? What's the full key map? The I2C slave MCU returns ASCII, but the exact mapping depends on the keyboard firmware. Need to document which physical keys produce which ASCII codes.

2. **SD card reliability** — `esp_vfs_fat_sdspi_mount` uses SPI mode (not SDMMC). SPI mode SD cards are slower and some cards refuse to initialize. What cards have been tested?

3. **Speaker volume** — `spk_tone()` uses volume 0-100, mapped to ±9000 amplitude. What's the actual loudness in a pocket vs outdoors? Might need a higher default volume for outdoor use.

4. **Page budget** — currently 7 views (0-6), keys 1-7. Adding History (8), Settings (9), and Label (10) pushes to 10 views. Keys `1`-`0` can map to views 1-10. Trackball still handles prev/next. No architectural issue, just a UI convention to settle.
