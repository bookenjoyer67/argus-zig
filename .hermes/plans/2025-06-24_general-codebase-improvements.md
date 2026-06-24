# General Codebase Improvements

> **For Hermes:** Implement independently. Each task is self-contained and can be done in any order.

**Goal:** Fix memory visibility, stack safety, build reliability, and data integrity issues identified during codebase review. No architectural changes.

---

## Task 1: Fix Memory Comment in `main.zig`

**Objective:** The comment at `main.zig:919-925` claims "No heap usage. Total: ~12 KB RAM." This is wrong. Update it with accurate numbers.

**Files:**
- Modify: `src/main.zig:919-925`

**Change the comment from:**

```zig
/// Memory: all globals use static allocation. No heap usage.
///   trackers:    MAX_TRACKERS * ~40 bytes ≈ 4 KB
///   oled_buf:    1024 bytes
///   FONT_5X7:    ~300 bytes (59 chars * 5)
///   KNOWN_OUIS:  96 * ~30 bytes ≈ 3 KB
///   stack:       ~4KB default FreeRTOS task stack
///   Total:       ~12 KB RAM of 512 KB available
```

**To:**

```zig
/// Memory budget (ESP32-S3FN8: 512 KB SRAM, no PSRAM):
///
///   Static (BSS) — Zig side:
///     trackers[96]        ~4.0 KB
///     history[200]        ~2.8 KB
///     ble_json_buf[8192]   8.0 KB
///     sd_log_buf (Heltec: 0, T-Deck: 4 KB)
///     csv_log_buf[4096]    4.0 KB
///     OUI_DB[96]          ~3.0 KB
///     gfx framebuffer      ~1.0 KB
///     analysis similarity   9.0 KB
///
///   Static (BSS) — C side:
///     WiFi ring[128]      ~22.0 KB (main/wifi.c)
///     BLE ring[64]         ~2.7 KB (main/ble.c)
///
///   Stack: FreeRTOS main task 16 KB (CONFIG_ESP_MAIN_TASK_STACK_SIZE)
///
///   Heap: newlib FILE buffers during fopen/fclose in SPIFFS/SD paths.
///         Batched to ≤2 fopen every 30s after dd8c90a — no fragmentation risk.
///         Internal: ESP-IDF WiFi, NimBLE, lwIP, SPIFFS, HTTP server allocs.
///
///   Total static (Zig + C): ~55-60 KB of 512 KB. ~450 KB remaining for
///   stack + ESP-IDF internal heap + headroom.
```

**Verify:** Build passes. No code change.

---

## Task 2: Move Stack Arrays to Static

**Objective:** `wifi_rid[128]` and `lora_buf[255]` are stack-allocated every main loop iteration. They live simultaneously, contributing ~400 bytes of peak stack pressure. Move them to file-level statics.

**Files:**
- Modify: `src/main.zig`

**Step 1: Move `wifi_rid` to static**

Find the `wifi_rid` declaration in the WiFi polling section (~line 1040):

```zig
var wifi_rid: [128]u8 = undefined;
```

Replace with:

Remove the local declaration from the while-loop scope and add a file-level static near the other static buffers (after the `ble_json_buf` declaration at ~line 760):

```zig
/// WiFi Remote ID payload buffer — static to reduce main-loop stack pressure.
var wifi_rid_buf: [128]u8 = undefined;
```

Then in the WiFi polling section, use `wifi_rid_buf` instead of the local.

**Step 2: Move `lora_buf` to static**

Find the `lora_buf` declaration in the LoRa polling section (~line 1244):

```zig
var lora_buf: [255]u8 = undefined;
```

Add a file-level static:

```zig
/// LoRa receive buffer — static to reduce main-loop stack pressure.
var lora_recv_buf: [255]u8 = undefined;
```

And use it in the LoRa polling section.

**Step 3: Verify**

