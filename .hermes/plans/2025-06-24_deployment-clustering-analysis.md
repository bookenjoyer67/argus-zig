# Deployment Clustering Analysis — Implementation Plan

> **For Hermes:** Implement task-by-task. Build and flash after each task that compiles.

**Goal:** Add a passive analysis layer that detects surveillance deployments by clustering co-located, co-moving devices in the tracker table. No new hardware. No new sensors.

**Architecture:** New module `src/analysis.zig` sits alongside the existing scanner/display/mesh modules. It runs every 3 seconds in the main loop, reading the tracker table, computing RSSI co-movement similarity between device pairs, forming clusters via greedy majority-rule aggregation, scoring each cluster, and setting a global deployment alert flag. The display, LED, API, and mesh layers consume this flag — same pattern as the existing `stingray_alert_active`.

**Tech Stack:** Zig 0.16 (esp32s3 target), ESP-IDF v5.4. No C changes. No new dependencies.

---

## Pre-Implementation Checks

Before writing any code, verify the build works:

```bash
cd ~/argus-zig
./build-zig.sh && source ~/esp/esp-idf/export.sh && idf.py build
```

Expected: BUILD SUCCESS. If the build is broken, fix it before adding new code.

---

## Task 1: Create `src/analysis.zig` — Module Skeleton + RSSI Tendency

**Objective:** Create the new module with the `rssiTendency()` function that computes whether a device is approaching or fading based on its 5-sample RSSI history ring buffer.

**Files:**
- Create: `src/analysis.zig`

**Step 1: Write the module**

Create `/home/computing/argus-zig/src/analysis.zig`:

```zig
//! === ARGUS — Deployment Clustering Analysis ===
//!
//! Passive surveillance-deployment detector. Runs periodically in the
//! main loop, scoring clusters of co-located, co-moving devices in the
//! tracker table. A cluster with multiple surveillance-typical devices
//! (Flock cameras, drones, Raven sensors, embedded BLE with static MACs)
//! that appear together, move together, and persist together triggers
//! a deployment alert visible on the OLED, LED, API, and LoRa mesh.
//!
//! No new hardware. No new sensors. Pure analysis over existing data.

const std = @import("std");
const main = @import("main.zig");
const scanner = @import("scanner.zig");
const display = @import("display.zig");

// ---- Thresholds ----

/// Minimum similarity score (0-100) for two devices to be considered
/// "in the same physical cluster." Scores below this are ambient noise.
const CLUSTER_SIMILARITY_MIN: u8 = 50;

/// Clusters need 3+ devices to be considered a potential deployment.
const CLUSTER_MIN_DEVICES: u8 = 3;

/// Maximum devices per cluster (bounded by tracker table size).
const CLUSTER_MAX_DEVICES: u8 = 16;

/// Maximum clusters tracked per analysis pass.
const MAX_CLUSTERS: u8 = 4;

/// How often the analysis runs (milliseconds).
pub const ANALYSIS_INTERVAL_MS: u32 = 3000;

/// Score thresholds for deployment alert tiers.
pub const DEPLOY_WARN: u16 = 60;   // "Possible surveillance activity"
pub const DEPLOY_ALERT: u16 = 100; // "Probable surveillance deployment"

// ---- Global state ----

/// True when a deployment cluster score exceeds DEPLOY_WARN.
pub var deployment_alert_active: bool = false;

/// The highest cluster score from the most recent analysis pass.
pub var deployment_score: u16 = 0;

/// Number of devices in the highest-scoring cluster.
pub var deployment_device_count: u8 = 0;

/// Timestamp of the most recent analysis pass.
pub var last_analysis_ms: u32 = 0;

// ---- Cluster type ----

const Cluster = struct {
    members: [CLUSTER_MAX_DEVICES]usize, // indices into main.trackers
    count: u8,
    score: u16,
    min_rssi: i8,
    max_rssi: i8,
    formed_at: u32,        // tick_ms when the cluster was first identified
    surv_count: u8,         // surveillance-type devices in cluster
    embedded_count: u8,     // embedded/professional BLE devices
    consumer_count: u8,     // consumer devices (trackers, phones)
};

// ---- RSSI Tendency ----

/// Compute whether a device's RSSI is trending up (approaching),
/// down (fading), or steady. Returns null if insufficient data.
/// Uses the 5-sample rssi_history ring buffer in chronological order
/// (hidx points to the NEXT write slot, oldest is at hidx).
fn rssiTendency(entry: main.TrackerEntry) ?i2 {
    var dir: i2 = 0; // negative = fading, positive = approaching
    var valid_pairs: u8 = 0;

    // Walk the ring buffer: hidx..hidx+4 (mod 5) is oldest→newest
    for (0..4) |i| {
        const a = entry.rssi_history[(entry.rssi_hidx +% i) % 5];
        const b = entry.rssi_history[(entry.rssi_hidx +% i +% 1) % 5];
        if (a == 0 or b == 0) continue;

        valid_pairs += 1;
        if (b > a + 3) {
            dir += 1; // getting closer
        } else if (b < a - 3) {
            dir -= 1; // getting farther
        }
        // |b - a| <= 3: steady, no change in direction
    }

    if (valid_pairs < 2) return null;

    // Normalize: clamp to ±2 range
    if (dir > 2) dir = 2;
    if (dir < -2) dir = -2;
    return dir;
}
```

