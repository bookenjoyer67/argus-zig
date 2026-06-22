# Hardware Test — Issues Found

Walk test: June 21, 2026
Environment: residential/urban, 15 minutes
Result: Raven and ALPR detected successfully. Four issues found.

---

## Confirmed Working

- **Raven gunshot detection** — picked up multiple Raven signals. BLE service UUID matching and firmware classification working.
- **Flock ALPR detection** — detected when approaching a Flock camera. OUI match + SSID validation working.
- **OLED display** — pages rendering, button cycling working.
- **Buzzer/LED alerts** — triggered on detection.

---

## Issue 1: Flock Camera Detected Late

**Symptom:** Camera didn't register on approach. Showed up later after standing nearby.

**Cause:** Not a bug. Flock cameras sleep most of their duty cycle. They wake briefly, upload photos over WiFi, then sleep again. The Heltec only sees the camera during the transmission window. Sleep gaps can be 30-90 seconds.

**Action:** None. Hardware behavior — the camera controls its own radio. If you stand under it for 2 minutes, it will transmit and the Heltec will catch it.

---

## Issue 2: Tracker Table Fills With iPhones

**Symptom:** 64-entry tracker table saturated. Most entries classified as AirTags.

**Cause:** Apple Find My BLE advertisements use the same manufacturer data pattern (0x4C00 + type 0x12) on every Apple device — AirTags, iPhones, iPads, MacBooks. The classifier calls them all AirTags with no distinction.

**Root cause in code:** `src/scanner.zig` line 164 — the Find My check doesn't examine payload length. AirTags send 28+ bytes (full public key). iPhones send 4-8 bytes (short status only).

**Fix 1:** Check payload length. Only classify as AirTag if payload >= 22 bytes (status + full key). Short payloads are phones/tablets — skip them or classify as `.findmy` generic.

```zig
// scanner.zig, after confirming 0x4C00 + 0x12:
if (payload.len >= 22) {
    kind = .airtag;
    methods |= METHOD_FINDMY;
} else {
    // iPhone/iPad/Mac — not a tracker
    // Don't add to table
}
```

**Fix 2:** Don't add devices with randomized MACs and sub-40 scores to the table at all. Phones rotate addresses every 15 minutes and appear as new entries.

```zig
// trackDevice(), after score computation:
if (score < SCORE_MED and (mac[0] & 0x02) != 0) {
    return false; // randomized + low confidence = phone, skip
}
```

**Files:** `src/scanner.zig`

---

## Issue 3: Doorbell Camera Counter Shows Zero

**Symptom:** OLED camera counter doesn't increment for Ring/Blink doorbells.

**Cause:** Two separate failures:

1. **BLE Sidewalk detection:** The BLE_SIGNATURES table entry for Amazon (0x0171) sets `tracker_type = .unknown`. A Ring doorbell broadcasting Sidewalk gets detected with Sidewalk methods but stored as unknown type. The camera counter on the display only counts `.camera` entries.

```zig
// scanner.zig line 90 — fix the tracker_type:
.{ .company_id = 0x0171, .service_uuids = &.{},
   .tracker_type = .camera, .method = METHOD_SIDEWALK },
// was: .tracker_type = .unknown
```

2. **WiFi OUI match for Ring cameras:** Ring cameras using WiFi (not Sidewalk) match the OUI (74:c2:46, 40:b4:cd, 68:54:fd) but get classified as `.wifi_device` because there's no camera SSID keyword match. Ring AP SSIDs are typically "Ring-XXXX" or hidden. "Ring" is not in the camera keyword list.

```zig
// scanner.zig line 241 — add Ring to camera keywords:
const cam_keywords = [_][]const u8{
    "hikvision", "dahua", "reolink", "camera", "cam_",
    "ring", "Ring-",   // ← add these
};
```

**Files:** `src/scanner.zig` lines 90 and 241

---

## Issue 4: History Page Shows Only One Bar

**Symptom:** Page 3 (detection history) shows only the leftmost bar filled. Other four bars empty.

**Cause:** The 5 bars represent time buckets going BACK from now: 0-12min, 12-24min, 24-36min, 36-48min, 48-60min. All detections from a 15-minute walk fall into bucket 0 (0-12 min ago). The code is working correctly, but the UX is confusing — you expect "now" to be on the right.

**Fix 1:** Invert bucket mapping so rightmost bar = recent, leftmost = oldest:

```zig
// display.zig line 477 — change:
const bucket: usize = @intCast(age / 720);
// to:
const bucket: usize = 4 - @intCast(age / 720);
```

**Fix 2:** Update X-axis labels to match:

```zig
// display.zig line 493 — change:
oledDrawStr(0, 52, " 12  24  36  48  60m");
// to:
oledDrawStr(0, 52, "60  48  36  24  now");
```

**Files:** `src/display.zig` lines 477 and 493

---

## Issue 5: 64-Entry WiFi Ring Buffer Overflows

**Symptom:** WiFi detections may be dropped in busy RF environments.

**Cause:** The promiscuous callback pushes every non-multicast frame to the ring buffer. In a residential area, hundreds of frames arrive per second — most are phones, laptops, smart TVs. The Zig side filters these later, but the ring buffer is full of noise.

**Fix:** Filter in the C callback before pushing. Only push frames where the transmitter MAC matches a known OUI or the SSID contains a surveillance keyword. The OUI list can be passed from Zig to C as an extern array.

Alternative simpler fix: double the ring buffer to 128 entries and add an overflow counter displayed on the system page.

**Files:** `main/wifi.c` line 39 (callback), `src/main.zig` (overflow counter)

---

## Priority

```
1. iPhone/AirTag classification     (fixes the most visible bug — full tracker table)
2. Doorbell counter                  (fixes broken feature)
3. History page bars                 (UX fix, 2 lines)
4. WiFi ring buffer overflow         (prevents data loss in dense areas)
5. Flock camera delay                (documentation, not a bug)
```