Build and confirm no stack-related issues. The main loop stack usage drops by ~400 bytes.

**Risks:** None. These buffers are used in a single-threaded cooperative loop with no reentrancy. Moving them to statics is safe.

---

## Task 3: Free Heap Telemetry

**Objective:** Show free heap on the System OLED page (page 6) and expose it via the API so memory exhaustion can be caught before a crash.

**Files:**
- Modify: `main/main.c` (add `esp_get_free_heap_size` wrapper)
- Modify: `src/main.zig` (add extern fn + print in System page)
- Modify: `src/boards/heltec_v3_ui.zig` (System page)
- Modify: `src/boards/tdeck_ui.zig` (System page)
- Modify: `src/api.zig` (add to status)

**Step 1: C wrapper**

Append to `main/main.c`:

```c
#include "esp_heap_caps.h"

int free_heap_kb(void) {
    return (int)(esp_get_free_heap_size() / 1024);
}
```

**Step 2: Zig extern**

Add to `src/main.zig` extern fn block (~line 170):

```zig
pub extern fn free_heap_kb() i32;
```

**Step 3: System page display**

In each board's UI file, find the System page section and add a line showing free heap:

```
Heap:    N KB free
```

On the Heltec 128x64 OLED this goes alongside the existing "Flash: N KB" or "Tracker: N/96" lines on page 6.

**Step 4: API**

Add to `src/api.zig` `zig_api_status()`:

```zig
b.add("\"free_heap_kb\":{d},", .{main.free_heap_kb()});
```

**Step 5: Early warning LED**

In `updateLed()`, if free heap drops below 8KB, flash the LED with a distinctive pattern (three quick blips every 5 seconds) to warn of imminent exhaustion:

```zig
// Heap pressure warning: 3 fast blips every 5s when free heap < 8KB.
if (free_heap_kb() < 8) {
    const p = tick_ms % 5000;
    const on = (p < 30) or (p >= 100 and p < 130) or (p >= 200 and p < 230);
    board.led.set(if (on) 255 else 0);
    return;
}
```

Insert before the stealth mode block in `updateLed()` so it overrides everything (heap exhaustion is the highest-priority alert).

**Step 6: Build**

```bash
./build-zig.sh && idf.py build
```

---

## Task 4: WiFi Ring Buffer Drop Counter Visibility

**Objective:** `wifi_get_dropped_count()` exists in `main/wifi.c` but nothing reads it. Expose it on the System page and API so users know when the sniffer is overloaded.

**Files:**
- Modify: `src/boards/heltec_v3_ui.zig` (System page)
- Modify: `src/boards/tdeck_ui.zig` (System page)
- Modify: `src/api.zig` (add to status)

**Step 1: API**

The extern fn is already declared in `main.zig:155`:

```zig
pub extern fn wifi_get_dropped_count() u32;
```

Add to `zig_api_status()`:

```zig
b.add("\"wifi_dropped\":{d},", .{main.wifi_get_dropped_count()});
```

**Step 2: System page**

Add a line on the System page: `WiFi drop: N`

**Step 3: BLE equivalent (optional)**

`main/ble.c` doesn't have a drop counter. It silently drops when the ring is full. Add one:

In `main/ble.c`, add:

```c
static volatile int ble_ring_dropped = 0;

// In ble_gap_event_cb, when the ring is full:
if (next == ble_ring_read) {
    ble_ring_dropped++;
    return 0;
}
```

```c
int ble_scan_dropped(void) {
    return ble_ring_dropped;
}
```

Declare in Zig and expose on the System page + API.

---

## Task 5: CSV Rotation

**Objective:** `detections.csv` grows until the SPIFFS partition (~4MB) fills up. Add rotation: when the file exceeds 512KB, rename to `detections.1.csv` and start fresh.

**Files:**
- Modify: `main/spiffs.c` (add rotate function)
- Modify: `src/main.zig` (declare extern, call on boot)
- Modify: `src/scanner.zig` (call rotate when file exceeds threshold)

