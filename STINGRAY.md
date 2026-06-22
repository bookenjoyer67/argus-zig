# Stingray / IMSI Catcher Detection — Implemented ✓

Detects probable Stingray events via WiFi probe request side-channel analysis.
Indirect detection — the Heltec has no cellular modem and cannot see the fake
cell tower directly. It watches for the signature side effect: a burst of
carrier SSID probes from many phones in a short time window, which happens
when a Stingray forces phones off the cellular network.

**Status: Implemented.** See `src/scanner.zig` lines 52-400.

```
Normal operation:
  Carrier probes trickle in at 2-5 per minute. Phones casually probe
  for known WiFi as they move around. Steady, low-rate background noise.

Stingray event:
  Stingray powers on → phones get captured → Stingray releases them →
  phones lose cellular data → phones probe for carrier WiFi all at once.
  Result: 15-80 probes in < 10 seconds, many different MACs, same location.
```

The detector tracks probe rate in 5-second buckets. A bucket exceeding 3x the
rolling 60-second average is flagged. Two flagged buckets within 30 seconds
triggers a STINGRAY? alert.

## Data structures

All state lives in `src/scanner.zig`. No changes to C code — the WiFi sniffer
already captures probe requests with SSIDs. The `classifyWiFi()` function
already counts carrier probes for the `carrier_probes` counter. Extend that.

```zig
// Carrier probe burst detector — scanner.zig
const BURST_BUCKET_MS: u32 = 5000;       // 5-second time buckets
const BURST_WINDOW_BUCKETS: usize = 12;   // 60 seconds (12 × 5s)
const BURST_THRESHOLD_MULTIPLIER: u32 = 3; // 3x average = spike
const BURST_CONFIRM_BUCKETS: u32 = 6;     // Two spikes within 6 buckets (30s)

var burst_buckets: [BURST_WINDOW_BUCKETS]u32 = [_]u32{0} ** BURST_WINDOW_BUCKETS;
var burst_bucket_idx: usize = 0;
var burst_bucket_start_ms: u32 = 0;
var burst_last_spike_at: u32 = 0;          // timestamp of last bucket flag
var burst_recent_count: u32 = 0;           // probes in current bucket
var stingray_alert_active: bool = false;
var stingray_alert_ms: u32 = 0;
var stingray_probe_count: u32 = 0;         // total probes during alert window
var stingray_total_probes: u32 = 0;        // lifetime counter
var stingray_last_location: ?[2]i32 = null; // GPS location of last suspected event
```

## Algorithm

### Phase 1: Bucket counting

In `classifyWiFi()`, when a carrier SSID is matched, instead of just
incrementing `carrier_probes`, also increment `burst_recent_count`.

```zig
// In classifyWiFi(), replace/amend the carrier probe counting:
if (match) {
    carrier_probes += 1;
    burst_recent_count += 1;
    break;
}
```

### Phase 2: Bucket rotation

Called once per main loop iteration from `zig_main()`. Rolls the bucket
window forward if enough time has passed.

```zig
pub fn burstTick(now_ms: u32) void {
    // Initialize first bucket
    if (burst_bucket_start_ms == 0) {
        burst_bucket_start_ms = now_ms;
        return;
    }

    const elapsed = now_ms -% burst_bucket_start_ms;
    if (elapsed < BURST_BUCKET_MS) return;

    // Rotate: store current bucket, advance index
    burst_bucket_idx = (burst_bucket_idx + 1) % BURST_WINDOW_BUCKETS;
    burst_buckets[burst_bucket_idx] = burst_recent_count;
    burst_recent_count = 0;
    burst_bucket_start_ms = now_ms;

    // Check for spike
    detectBurst();
}
```

### Phase 3: Spike detection

Called after each bucket rotation. Computes the rolling average and
checks the just-closed bucket against the threshold.

```zig
fn detectBurst() void {
    // Compute rolling average (skip current/empty buckets)
    var sum: u32 = 0;
    var active_buckets: u32 = 0;
    for (0..BURST_WINDOW_BUCKETS) |i| {
        if (i == burst_bucket_idx) continue; // skip current (just reset to 0)
        if (burst_buckets[i] > 0) {
            sum += burst_buckets[i];
            active_buckets += 1;
        }
    }

    // Need at least 3 active buckets for a baseline
    if (active_buckets < 3) return;

    const avg: u32 = sum / active_buckets;
    if (avg == 0) return;

    // The bucket we just closed is at the previous index
    const prev_idx = (burst_bucket_idx + BURST_WINDOW_BUCKETS - 1) % BURST_WINDOW_BUCKETS;
    const recent = burst_buckets[prev_idx];

    // Spike: recent bucket is N× the average
    if (recent >= avg * BURST_THRESHOLD_MULTIPLIER and recent >= 4) {
        const now = @import("main.zig").tick_ms;
        const time_since_last = now -% burst_last_spike_at;

        // Two spikes within confirm window = alert
        if (time_since_last < BURST_CONFIRM_BUCKETS * BURST_BUCKET_MS and burst_last_spike_at != 0) {
            stingray_alert_active = true;
            stingray_alert_ms = now;
            stingray_probe_count = recent;

            // Capture GPS location if available
            if (gps_fix) {
                stingray_last_location = .{ gps_lat, gps_lon };
            }
        }

        burst_last_spike_at = now;
    }
}
```