**Step 2: Verify it compiles**

```bash
cd ~/argus-zig && ./build-zig.sh
```

Expected: Zig build succeeds. The module imports main.zig and scanner.zig which already exist. No callers yet — the module is dead code, but it must compile.

---

## Task 2: `src/analysis.zig` — Device Pairwise Similarity

**Objective:** Add `deviceSimilarity()` — scores how likely two tracker entries are physically co-located, using RSSI co-movement (strong), RSSI proximity (weak), and temporal overlap (moderate).

**Files:**
- Modify: `src/analysis.zig` (append after `rssiTendency`)

**Step 1: Add the similarity function**

Append to `src/analysis.zig`:

```zig
// ---- Device Similarity ----

/// Score how likely two devices are in the same physical location.
/// Returns 0-100. Co-movement carries the most weight (strongest
/// evidence of co-location), RSSI proximity is a weak tiebreaker,
/// temporal overlap provides moderate signal.
fn deviceSimilarity(a: *const main.TrackerEntry, b: *const main.TrackerEntry, now: u32) u8 {
    // Both must be recently seen (within 30 seconds).
    if ((now -% a.last_seen) > 30000 or (now -% b.last_seen) > 30000) return 0;

    // Don't cluster a device with itself.
    if (std.mem.eql(u8, &a.mac, &b.mac)) return 0;

    var score: u8 = 0;

    // ----- Co-movement (strongest signal: 0-60 points) -----
    const ta = rssiTendency(a.*);
    const tb = rssiTendency(b.*);
    if (ta != null and tb != null) {
        const sa: i2 = ta.?;
        const sb: i2 = tb.?;

        // Same direction? (+approaching +approaching) or (-fading -fading)
        if ((sa > 0 and sb > 0) or (sa < 0 and sb < 0)) {
            score += 40;
            // Similar magnitude?
            if (@abs(sa - sb) <= 1) score += 20;
        }
        // Opposite directions = anti-signal (one approaching, other fading)
        else if ((sa > 0 and sb < 0) or (sa < 0 and sb > 0)) {
            if (score >= 30) score -= 30 else score = 0;
            return score; // early exit — strong anti-signal
        }
    }

    // ----- RSSI proximity (weak: 0-15 points) -----
    const rssi_diff = @abs(@as(i16, a.rssi) - @as(i16, b.rssi));
    if (rssi_diff <= 5) {
        score += 15;
    } else if (rssi_diff <= 10) {
        score += 10;
    } else if (rssi_diff <= 15) {
        score += 5;
    }

    // ----- Temporal overlap (moderate: 0-15 points) -----
    // Devices that appeared within the same time window are more
    // likely to belong to the same deployment.
    const overlap = temporalOverlap(a.*, b.*, now);
    if (overlap > 0.8) {
        score += 15;
    } else if (overlap > 0.5) {
        score += 10;
    } else if (overlap > 0.2) {
        score += 5;
    }

    return score;
}

/// Compute how much of their observed lifetimes two devices share.
/// Returns 0.0-1.0. Devices that appear together and disappear together
/// score highly; devices with staggered arrival/departure score lower.
fn temporalOverlap(a: main.TrackerEntry, b: main.TrackerEntry, now: u32) f32 {
    const overlap_start = @max(a.first_seen, b.first_seen);
    const overlap_end = @min(@max(a.last_seen, b.last_seen), now);

    if (overlap_end <= overlap_start) return 0.0;

    const shared: f32 = @floatFromInt(overlap_end -% overlap_start);
    const total: f32 = @floatFromInt(@max(
        @max(a.last_seen, b.last_seen) -% @min(a.first_seen, b.first_seen),
        @as(u32, 1),
    ));

    return shared / total;
}
```