**Step 1: C implementation**

Add to `main/spiffs.c`:

```c
#include <sys/stat.h>

#define CSV_MAX_SIZE (512 * 1024) // 512 KB

int spiffs_csv_rotate(void) {
    struct stat st;
    if (stat("/spiffs/detections.csv", &st) != 0) return 0; // no file yet
    if (st.st_size < CSV_MAX_SIZE) return 0; // not full enough

    // Remove oldest rotation if it exists
    remove("/spiffs/detections.2.csv");
    rename("/spiffs/detections.1.csv", "/spiffs/detections.2.csv");
    rename("/spiffs/detections.csv", "/spiffs/detections.1.csv");
    return 1; // rotated
}
```

**Step 2: Zig extern**

Add to `src/main.zig`:

```zig
pub extern fn spiffs_csv_rotate() i32;
```

**Step 3: Call on boot**

In `zig_main()`, after `scanner.restoreSession()`:

```zig
_ = spiffs_csv_rotate();
```

**Step 4: Call during operation**

In `csvLogTick()`, after flush, check the file size and rotate if needed:

```zig
pub fn csvLogTick(now: u32) void {
    if (csv_log_lines >= CSV_FLUSH_LINES or (now -% csv_last_flush_ms) >= CSV_FLUSH_MS) {
        csvLogFlush();
        _ = main.spiffs_csv_rotate();
        csv_last_flush_ms = now;
    }
}
```

This checks post-flush so the file size stat is accurate.

---

## Task 6: `set -e` in `build-zig.sh`

**Objective:** If Zig compilation fails, `build-zig.sh` currently continues and produces a stale `libargus.a` that `idf.py` silently links. The resulting binary has missing symbols or wrong behavior with no error message.

**Files:**
- Modify: `build-zig.sh`

**Change:** Add `set -e` as the second line of the script (after the shebang):

```bash
#!/bin/bash
set -e
```

That's it. One line. The script now exits on any non-zero return code from Zig.

---

## Task 7: Tracker Table Compaction

**Objective:** `tracker_count` never shrinks, even when devices haven't been seen for hours. Compact the table by removing stale entries (last seen > 30 minutes ago), shifting remaining entries down.

**Files:**
- Modify: `src/main.zig` (add compact function)
- Modify: `src/main.zig` (call periodically in main loop)

**Step 1: Add compact function**

Add after the tracker table section in `src/main.zig`:

```zig
/// Remove tracker entries not seen in COMPACT_STALE_MS.
/// Shifts remaining entries down to keep the table dense.
pub fn compactTrackers() void {
    const COMPACT_STALE_MS: u32 = 30 * 60 * 1000; // 30 minutes
    var write: usize = 0;
    for (0..tracker_count) |read| {
        if ((tick_ms -% trackers[read].last_seen) < COMPACT_STALE_MS) {
            if (write != read) {
                trackers[write] = trackers[read];
            }
            write += 1;
        }
    }
    tracker_count = write;
}
```

**Step 2: Call periodically**

In the main loop, after the deferred write section and before the yield, add:

```zig
// Compact stale tracker entries every 5 minutes.
if (tick_ms % 300000 < 10) compactTrackers();
```

This runs once every ~5 minutes, shifting at most 96 entries. Negligible cost.

---

## Task 8: Dedup Cache Size Bump

**Objective:** The mesh dedup cache is 16 entries with a 5-minute window. With 4+ peer units, a single Flock camera fills 4 slots. Bump to 32.

**Files:**
- Modify: `src/mesh.zig`

**Change:**

```zig
// const DEDUP_CACHE_SIZE = 16; → const DEDUP_CACHE_SIZE = 32;
```

RAM cost: 16 extra `DedupEntry` structs × (1 + 4 + 4) = 144 bytes. Negligible.

---

---

