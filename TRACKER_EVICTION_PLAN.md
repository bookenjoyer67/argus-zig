# Tracker Eviction Synthesis Plan

Author: Hermes  
Date: 2026-06-22  
Status: draft — not implemented  

## Problem

`MAX_TRACKERS = 64` (a static array, no heap). In dense urban walks, the table
can fill with low-value entries (commodity WiFi chips at score ≤ 25, transient
phone MACs) before a high-value surveillance device shows up. Once full, the
current eviction strategy is pure FIFO by `last_seen` — drops the stalest entry
regardless of its classification value. A Ring doorbell at score 100 can get
evicted by a random Espressif OUI at score 25, which is backwards.

## Two options (not mutually exclusive)

### Option A — Bump to 128

```
pub const MAX_TRACKERS = 128;  // was 64
```

**One line.** `TrackerEntry` is 26 bytes (packed Zig struct):

| Field         | Bytes |
|---------------|-------|
| mac           | 6     |
| kind (enum)   | 1     |
| rssi          | 1     |
| last_seen     | 4     |
| score         | 1     |
| methods       | 2     |
| rssi_history  | 5     |
| rssi_hidx     | 1     |
| source        | 1     |
| mesh_lat/lon  | 8     |
| first_seen    | 4     |
| sightings     | 2     |
| *padding*     | ~4    |
| **Total**     | **~40** (compiler-dependent) |

64 → 128 doubles the array: **~2,560 bytes → ~5,120 bytes**. On a 512 KB
SRAM device with ~300 KB free after stack/heap, that's ~0.8% of available RAM.
Negligible.

**Pros:** No eviction logic changes. No new bugs. Handles dense areas by
brute force.  
**Cons:** Kicks the can down the road — 128 fills too. Higher memory pressure
for future features (mesh peer table, CSV buffer, web dashboard).

### Option B — Keep 64, prioritize evictions

When the table is full, evict in this order of priority:

1. **Drop score < SCORE_MED (40) first** — commodity OUIs, random phone MACs,
   anything the classifier didn't flag.
2. **Among low-score, drop oldest `last_seen`** — clean up stale background
   noise before fresher noise.
3. **If all entries are ≥ MEDIUM, drop the oldest `last_seen` overall** —
   fallback to current behavior for the pathological case where 64 real threats
   are simultaneously in range (unlikely in practice).

Implementation (~10 lines in `scanner.zig` `trackDevice()`):

```zig
// Current (lines 511-524):
if (main.tracker_count < main.MAX_TRACKERS) {
    main.trackers[main.tracker_count] = entry;
    main.tracker_count += 1;
} else {
    var oldest_idx: usize = 0;
    var oldest_time: u32 = main.trackers[0].last_seen;
    for (1..main.MAX_TRACKERS) |i| {
        if (main.trackers[i].last_seen < oldest_time) {
            oldest_time = main.trackers[i].last_seen;
            oldest_idx = i;
        }
    }
    main.trackers[oldest_idx] = entry;
}

// Proposed:
if (main.tracker_count < main.MAX_TRACKERS) {
    main.trackers[main.tracker_count] = entry;
    main.tracker_count += 1;
} else {
    var evict_idx: usize = 0;
    var evict_score: u8 = main.trackers[0].score;
    var evict_time: u32  = main.trackers[0].last_seen;
    for (1..main.MAX_TRACKERS) |i| {
        const s = main.trackers[i].score;
        const t = main.trackers[i].last_seen;
        // Priority 1: lower score wins eviction
        // Priority 2: within same score bracket, older wins
        if (s < evict_score) {
            evict_score = s; evict_time = t; evict_idx = i;
        } else if (s == evict_score and t < evict_time) {
            evict_time = t; evict_idx = i;
        }
    }
    main.trackers[evict_idx] = entry;
}
```

**Pros:** Zero RAM increase. Smart about what gets dropped — high-value
detections are sticky. Fits the surveillance use case: you care about
keeping threats, not background devices.  
**Cons:** The 64-entry hard ceiling remains. In a truly dense threat
environment (convention center sweep? multi-ALPR intersection?), you
could still lose entries. The eviction loop is ~2x the current loop
(reads `score` and `last_seen` per iteration instead of just `last_seen`),
but 64 iterations through a 40-byte struct is ~30 µs on ESP32-S3 at
240 MHz — well within the BLE callback budget.

## Recommended synthesis: do both

| Step | Change | Lines | Rationale |
|------|--------|-------|-----------|
| 1 | Bump `MAX_TRACKERS` to **96** | 1 | Sweet spot: ~1,280 extra bytes (~0.2% of 512KB), 50% more headroom |
| 2 | Add score-prioritized eviction | ~10 | Keeps high-value entries sticky even at 96 |
| 3 | Optional: age-out low-score entries on a timer | future | Background cleanup of commodities older than N minutes; not needed yet |

Why not 128? Because 96 + smart eviction together preserve the headroom for
future features (mesh peer table, dashboard JSON buffer, longer CSV rows)
while still providing enough capacity for dense walks. If field testing shows
96 fills, bump to 128 in a single-character change.

If only one is done now: choose **Option B** (smart eviction). It fixes the
fundamental bug (ring doorbell evicted by random Espressif) without touching
a single byte of RAM budget. Bumping the constant can come later when there's
field data.

## Verification

- Build: `./build-zig.sh && idf.py build`
- Walk test: dense urban area, verify SURV count doesn't oscillate
- Check: a Ring doorbell (score 100, 30 minutes stale) survives while
  a fresh Espressif commodity (score 25, 5 seconds old) gets dropped

## Related files

| File | Lines affected |
|------|----------------|
| `src/main.zig:389` | `MAX_TRACKERS` constant |
| `src/scanner.zig:511–524` | `trackDevice()` eviction loop |
| `src/main.zig:650` | Comment referencing 640 bytes (needs update) |
| `AGENTS.md:97` | "MAX_TRACKERS static array" (needs update) |
| `src/display.zig` | No changes (reads `.score` from entry, no awareness of eviction) |