**Step 2: Build**

```bash
cd ~/argus-zig && ./build-zig.sh
```

Expected: Compiles. Zig 0.16 supports `f32` on Xtensa (it's soft-float, but the compiler handles it).

---

## Task 3: `src/analysis.zig` — Cluster Formation

**Objective:** Add `formClusters()` — greedy majority-rule aggregation. A new device joins a cluster only if it's similar to MOST existing members, not just one edge member.

**Files:**
- Modify: `src/analysis.zig` (append after `deviceSimilarity`)

**Step 1: Add the cluster formation function**

Append to `src/analysis.zig`:

```zig
// ---- Cluster Formation ----

/// Similarity matrix: pairwise scores for all tracker entries.
/// 96×96 u8 = 9KB. Static to avoid stack allocation in the main loop.
var similarity: [main.MAX_TRACKERS][main.MAX_TRACKERS]u8 = undefined;

/// Form clusters from the tracker table. Returns a slice of clusters
/// (length may be 0 if no clusters meet the minimum-size threshold).
/// Recomputes the similarity matrix each pass.
fn formClusters(now: u32) []Cluster {
    var clusters: [MAX_CLUSTERS]Cluster = undefined;
    var cluster_count: u8 = 0;
    const n = main.tracker_count;
    if (n < CLUSTER_MIN_DEVICES) return &[0]Cluster{};

    // ----- Build similarity matrix -----
    for (0..n) |i| {
        similarity[i][i] = 0; // self = 0
        for (i + 1..n) |j| {
            const s = deviceSimilarity(&main.trackers[i], &main.trackers[j], now);
            similarity[i][j] = s;
            similarity[j][i] = s;
        }
    }

    // ----- Greedy majority-rule aggregation -----
    var assigned: [main.MAX_TRACKERS]bool = [_]bool{false} ** main.MAX_TRACKERS;

    for (0..n) |i| {
        if (assigned[i]) continue;

        // Start a new cluster with device i.
        var clust = Cluster{
            .members = [_]usize{0} ** CLUSTER_MAX_DEVICES,
            .count = 0,
            .score = 0,
            .min_rssi = main.trackers[i].rssi,
            .max_rssi = main.trackers[i].rssi,
            .formed_at = now,
            .surv_count = 0,
            .embedded_count = 0,
            .consumer_count = 0,
        };
        clust.members[clust.count] = i;
        clust.count += 1;
        assigned[i] = true;

        // Grow cluster: add devices similar to the majority.
        var changed = true;
        while (changed and clust.count < CLUSTER_MAX_DEVICES) {
            changed = false;
            for (0..n) |j| {
                if (assigned[j]) continue;

                // Device j must be similar to MOST existing members.
                var matches: u8 = 0;
                for (0..clust.count) |m| {
                    if (similarity[clust.members[m]][j] >= CLUSTER_SIMILARITY_MIN) {
                        matches += 1;
                    }
                }
                if (matches * 2 >= clust.count) { // majority rule
                    clust.members[clust.count] = j;
                    clust.count += 1;
                    assigned[j] = true;
                    changed = true;

                    // Update RSSI range.
                    if (main.trackers[j].rssi < clust.min_rssi)
                        clust.min_rssi = main.trackers[j].rssi;
                    if (main.trackers[j].rssi > clust.max_rssi)
                        clust.max_rssi = main.trackers[j].rssi;
                }
            }
        }

        // Only keep clusters with enough devices.
        if (clust.count >= CLUSTER_MIN_DEVICES and cluster_count < MAX_CLUSTERS) {
            clusters[cluster_count] = clust;
            cluster_count += 1;
        }
    }

    return clusters[0..cluster_count];
}
```

**Step 2: Build**

```bash
cd ~/argus-zig && ./build-zig.sh
```

Expected: Compiles. The `similarity` matrix is 9KB static — verify it fits by checking `zig-out/libargus.a` size didn't grow dramatically (should be +~2-3KB for this code).

---

## Task 4: `src/analysis.zig` — `isEmbedded()` Classifier

**Objective:** Add the embedded device classifier — identifies BLE devices with professional/embedded signatures (static MAC, manufacturer data, no device name, no known consumer services, high duty cycle).

**Files:**
- Modify: `src/analysis.zig` (append after `formClusters`)

**Step 1: Add the classifier**

Append to `src/analysis.zig`:

```zig
// ---- Embedded Device Classification ----

/// Identify BLE devices with professional/embedded signatures.
/// These are not recognized as a specific surveillance type but have
/// characteristics inconsistent with consumer devices:
///   - Static MAC (consumer BLE randomizes)
///   - Manufacturer data present
///   - No device name (consumer devices typically advertise a name)
///   - No known consumer service UUIDs
///   - High duty cycle (seen frequently relative to dwell time)
fn isEmbedded(t: *const main.TrackerEntry) bool {
    // Prerequisite: static MAC address.
    // Bit 1 of byte 0 = locally administered (randomized).
    if (t.mac[0] & 0x02 != 0) return false;

    const m = t.methods;

    // Has manufacturer data?
    const has_manuf = (m & scanner.METHOD_MANUF) != 0;
    if (!has_manuf) return false;

    // Has human-readable device name?
    const has_name = (m & scanner.METHOD_BLE_NAME) != 0;
    if (has_name) return false;

    // Has known consumer service UUIDs?
    const has_consumer_service = (m & (
        scanner.METHOD_FINDMY |
        scanner.METHOD_TILE |
        scanner.METHOD_DRONE |
        scanner.METHOD_RAVEN |
        scanner.METHOD_SIDEWALK
    )) != 0;
    if (has_consumer_service) return false;

    // High duty cycle: seen frequently relative to how long it's been around.
    // A device seen > once per 3 seconds on average is broadcasting continuously
    // (consumer BLE typically duty-cycles when the phone screen is off).
    const dwell = t.last_seen -% t.first_seen;
    if (dwell > 0) {
        const avg_interval = dwell / t.sightings;
        if (avg_interval < 3000) return true; // < 3s average interval
    }

    return false;
}
```

**Step 2: Build**

```bash
cd ~/argus-zig && ./build-zig.sh
```

Expected: Compiles.

---

## Task 5: `src/analysis.zig` — Cluster Scoring

**Objective:** Add `scoreCluster()` — scores a cluster based on device types, diversity bonuses, consumer penalties, duration, and time-of-day context.

**Files:**
- Modify: `src/analysis.zig` (append after `isEmbedded`)

**Step 1: Add the scoring function**

Append to `src/analysis.zig`:

```zig
// ---- Cluster Scoring ----

/// Score a cluster based on the types of devices it contains,
/// their diversity, the cluster's duration, and contextual factors.
/// Returns a score from 0-255 (capped).
fn scoreCluster(clust: *Cluster, now: u32) u16 {
    var score: u16 = 0;
    var earliest_seen: u32 = 0xFFFFFFFF;
    var latest_seen: u32 = 0;

    for (0..clust.count) |m| {
        const t = &main.trackers[clust.members[m]];

        // Per-device type scoring.
        switch (t.kind) {
            .flock_camera => {
                score += 30;
                clust.surv_count += 1;
            },
            .drone => {
                score += 25;
                clust.surv_count += 1;
            },
            .raven => {
                score += 30;
                clust.surv_count += 1;
            },
            .camera => {
                score += 15;
                clust.surv_count += 1;
            },
            .wifi_device => {
                // OUI-matched WiFi device — could be a camera, could be
                // a router. Score modestly; diversity bonuses will amplify
                // if other surveillance types are also present.
                score += 10;
            },
            .unknown => {
                if (isEmbedded(t)) {
                    score += 10;
                    clust.embedded_count += 1;
                } else {
                    score += 2; // generic unknown — minimal contribution
                }
            },
            .airtag, .tile, .samsung, .findmy => {
                clust.consumer_count += 1;
                // Consumer trackers are ambient. Don't reward them.
            },
            else => {},
        }

        if (t.first_seen < earliest_seen) earliest_seen = t.first_seen;
        if (t.last_seen > latest_seen) latest_seen = t.last_seen;
    }

    // ---- Multipliers ----

    // Surveillance diversity bonus: multiple distinct surveillance types
    // in the same physical cluster is a strong signal.
    if (clust.surv_count >= 2) {
        score = score * 3 / 2; // ×1.5
    }
    if (clust.surv_count >= 1 and clust.embedded_count >= 2) {
        score = score * 3 / 2; // ×1.5
    }

    // Penalize consumer-heavy clusters. A cluster dominated by AirTags
    // and Tiles is ambient crowd noise, not a deployment.
    if (clust.consumer_count > clust.surv_count + clust.embedded_count) {
        score = score * 2 / 3; // ×0.67
    }

    // ---- Duration multiplier ----
    const dur_sec = (latest_seen -% earliest_seen) / 1000;
    if (dur_sec > 3600) {
        score = score * 2;        // >1 hour — persistent surveillance
    } else if (dur_sec > 1800) {
        score = score * 3 / 2;   // >30 minutes
    } else if (dur_sec < 120) {
        score = score / 2;        // <2 minutes — probably transient
    }
    // 2-60 minutes: baseline, no multiplier

    // Cap at 255 (fits u8 display, but we use u16 internally for
    // intermediate multiplication without overflow).
    if (score > 255) score = 255;

    clust.score = score;
    return score;
}
```

**Step 2: Build**

```bash
cd ~/argus-zig && ./build-zig.sh
```

Expected: Compiles.

---

## Task 6: `src/analysis.zig` — Main Entry Point

**Objective:** Add `analyzeDeployments()` — the public function called from the main loop. Computes clusters, scores them, updates global deployment alert state, and returns the highest-scoring cluster.

**Files:**
- Modify: `src/analysis.zig` (append after `scoreCluster`)

**Step 1: Add the entry point**

Append to `src/analysis.zig`:

```zig
// ---- Public API ----

/// The result of a deployment analysis pass.
pub const DeploymentResult = struct {
    active: bool,
    score: u16,
    device_count: u8,
    surv_count: u8,
    embedded_count: u8,
};

/// Run one analysis pass over the tracker table. Called every
/// ANALYSIS_INTERVAL_MS from the main loop. Updates global state
/// (`deployment_alert_active`, `deployment_score`) and returns
/// a summary for consumers (display, API, mesh).
pub fn analyzeDeployments(now: u32) DeploymentResult {
    if (now -% last_analysis_ms < ANALYSIS_INTERVAL_MS) {
        // Not due yet — return cached result.
        return DeploymentResult{
            .active = deployment_alert_active,
            .score = deployment_score,
            .device_count = deployment_device_count,
            .surv_count = 0,
            .embedded_count = 0,
        };
    }
    last_analysis_ms = now;

    const clusters = formClusters(now);
    if (clusters.len == 0) {
        deployment_alert_active = false;
        deployment_score = 0;
        deployment_device_count = 0;
        return DeploymentResult{
            .active = false,
            .score = 0,
            .device_count = 0,
            .surv_count = 0,
            .embedded_count = 0,
        };
    }

    // Score every cluster.
    var best_score: u16 = 0;
    var best_idx: u8 = 0;
    for (clusters, 0..) |*clust, i| {
        const s = scoreCluster(clust, now);
        if (s > best_score) {
            best_score = s;
            best_idx = @intCast(i);
        }
    }

    deployment_score = best_score;
    deployment_alert_active = best_score >= DEPLOY_WARN;
    deployment_device_count = clusters[best_idx].count;

    return DeploymentResult{
        .active = deployment_alert_active,
        .score = best_score,
        .device_count = clusters[best_idx].count,
        .surv_count = clusters[best_idx].surv_count,
        .embedded_count = clusters[best_idx].embedded_count,
    };
}
```

**Step 2: Build**

```bash
cd ~/argus-zig && ./build-zig.sh
```

Expected: Compiles. Module is now complete and callable.

---

## Task 7: `src/main.zig` — Main Loop Integration

**Objective:** Add the analysis call site to the main loop, after BLE/WiFi polling and before the display refresh.

**Files:**
- Modify: `src/main.zig`

**Step 1: Import the module**

Add after the existing imports (around line 57, after `pub const api = @import("api.zig");`):

```zig
pub const analysis = @import("analysis.zig");
```

**Step 2: Add the call site in the main loop**

The analysis should run after both BLE and WiFi polling are done (both drain loops complete), after ID handling, and before the display refresh. Find the location after the WiFi polling block and before the `board.input.handle()` call (around line 1103). Insert:

```zig
        // --- Deployment clustering analysis ---
        // Runs every ~3s (throttled internally). Scores clusters of
        // co-located, co-moving devices for surveillance-deployment patterns.
        const depl = analysis.analyzeDeployments(tick_ms);
        if (depl.active) {
            // Extend threat LED: if deployment is active AND score >= MED,
            // treat it as a threat-level event so the LED pulses.
            if (depl.score >= 100) {
                // Score 100+ = probable deployment. Treat as "aware" (pulse).
                // This is handled in updateLed() which reads currentThreatLevel().
                // We don't need to change updateLed() — the deployment flag is
                // checked below in the alert section.
            }
        }
```

Insert this between the WiFi polling drain loop end (line ~1101) and `board.input.handle()` (line ~1107).

**Step 3: Add deployment to the threat LED (optional visual indicator)**

In the `updateLed()` function (around line 816), after the stingray alert check and before the normal threat-level check, add:

```zig
    // Deployment alert: slow amber double-pulse when a surveillance
    // deployment cluster is detected but no specific high-score threat
    // is active. Distinct from the threat-level patterns.
    if (analysis.deployment_alert_active and level < scanner.SCORE_MED) {
        const p = tick_ms % 3000;
        const on = (p < 60) or (p >= 400 and p < 460);
        board.led.set(if (on) LED_PULSE_PEAK else 0);
        return;
    }
```

Insert after the stealth mode block and before the stingray block (around line 836).

**Step 4: Build**

```bash
cd ~/argus-zig && ./build-zig.sh
```

Expected: Compiles. The Zig module imports, the call site is correct, the LED function references `analysis.deployment_alert_active`.

---

## Task 8: `src/api.zig` — Deployment Data in Status Endpoint

**Objective:** Add deployment cluster info to the `/api/status` JSON response so the web dashboard can show it.

**Files:**
- Modify: `src/api.zig`

**Step 1: Import analysis module**

Add at the top of `src/api.zig`:

```zig
const analysis = @import("analysis.zig");
```

**Step 2: Add deployment fields to status**

In `zig_api_status()`, after the `stingray_active` line (around line 129), add:

```zig
    b.add("\"deployment_active\":{s},", .{boolStr(analysis.deployment_alert_active)});
    b.add("\"deployment_score\":{d},", .{analysis.deployment_score});
    b.add("\"deployment_devices\":{d},", .{analysis.deployment_device_count});
```

The JSON output will include:
```json
"deployment_active": false,
"deployment_score": 0,
"deployment_devices": 0,
```

**Step 3: Build**

```bash
cd ~/argus-zig && ./build-zig.sh
```

Expected: Compiles.

---

## Task 9: Board UI — Deployment Counter on Summary Page

**Objective:** Show "DEPLOY: N" on the Heltec OLED summary page (page 0) and the T-Deck summary view, using the existing pattern for SURV and TRACK counters.

**Files:**
- Modify: `src/boards/heltec_v3_ui.zig`
- Modify: `src/boards/tdeck_ui.zig`

**Step 1: Heltec V3 summary page**

In `src/boards/heltec_v3_ui.zig`, find the summary page rendering (the section that draws "SURV: N  TRACK: M" on the first page). Add a third counter. The existing line format is approximately:

```
SURV: N  TRACK: M
```

Change to:

```
SURV: N  TRACK: M  DEPL: K
```

Or, if space is tight on the 128-pixel OLED, add it on the next line below the existing counters.

**Step 2: T-Deck summary view**

In `src/boards/tdeck_ui.zig`, locate the summary page section and add the same counter.

**Step 3: Build**

```bash
cd ~/argus-zig && ./build-zig.sh
```

Expected: Compiles. The counter reads `analysis.deployment_device_count` when `analysis.deployment_alert_active` is true, or 0 otherwise.

---

## Task 10: `src/mesh.zig` — Deployment Alert Mesh Packet

**Objective:** Add a `TYPE_DEPLOY` (0x04) mesh packet so peer Argus units can relay deployment alerts.

**Files:**
- Modify: `src/mesh.zig`

**Step 1: Add the packet type constant**

In `src/mesh.zig`, after `const TYPE_DETECTION = 0x02;`:

```zig
const TYPE_STINGRAY = 0x03;
const TYPE_DEPLOY = 0x04;
```

**Step 2: Add the packet builder**

After `makeDetection()`, add:

```zig
fn makeDeploy(pkt: *[PKT_MAX]u8, score: u16, device_count: u8, surv: u8, embedded: u8) u8 {
    pkt[0] = TYPE_DEPLOY; // hop 0
    pkt[1] = mesh_node_id();
    std.mem.writeInt(u16, pkt[2..4], score, .little);
    pkt[4] = device_count;
    pkt[5] = surv;
    pkt[6] = embedded;
    std.mem.writeInt(i32, pkt[7..11], scanner.gps_lat, .little);
    std.mem.writeInt(i32, pkt[11..15], scanner.gps_lon, .little);
    const len: u8 = 15;
    pkt[len] = crc8(pkt[0..len]);
    return len + 1;
}
```

**Step 3: Add the broadcast function**

After `sendHeartbeat()`:

```zig
pub fn sendDeployAlert(score: u16, devices: u8, surv: u8, embedded: u8) void {
    var pkt: [PKT_MAX]u8 = undefined;
    const len = makeDeploy(&pkt, score, devices, surv, embedded);
    _ = main.lora_send(&pkt, len);
}
```

**Step 4: Add the receive handler**

After `recvStingray()` (which you'll add now if it doesn't exist yet — use a stub that just records the peer):

```zig
fn recvDeploy(pkt: []const u8, hop: u4) void {
    _ = hop;
    if (pkt.len < 16) return;
    const sender_id: u8 = pkt[1];
    // We receive a deployment alert from a peer — log the peer and
    // surface the alert locally. The peer's score overrides our own
    // if it's higher (mesh corroboration).
    peerSeen(sender_id);
    
    const score: u16 = std.mem.readInt(u16, pkt[2..][0..2], .little);
    if (score > analysis.deployment_score) {
        analysis.deployment_alert_active = true;
        analysis.deployment_score = score;
        analysis.deployment_device_count = pkt[4];
    }
}
```

**Step 5: Add to meshRecv dispatch**

In `meshRecv()`, add cases:

```zig
    switch (pkt_type) {
        TYPE_HEARTBEAT => recvHeartbeat(pkt, hop),
        TYPE_DETECTION => recvDetection(pkt, hop),
        TYPE_STINGRAY => recvStingray(pkt, hop),
        TYPE_DEPLOY => recvDeploy(pkt, hop),
        else => {},
    }
```

**Step 6: Call the broadcast from the main loop**

In `src/main.zig`, after the deployment analysis call site (from Task 7), add:

```zig
        if (depl.active and depl.score >= 100) {
            if (tick_ms -% mesh.last_heartbeat_ms >= 5000) {
                mesh.sendDeployAlert(depl.score, depl.device_count, depl.surv_count, depl.embedded_count);
            }
        }
```

This broadcasts deployment alerts over the mesh at most once per 5 seconds, rate-limited to avoid flooding the channel.

**Step 7: Build**

```bash
cd ~/argus-zig && ./build-zig.sh
```

Expected: Compiles.

---

## Task 11: Full Build and Flash Test

**Objective:** Build the complete firmware and verify it boots on hardware.

**Step 1: Full build**

```bash
cd ~/argus-zig
./build-zig.sh
source ~/esp/esp-idf/export.sh
idf.py build
```

Expected: BUILD SUCCESS. Binary size should increase by ~3-5KB (the analysis logic, similarity matrix, and new mesh packet handlers).

**Step 2: Check binary size**

```bash
ls -lh build/argus-zig.bin
```

Compare with previous build. Expected: modest increase, well within the 2MB OTA partition.

**Step 3: Flash and monitor**

```bash
idf.py -p /dev/ttyUSB0 flash monitor
```

Expected: Device boots, shows "Argus Zig — booting", enters main loop, OLED displays normally. No crashes in the first 30 seconds. The deployment counter should show 0 under normal home/office conditions.

**Step 4: Walk test**

Walk through an area with known surveillance devices (Flock cameras, drone activity) and check:
- Deployment counter stays at 0 with ambient devices (no false positives)
- If multiple surveillance devices cluster at similar RSSI, the counter may rise
- The device should not crash or watchdog-reset during extended operation

---

## Task 12: SDK Config — Enable Stack Canary (Safety Measure)

**Objective:** Ensure the stack canary is enabled to catch any stack overflow from the similarity matrix or cluster analysis.

**Step 1: Check current config**

```bash
cd ~/argus-zig
grep STACKOVERFLOW sdkconfig
```

**Step 2: Enable if not already set**

If `CONFIG_FREERTOS_CHECK_STACKOVERFLOW_CANARY` is not `y`, run:

```bash
# Already confirmed in sdkconfig: CONFIG_FREERTOS_CHECK_STACKOVERFLOW_CANARY=y
```

This is already enabled. No change needed.

**Step 3: Verify main task stack size**

```bash
grep MAIN_TASK_STACK sdkconfig
```

Expected: `CONFIG_ESP_MAIN_TASK_STACK_SIZE=16384` (16KB). The similarity matrix is a static (BSS, not stack), so no additional stack pressure. The analysis functions use minimal stack (~200 bytes for local variables). 16KB is sufficient.

---

## Summary of All Changes

| File | Change | Lines (approx) |
|------|--------|---------------|
| `src/analysis.zig` | New module | ~280 |
| `src/main.zig` | Import + main loop call site + LED + mesh broadcast | ~25 |
| `src/api.zig` | Import + 3 JSON fields in status | ~5 |
| `src/mesh.zig` | TYPE_DEPLOY constant + builder + sender + receiver + dispatch | ~50 |
| `src/boards/heltec_v3_ui.zig` | DEPLOY counter on summary page | ~5 |
| `src/boards/tdeck_ui.zig` | DEPLOY counter on summary page | ~5 |

Total: ~370 lines of new code across 6 files.

## Verification Checklist

- [ ] `./build-zig.sh` passes (Zig compilation)
- [ ] `idf.py build` passes (ESP-IDF link)
- [ ] Binary size increase is <10KB vs baseline
- [ ] Device boots and runs for >60 seconds without crash
- [ ] OLED shows normal pages, DEPLOY counter at 0 in normal environment
- [ ] Web dashboard `/api/status` includes `deployment_active`, `deployment_score`, `deployment_devices`
- [ ] Walk test: no false positives in civilian environments
- [ ] Stack canary does not trigger during extended operation

## Risks and Open Questions

1. **The similarity matrix (9KB static BSS).** Fine on ESP32-S3 with 512KB SRAM. Not a concern for memory pressure.

2. **False positives in IoT-dense environments (smart homes, coffee shops).** The `isEmbedded()` classifier and consumer penalty should mitigate this, but real-world testing is needed to tune thresholds. The `DEPLOY_WARN` threshold (60) and `DEPLOY_ALERT` threshold (100) are educated guesses.

3. **Co-movement requires the observer to be moving.** If you're stationary and the surveillance van is also stationary, RSSI doesn't change and co-movement scores zero. The cluster still forms via RSSI proximity and temporal overlap, but the score will be lower. This is acceptable — a stationary van in a parking lot at 3 AM with 5 radios will still trigger via the other signals.

4. **No baseline persistence across reboots.** Each power cycle resets the tracker table. A deployment that's been active for 3 hours will show as "just appeared" after a reboot. The duration multiplier won't apply. Acceptable for v1 — GPS-keyed baselining is a v2 feature.

5. **Zig 0.16 soft-float for `f32` in `temporalOverlap()`.** The Xtensa target uses software floating point via compiler-rt. The function uses one float division per pairwise comparison. For 96 devices that's ~4500 float ops every 3 seconds — negligible on a 240 MHz CPU.