## Task 9: Log Deployment Clusters to CSV

**Objective:** When `analyzeDeployments()` finds a cluster with score ≥ DEPLOY_WARN, append a summary line to the detection CSV. This creates a paper trail — you can walk through known areas, dump the CSV, and see what the scorer thinks about different environments. Without this, thresholds are blind guesses.

**Files:**
- Modify: `src/analysis.zig` (log on cluster detection)
- Modify: `src/scanner.zig` (add `logDeploy()` function or reuse `csvAppend`)

**Step 1: Add deployment CSV logger**

In `src/analysis.zig`, at the end of `analyzeDeployments()`, when a cluster is active and the score exceeds the warn threshold:

```zig
if (best_score >= DEPLOY_WARN and best_idx < clusters.len) {
    logDeployCluster(&clusters[best_idx], best_score);
}
```

**Step 2: Implement `logDeployCluster()`**

```zig
/// Log a deployment cluster summary to the CSV log for post-walk analysis.
fn logDeployCluster(clust: *const Cluster, score: u16) void {
    var line: [120]u8 = undefined;
    const dur_sec = if (clust.count > 0)
        (main.tick_ms -% main.trackers[clust.members[0]].first_seen) / 1000
    else
        0;
    const s = std.fmt.bufPrint(&line,
        "{d},DEPLOY,{d},{d},{d},{d},{d},,,,0",
        .{ main.tick_ms, score, clust.count, clust.surv_count, clust.embedded_count, dur_sec },
    ) catch return;
    scanner.csvLogAppendLine(s); // reuses the batching path
}
```

**Step 3: Expose `csvAppend` as public**

In `src/scanner.zig`, rename or add a public wrapper:

```zig
/// Append a raw line to the CSV log buffer (used by analysis.zig for
/// deployment cluster summaries).
pub fn csvLogAppendLine(line: []const u8) void {
    csvAppend(line);
}
```

**Output format:** A CSV line in the log:
```
12345678,DEPLOY,142,5,2,2,3200,,,0
```
Columns: time_ms, kind=DEPLOY, score, device_count, surv_count, embedded_count, duration_sec, (empty mac/rssi/lat/lon), methods=0.

**Verify:** Walk through a known area, dump CSV, grep for DEPLOY lines.

---

## Task 10: Add Police/Municipal Networking OUI List

**Objective:** Cradlepoint, Sierra Wireless, Pepwave, Digi — LTE routers common in police/surveillance vehicles. Add them to `ouis.txt` under a `commodity` section so they appear as `wifi_device` in the tracker table at OUI-only cap (25). Individually they won't trigger alerts, but they contribute to cluster scores — a cluster with a Cradlepoint AP + a Flock camera is stronger than one without.

**Files:**
- Modify: `src/ouis.txt`

**Step 1: Add a new section**

Append to `src/ouis.txt`:

```
# Police / Municipal Networking Gear (LTE routers, vehicle APs) — commodity
0C:1C:20
00:30:1A
AC:3A:7A
64:64:4B
```

**Step 2: Verify OUIs**

Check each OUI against the IEEE registry or macvendors.com:

| OUI | Vendor | Context |
|-----|--------|---------|
| 0C:1C:20 | Cradlepoint | Vehicle LTE routers, common in police cruisers |
| 00:30:1A | Pepwave / Peplink | Mobile networking, municipal vehicles |
| AC:3A:7A | Sierra Wireless | AirLink mobile routers, public safety |
| 64:64:4B | Digi International | Digi Transport routers, municipal deployments |

**Step 3: Build and verify**

```bash
./build-zig.sh
grep -c ":" src/ouis.txt  # count OUI lines — should be 4 more than before
```

The `comptime` OUI parser picks up the new section automatically. No code changes needed beyond the text file.

---

## Task 11: Deployment Cluster Persistence (Save/Restore on Boot)

