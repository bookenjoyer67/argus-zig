# Walk Test Fixes — June 21, 2026

Based on CSV analysis from a 45-minute walk. 460+ detections logged.
5 Raven, 2 Flock ALPR, 5 Tile, 30 Samsung confirmed. Rest is noise.

---

## Fix 1: Stop Logging iPhones as AirTags

**File:** `src/scanner.zig`  
**Location:** `classifyBle()`, line 164 — the Apple Find My check

**Problem:** Every iPhone with Find My enabled broadcasts `0x4C 0x00 0x12`
(same as AirTag). 200+ entries classified as AIR with methods 0x20
(METHOD_FINDMY). They're phones, not trackers.

**Change:** After confirming company ID 0x004C and type 0x12, check payload
length before classifying as AirTag.

```
// Current (line 164):
if (company == 0x004C and payload.len >= 3 and payload[2] == 0x12) {
    kind = .airtag;
    methods |= METHOD_FINDMY;
}

// Replace with:
if (company == 0x004C and payload.len >= 3 and payload[2] == 0x12) {
    if (payload.len >= 22) {
        // Full public key — real AirTag or Find My accessory
        kind = .airtag;
        methods |= METHOD_FINDMY;
    }
    // Short payload (< 22 bytes) = iPhone/iPad/Mac — skip entirely
    // Don't set kind, don't set methods. Falls through to unknown.
}
```

**Expected result:** AIR entries drop from ~200 to actual AirTags (if any
are nearby). Phones pass through as unknown with no methods and get
filtered by Fix 3.

---

## Fix 2: Stop Logging Unclassified Noise

**File:** `src/scanner.zig`  
**Location:** `logCsv()`, line 492 — the CSV append function

**Problem:** Devices with no classification methods (methods == 0x00) are
being written to the CSV. These are random BLE advertisements from
headphones, fitness trackers, smart home devices — not surveillance.
They account for ~100 entries (25% of the log).

**Change:** Guard the CSV write. Only log if the device has at least one
method flag.

```
// Current (line 492):
pub fn logCsv(mac: [6]u8, rssi: i8) void {
    for (0..main.tracker_count) |i| {
        if (std.mem.eql(u8, &main.trackers[i].mac, &mac)) {
            // ... build line, append to SPIFFS ...

// Replace with:
pub fn logCsv(mac: [6]u8, rssi: i8) void {
    for (0..main.tracker_count) |i| {
        if (std.mem.eql(u8, &main.trackers[i].mac, &mac)) {
            const methods = main.trackers[i].methods;

            // Skip unclassified noise — don't waste SPIFFS space
            if (methods == 0) return;

            // ... build line, append ...
```

**Expected result:** ??? entries with methods 0x00 disappear from CSV.
Only devices with at least one detection method are logged.

---

## Fix 3: Don't Add Noise to the Tracker Table

**File:** `src/scanner.zig`  
**Location:** `trackDevice()`, line 309 — adding entries to the table

**Problem:** Devices with no methods still take up slots in the 64-entry
table. Combined with iPhone noise from Fix 1, the table fills and
evicts legitimate entries.

**Change:** Reject entries with no classification methods before they
enter the table.

```
// In trackDevice(), near the top, after classification but before
// searching for existing entries:

pub fn trackDevice(mac: [6]u8, result: ClassResult, rssi: i8) bool {
    // Reject unclassified devices — don't waste tracker slots
    if (result.methods == 0) return false;

    // ... existing logic ...
```

**Expected result:** Tracker table only holds classified devices. The
64-entry cap becomes a non-issue for normal environments.

---

## Fix 4: Only Log When Entry Is Added or Updated

**File:** `src/scanner.zig`  
**Location:** Call site in `main.zig` where `trackDevice` and `logCsv`
are called together (around line 1500-1530)

**Problem:** `logCsv` is called on every detection cycle, even if the
device was already in the table and hasn't changed. This means the
same MAC appears in the CSV multiple times per minute, bloating the log.
In the walk test CSV, many AIR entries appear 3-4 times with slightly
different RSSI values within seconds.

**Change:** Only log when `trackDevice` returns true (new entry) or
when the entry's score changes significantly. Move the `logCsv` call
inside the `is_new` branch or add a score-change threshold.

```
// Current pattern in main.zig:
const is_new = trackDevice(mac, result, rssi);
if (is_new) {
    had_new = true;
    session_total += 1;
    saveSession();
}
logCsv(mac, rssi);  // called every time, even for existing entries

// Fix: move logCsv inside the new-entry branch
const is_new = trackDevice(mac, result, rssi);
if (is_new) {
    had_new = true;
    session_total += 1;
    saveSession();
    logCsv(mac, rssi);  // only log new detections
}
```

**Expected result:** CSV file size drops ~80%. Each unique MAC appears
once per session instead of every few seconds.

---

## Fix 5: Doorbell Camera Counter

**File:** `src/scanner.zig`  
**Location:** Line 90 — BLE_SIGNATURES table, Sidewalk entry

**Problem:** Amazon Sidewalk devices (Ring/Blink/Echo) get `tracker_type = .unknown`
instead of `.camera`. The OLED camera counter only counts `.camera` entries.

**Change 1 — BLE_SIGNATURES table:**

```
// Line 90 — change tracker_type:
.{ .company_id = 0x0171, .service_uuids = &.{},
   .tracker_type = .camera, .method = METHOD_SIDEWALK },
// was: .tracker_type = .unknown
```

**Change 2 — Camera SSID keywords (line 241):**

WiFi Ring cameras won't match the existing camera keywords. Add "ring"
to the camera keyword list.

```
// Line 241 — add "ring" to cam_keywords:
const cam_keywords = [_][]const u8{
    "hikvision", "dahua", "reolink", "camera", "cam_",
    "ring",      // ← add this
};
```

**Expected result:** Ring doorbells detected via BLE Sidewalk count as
CAMERA type. Ring doorbells on WiFi with SSID containing "ring" also
register as camera.

---

## Fix 6: History Page Bar Order

**File:** `src/display.zig`  
**Location:** Lines 477 and 493 — `drawHistory()`

**Problem:** Buckets run left-to-right as 0-12min, 12-24min, etc. All
recent detections pile into the leftmost bar. Should be oldest-on-left,
newest-on-right.

**Change:**

```
// Line 477 — invert bucket assignment:
// Old:
const bucket: usize = @intCast(age / 720);
// New:
const bucket: usize = 4 - @intCast(age / 720);

// Line 493 — update X-axis labels:
// Old:
oledDrawStr(0, 52, " 12  24  36  48  60m");
// New:
oledDrawStr(0, 52, "60  48  36  24  now");
```

**Expected result:** After a walk, the rightmost bar fills. As time passes,
bars shift left. After 60+ minutes, all bars reset to empty.

---

## Order of Implementation

```
1. Fix 3  (noise rejection)          — stops the table filling
2. Fix 1  (iPhone/AirTag split)      — stops iPhones filling what's left
3. Fix 2  (CSV filter)               — cleans the log
4. Fix 4  (dedup logging)            — shrinks the log
5. Fix 5  (doorbell counter)         — fixes the broken counter
6. Fix 6  (history bars)             — cosmetic
```

Fixes 1-4 together reduce the CSV from 460 lines to ~40 lines of actual
surveillance and tracker detections per 45-minute walk.