### Phase 4: Auto-clear

Stingray alerts decay after 5 minutes with no new spikes.

```zig
pub fn burstClearCheck(now_ms: u32) void {
    if (stingray_alert_active and (now_ms -% stingray_alert_ms) > 300000) {
        stingray_alert_active = false;
    }
}
```

## Integration points

### In `zig_main()` main loop

Add two calls per iteration:

```zig
// In the main loop, alongside GPS and LoRa polling:
scanner.burstTick(tick_ms);
scanner.burstClearCheck(tick_ms);
```

### In OLED display

Add a STINGRAY indicator on the summary page when alert is active:

```zig
// drawSummary() — add after threat counts:
if (scanner.stingray_alert_active) {
    oledDrawStr(0, 50, "⚠ STINGRAY?");
}
```

Add a new threat class tile on the threats page:

```zig
// drawThreats() — add sixth tile for STINGRAY
if (scanner.stingray_alert_active) {
    displayThreatTile(/* position */, scanner.stingray_probe_count, "STING?");
}
```

### In CSV logging

Log Stingray alerts as a special event type:

```zig
// logCsv() or a new function:
if (stingray_alert_active) {
    var line: [80]u8 = undefined;
    const s = std.fmt.bufPrint(&line, "{d},STINGRAY,,,,,,{d},,,{d},{d},{X}\n", .{
        main.tick_ms,
        stingray_probe_count,
        if (stingray_last_location) |loc| loc[0] else @as(i32, 0),
        if (stingray_last_location) |loc| loc[1] else @as(i32, 0),
        @as(u32, 0), // methods = 0 for indirect detection
    }) catch return;
    _ = main.spiffs_append_line("detections.csv", line[0..s.len :0].ptr);
}
```

## Carrier SSID list

The existing list in `classifyWiFi()` (line 257) already covers the major US carriers:

```zig
const carrier_ssids = [_][]const u8{
    "attwifi", "VerizonWiFi", "xfinitywifi", "T-Mobile",
    "vodafone", "EE WiFi", "Orange", "o2wifi"
};
```

These are the SSIDs phones probe for when they lose cellular data.
AT&T phones probe `attwifi`. Verizon phones probe `VerizonWiFi`.
T-Mobile phones probe `T-Mobile`. In the US, `attwifi` probes are
the most common and the strongest Stingray indicator — AT&T has the
largest subscriber base and their phones aggressively probe.

## Verification

### False positive sources (expected normal bursts)

- **Train station / airport terminal:** 100+ people arriving simultaneously
  from a dead zone. Phones reconnect to cellular, no probes generated.
  Not a false positive trigger.

- **Cellular outage in a building:** Multiple phones lose signal simultaneously
  when entering a dead zone (elevator, basement parking). Phones probe carrier
  SSIDs. Looks identical to a Stingray but usually has lower probe volume
  (phoones don't all probe at the same instant — they stagger over 30-60s).

- **Concert venue / stadium:** 10,000+ phones in one location. Background probe
  rate is elevated but steady. The spike detector uses a rolling average, so
  a consistently high baseline won't trigger. Only a *sudden* increase does.

### How to test

1. **Baseline:** Run the device for 24 hours at home. Note normal carrier probe
   rate (likely 0-2 per bucket). The rolling average settles at ~0.1-0.3/bucket.

2. **Simulated spike:** Walk past a known dead zone (elevator bank, underground
   parking entrance) where phones lose signal. Watch for a probe burst as people
   exit. If it triggers, note the bucket count and adjust threshold.

3. **Real Stingray:** Nearly impossible to arrange, but Stingray usage is
   documented at protests, near federal buildings, and in some high-crime
   neighborhoods. If you're at a large protest and the device alerts, the
   probability is non-trivial.

4. **Tuning:** Adjust `BURST_THRESHOLD_MULTIPLIER` based on field data.
   Start at 3x. If you get false positives in urban areas, raise to 4x.
   If you never get any alerts, lower to 2.5x.

## Limitations

- **Indirect detection only.** Cannot confirm a Stingray is present. Only
  detects the *signature* of phones being kicked off cellular.

- **Carrier-dependent.** Works better in the US (where carrier SSIDs are
  well-known and phones probe aggressively). May not work in countries
  where carriers don't use dedicated WiFi SSIDs.

- **4G/5G Stingrays may be stealthier.** Modern IMSI catchers can capture
  phones without forcing them to reconnect, generating no probe burst.
  These are more expensive and less common, but they exist.

- **Location required for maximum utility.** A burst with GPS coordinates
  is actionable ("Stingray at 38.6270, -90.1994"). Without GPS, it's just
  "something happened somewhere near you."

## Effort

| Task | Time |
|------|------|
| Data structures + bucket rotation | 30 min |
| Spike detection algorithm | 30 min |
| Integration into main loop | 15 min |
| OLED display updates | 20 min |
| CSV logging | 15 min |
| Testing and tuning | ongoing |
| **Total** | **~2 hours** |