**Objective:** When the device reboots, the tracker table is empty and all cluster state is lost. Save the top cluster's MAC hashes to SPIFFS on shutdown (long-press CSV dump) and restore them on boot. If the same MACs reappear within 5 minutes, the cluster inherits its previous duration for the scorer.

**Files:**
- Modify: `src/analysis.zig` (save/restore functions)
- Modify: `src/main.zig` (call restore on boot, save on dump)
- Modify: `main/spiffs.c` (no changes — reuses existing API)

**Step 1: Save function**

```zig
/// Write the top cluster's MAC hashes to SPIFFS for persistence across reboots.
pub fn saveDeployCluster() void {
    if (!deployment_alert_active or deployment_score < DEPLOY_WARN) return;
    // ... build a compact binary format: score(u16) + count(u8) + [mac_hash(u32); count]
    // Write to /spiffs/deploy.dat via spiffs_write_file
}
```

**Step 2: Restore function**

Called after `restoreSession()` in `zig_main()`:

```zig
/// Read persisted cluster data from SPIFFS. If the stored MACs reappear
/// in the tracker table within 5 minutes of boot, bootstrap the cluster
/// with its previous score and duration for continuity.
pub fn restoreDeployCluster() void {
    // Read deploy.dat, store hashes + score in a small static array.
    // When those MACs appear in the tracker table, the next analysis
    // pass will find them already clustered with inherited duration.
}
```

**Step 3: Call sites**

In `zig_main()`:

```zig
scanner.restoreSession();
analysis.restoreDeployCluster();
```

In `dumpCsv()`:

```zig
scanner.csvLogFlush();
analysis.saveDeployCluster();
spiffs_csv_export();
```

**RAM cost:** Small — a few dozen bytes for the persistent cluster state.

**Limitation:** This bridges gaps of minutes (reboots), not days (the MAC hashes may not be seen again in a different location). It's a stopgap until GPS-keyed baselining (v2).

---

## Task 12: Time-of-Day Weighting via GPS Time

**Objective:** Surveillance deployments at 3 AM are more suspicious than at noon. If the T-Deck GPS has a fix, use the NMEA timestamp to derive UTC hour and apply a night multiplier (×2.0 for 10 PM–6 AM). On the Heltec without GPS, skip — time is unknown.

**Files:**
- Modify: `src/scanner.zig` (expose UTC hour from GPS)
- Modify: `src/analysis.zig` (apply multiplier in `scoreCluster()`)

**Step 1: Extract UTC hour from GPS**

NMEA GGA and RMC sentences contain a UTC timestamp field (HHMMSS.SS). The scanner already parses these. Add:

```zig
/// UTC hour of the most recent GPS fix, or null if no fix / no GPS.
pub var gps_utc_hour: ?u5 = null;
```

Set it in `parseNmea()` when a valid RMC sentence is parsed.

**Step 2: Apply multiplier in `scoreCluster()`**

```zig
// Time-of-day multiplier: night deployments are more suspicious.
if (scanner.gps_utc_hour) |hour| {
    if (hour < 6 or hour >= 22) {
        score = score * 2; // 10 PM – 6 AM
    }
}
```

**Step 3: Build**

GPS parsing already works. This is a read-only addition to the scorer.

---

## Task 13: Don't Gate Analysis Behind `tracker_count >= 3`

**Objective:** `formClusters()` currently returns early if `tracker_count < 3`. That's correct for cluster output, but the similarity matrix should still be computed. This warms up the co-movement data so when a third device arrives, the cluster forms immediately on the next pass rather than waiting for another 3-second window.

**Files:**
- Modify: `src/analysis.zig` (`formClusters()`)

**Change:** Remove the early-return guard:

```zig
// REMOVE:
// if (n < CLUSTER_MIN_DEVICES) return &[0]Cluster{};

// KEEP: the similarity matrix is still built for devices that exist.
// The cluster formation loop simply won't produce clusters below min size,
// but the similarity data is warm for when the next device arrives.
```

