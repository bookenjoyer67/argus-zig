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

## Hardware sensitivity: T-Deck vs Heltec V3

The two supported boards have meaningfully different RF sensitivity:

| Board | Radio | Antenna | Sensitivity | Table fill risk |
|-------|-------|---------|------------|-----------------|
| **T-Deck** | ESP32-S3 module (shielded can) | Espressif-tuned PCB antenna | Higher — picks up ~30-50% more devices | Fills 64 entries in dense urban walks |
| **Heltec V3** | ESP32-S3FN8 bare chip | Heltec-designed PCB trace antenna, unshielded, adjacent to SX1262 LoRa | Lower — the SX1262 radiates RF noise into 2.4 GHz even when idle | Rarely fills 64 entries |

Root cause: the Heltec V3's SX1262 LoRa chip sits millimeters from the
BLE/WiFi antenna with no RF isolation. The module-based T-Deck has Espressif's
factory-tuned matching network and a metal shield can.

This is the SAME firmware — a single `MAX_TRACKERS` constant governs both
boards. The T-Deck is the stress case.

**Implication for eviction:** the T-Deck makes the table-fill problem real.
On the Heltec, MAX_TRACKERS=64 might never overflow in practice. On the
T-Deck, a walk through a dense commercial district can fill it in under
a minute. We must size for the worst board.

## Recommended synthesis: do both

| Step | Change | Lines | Rationale |
|------|--------|-------|-----------|
| 1 | Bump `MAX_TRACKERS` to **96** | 1 | Sweet spot: ~1,280 extra bytes (~0.2% of 512KB), 50% more headroom |
| 2 | Add score-prioritized eviction | ~10 | Keeps high-value entries sticky even at 96 |
| 3 | Optional: age-out low-score entries on a timer | future | Background cleanup of commodities older than N minutes; not needed yet |

Why not 128? Because 96 + smart eviction together preserve the headroom for
future features (mesh peer table, dashboard JSON buffer, longer CSV rows)
while still providing enough capacity for dense walks. The T-Deck's higher
sensitivity (~30-50% more devices) makes 96 justified. If field testing on
the T-Deck shows 96 fills, bump to 128 in a single-character change.

If only one is done now: choose **Option B** (smart eviction). It fixes the
fundamental bug (ring doorbell evicted by random Espressif) without touching
a single byte of RAM budget, and it benefits the T-Deck immediately — the
board that actually hits the limit. Bumping the constant can come after
a T-Deck walk test with the smart eviction in place to see if 64 still fills.

## Verification

- Build both boards: `BOARD=heltec_v3 ./build-zig.sh && idf.py build` and
  `BOARD=tdeck ./build-zig.sh && idf.py build`
- **Primary test target: T-Deck.** Walk through a dense commercial district
  (strip mall, downtown block) — the T-Deck is the board that actually fills
  the table. Verify SURV count doesn't oscillate (entries being evicted and
  re-detected in a loop).
- Secondary: same walk with Heltec V3 — confirm it never approaches the limit
  (validates that the Heltec's lower sensitivity makes this a non-issue on
  that board).
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