**Line change:** One line removed in `formClusters()`. The similarity matrix fills regardless, the greedy aggregation naturally produces zero clusters when there are <3 devices.

---

## Task 14: Deployment OLED Page (Optional — Needs 128×64 Space Planning)

**Objective:** A dedicated OLED page showing the top cluster's devices by kind + RSSI, so you can interpret what triggered the alert in the field without dumping CSV. `NUM_PAGES` goes from 8 to 9.

**Files:**
- Modify: `src/boards/heltec_v3_ui.zig` (new page, bump NUM_PAGES)
- Modify: `src/boards/tdeck_ui.zig` (same, more space available)

**Heltec V3 layout (128×64, 6 lines of 5×7 text):**

```
DEPLOY: 142 [HIGH]
FLK F4:6A:DD -62
DRN WiFiRID  -68
BLE static    -60
BLE static    -65
AP  Cradlept  -58
```

Shows the top 5 devices in the cluster with kind + OUI prefix or type + RSSI. Score and severity level on the first line.

**T-Deck layout (320×240 color):** Much more room — can show all cluster devices, duration, and a color-coded severity bar. The color display makes this significantly more useful.

**NUM_PAGES change:** From 8 to 9 on Heltec, from existing count + 1 on T-Deck.

**Fallback:** If no deployment is active, show "No deployment detected" on the page.

---

## Task 15: Build Ground-Truth Dataset (Manual, Not Code)

**Objective:** Walk/drive Argus through known environments, dump the CSV, and record what the clustering engine scored. This calibrates the thresholds against reality instead of the model.

**Procedure:**

1. Flash the firmware with clustering enabled
2. Walk through:
   - A residential neighborhood (expected: 0 clusters, ambient noise only)
   - A downtown commercial area at noon (expected: 0-1 weak clusters from IoT density)
   - A police station parking lot (expected: potentially 1+ clusters from cruiser networking gear)
   - A known Flock camera location (expected: single-device "cluster" should NOT fire — verify consumer penalty works)
3. After each walk, dump CSV: long-press button, capture serial output
4. Grep for DEPLOY lines:
   ```bash
   grep DEPLOY detections.csv
   ```
5. Record in a spreadsheet: location, time, cluster score, device count, surv count, embedded count, duration
6. Adjust thresholds based on findings:
   - If you get false positives in residential areas: raise `DEPLOY_WARN` from 60 to 80
   - If you get nothing near known police infrastructure: lower `DEPLOY_WARN` or adjust per-device scores
   - If consumer clusters fire: tighten `isEmbedded()` duty cycle check or increase consumer penalty

**Deliverable:** `docs/CLUSTERING_FIELD_TEST.md` with per-location findings and threshold calibration notes.

---

## Summary

| # | What | Lines | Impact |
|---|------|-------|--------|
| 1 | Fix memory comment | 0 | Accurate docs for debugging |
| 2 | Stack → static for wifi_rid + lora_buf | ~8 | ~400B stack saved |
| 3 | Free heap telemetry | ~25 | Catch OOM before crash |
| 4 | WiFi/BLE drop counter visibility | ~15 | Know when sniffer overloads |
| 5 | CSV rotation | ~20 | Prevent SPIFFS fill-up |
| 6 | `set -e` in build script | 1 | Catch Zig errors silently |
| 7 | Tracker table compaction | ~20 | Keep table clean, faster analysis |
| 8 | Dedup cache 16→32 | 1 | Better mesh relay dedup |
| 9 | Log clusters to CSV | ~25 | Ground truth for threshold tuning |
| 10 | Police OUI list | 4 lines | Cradlepoint/Sierra/Pepwave/Digi |
| 11 | Cluster persistence across reboots | ~40 | Bridge reboot gap |
| 12 | Time-of-day via GPS | ~10 | Night multiplier ×2.0 |
| 13 | Warm similarity matrix | 1 line | Faster cluster formation |
| 14 | Deployment OLED page | ~50 | Field-interpretable alerts |
| 15 | Ground-truth dataset | manual | Calibrate thresholds |

Total: ~215 lines of code + 4 OUI lines + 1 manual task. All independent except 9 depends on the clustering module being built.

## Recommended Order

**Immediate (today):** Task 6 (`set -e` — one line, prevents silent build failures).  
**Then:** Task 3 (heap telemetry — verify the SPIFFS fix).  
**Then:** Task 2 (stack safety).  
**After clustering module is built:** Tasks 9, 10, 11, 12, 13, 14 (refinements).  
**After field testing:** Task 15 (calibration).

---

## Additional Issues Found During Full Codebase Audit

These were discovered by reading every C and Zig source file. They're smaller than the tasks above but represent real bugs, missing error handling, or correctness issues.

### Issue 16: LoRa Driver — Verbose Debug Prints in Production

**File:** `main/lora.c`  
**Lines:** 386, 410, 415, 421, 439, 447, 457

Every `lora_send()` prints "LoRa TX: NdB" plus IRQ/mode diagnostics. Every `lora_poll_receive()` prints on RX and RX_TIMEOUT. Every ~2 seconds it dumps "LoRa: poll irq=... mode=..." to serial. Under heavy mesh activity this floods the console.

**Fix:** Wrap in `#if 0` or `#ifdef LORA_DEBUG`. Keep one line on init: `printf("Argus: LoRa SX1262 ready...")`. Remove the rest or gate behind a compile flag.

### Issue 17: HTTP CSV Export Missing Buffered Lines

**File:** `main/httpd.c:213-229`  
**Bug:** `h_export_csv()` calls `fopen("/spiffs/detections.csv", "r")` directly. The scanner's RAM buffer (`csv_log_buf`) may contain up to 64 unflushed lines. These are NOT in the SPIFFS file yet, so they're silently missing from the HTTP download.

The serial export path (`main.zig:dumpCsv()`) correctly calls `scanner.csvLogFlush()` first. The HTTP path doesn't.

**Fix:** Call `csvLogFlush()` before opening the file. Requires exposing the function to C or adding a C wrapper:

```c
extern void csv_log_flush(void);  // declared in Zig, calls scanner.csvLogFlush()
```

Then in `h_export_csv`:

```c
csv_log_flush();  // flush buffered lines before reading
FILE *f = fopen("/spiffs/detections.csv", "r");
```

### Issue 18: Raven Single-UUID False Positives

**File:** `src/scanner.zig:273-275`  

```zig
} else if (raven_uuids == 1) {
    kind = .raven;
    methods |= METHOD_RAVEN_LOW;
}
```

This triggers on ANY single UUID from the Raven set, including 0x180A (Device Information — extremely common), 0x1809 (Health Thermometer — common in fitness devices), and 0x1819 (not Raven-specific). Any BLE thermometer advertising Device Information will be classified as `.raven` with 40 confidence points.

The comment in AGENTS.md says "1 UUID = possible (generic 0x180A alone is not reliable)" but the code doesn't exclude 0x180A in the single-UUID path.

**Fix:** Only count Raven-specific UUIDs (0x3100, 0x3200, 0x3300, 0x3400, 0x3500) toward the single-UUID path. Exclude 0x180A and 0x1809:

```zig
} else if (raven_uuids == 1) {
    // Only accept single-UUID match if it's a Raven-specific UUID,
    // not the universal 0x180A (Device Information) or 0x1809 (Health Thermometer).
    if (raven_fw_major >= 2) {  // saw 0x31xx/0x32xx/0x33xx/0x34xx/0x35xx
        kind = .raven;
        methods |= METHOD_RAVEN_LOW;
    }
}
```

### Issue 19: SSD1306 I2C Errors Silently Ignored

**File:** `src/hal/ssd1306.zig:68-77`  

`update()` calls `oled_i2c_write()` 9 times (3 command bytes per page + 1 data transfer per page) and ignores all return values. If I2C bus hangs or the OLED disconnects, the display goes blank with no indication — no LED error, no serial message, no fallback.

**Fix:** Track failures. If any page write fails, set a flag. On the next update cycle, try a full re-init. If that also fails, trigger the board's error LED pattern. Minimum: log the first failure to serial so it's visible on monitor.

### Issue 20: Carrier Probe Counter No MAC Dedup

**File:** `src/scanner.zig:306-320`

`carrier_probes` and `burst_recent_count` increment on every carrier SSID match. A single phone probing "attwifi" 10 times in rapid succession counts as 10 separate probes. The stingray burst detector thresholds (3× average in 5s window) are based on the assumption that each probe comes from a different phone.

**Fix:** Track a small dedup set (last 8 MACs + timestamps) for carrier probes. Only count a probe if the MAC hasn't been seen in the last 2 seconds. Prevents a single aggressive phone from triggering a false stingray alert.

### Issue 21: Firmware Version Mismatch with SPIFFS Config

**File:** `main/config.c`, `src/scanner.zig` (session persistence)  

No version check on config or session files. If a future firmware version changes the config format or session data layout, old SPIFFS files will be read with wrong assumptions — potentially corrupting config or resetting session counters to garbage values.

**Fix:** Write a version byte at the start of both `config.txt` and `session.dat`. On read, if the version doesn't match the current firmware's expected version, reset to defaults and re-save. One byte, zero cost.

### Issue 22: `ble_json_buf[8192]` Always Allocated

**File:** `src/main.zig:760`

8KB static buffer for the BLE phone stream, allocated even when no phone is connected. On a 512KB device that's 1.5% of RAM sitting idle in the common case (no phone paired).

**Fix:** This is harder than the SD log buffer gate because the buffer is needed at runtime (not comptime). Two options:
1. Reduce to 4096 — the largest JSON payload is `/api/detections` with 50 entries. 4KB should still fit.
2. Allocate from heap on first BLE connection, free on disconnect. But this reintroduces heap fragmentation risk in the exact scenario we just fixed with SPIFFS batching.

Option 1 is safer. 4096 bytes.

### Issue 23: `lora_send()` printf on Every TX

**File:** `main/lora.c:386`  

```c
printf("LoRa TX: %dB\n", len);
```

This printf fires on every mesh heartbeat (every 30s), every detection relay (potentially frequent), and every deployment alert relay. Each printf is ~15 bytes over 115200 baud UART = ~1.3ms of serial blocking. Under heavy mesh activity with multiple peers relaying detections, this adds up.

**Fix:** Gate behind `#ifdef LORA_DEBUG` (same as Issue 16).

### Summary of Additional Issues

| # | What | File | Lines | Severity |
|---|------|------|-------|----------|
| 16 | LoRa debug printf spam | lora.c | ~10 lines | Low — noisy serial |
| 17 | HTTP CSV export misses buffered lines | httpd.c, scanner.zig | ~5 lines | Medium — data loss |
| 18 | Raven single-UUID false positives | scanner.zig:273-275 | ~5 lines | Medium — false alerts |
| 19 | SSD1306 I2C errors silent | ssd1306.zig:68-77 | ~10 lines | Low — display failure invisible |
| 20 | Carrier probe counter no MAC dedup | scanner.zig:306-320 | ~15 lines | Medium — stingray false positives |
| 21 | No firmware version guard on config/session | config.c, scanner.zig | ~10 lines | Low — future-proofing |
| 22 | ble_json_buf wastes 4KB when idle | main.zig:760 | 1 line | Low — RAM optimization |
| 23 | lora_send printf on every TX | lora.c:386 | 1 line | Low — noisy serial |
