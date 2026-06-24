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
const CLUSTER_MIN_DEVICES: usize = 3;

/// Maximum devices per cluster (bounded by tracker table size).
const CLUSTER_MAX_DEVICES: u8 = 16;

/// Maximum clusters tracked per analysis pass.
const MAX_CLUSTERS: u8 = 4;

/// How often the analysis runs (milliseconds).
pub const ANALYSIS_INTERVAL_MS: u32 = 3000;

/// Score thresholds for deployment alert tiers.
pub const DEPLOY_WARN: u16 = 60; // "Possible surveillance activity"
pub const DEPLOY_ALERT: u16 = 100; // "Probable surveillance deployment"

// ---- Global state ----

/// True when a deployment cluster score exceeds DEPLOY_WARN.
pub var deployment_alert_active: bool = false;

/// The highest cluster score from the most recent analysis pass.
pub var deployment_score: u16 = 0;

/// Number of devices in the highest-scoring cluster.
pub var deployment_device_count: u8 = 0;

/// Surveillance / embedded device counts in the highest-scoring cluster.
/// Cached so throttled (non-recompute) passes still report real values.
pub var deployment_surv_count: u8 = 0;
pub var deployment_embedded_count: u8 = 0;

/// Timestamp of the most recent analysis pass.
pub var last_analysis_ms: u32 = 0;

// ---- Cluster type ----

const Cluster = struct {
    members: [CLUSTER_MAX_DEVICES]usize, // indices into main.trackers
    count: u8,
    score: u16,
    min_rssi: i8,
    max_rssi: i8,
    formed_at: u32, // tick_ms when the cluster was first identified
    surv_count: u8, // surveillance-type devices in cluster
    embedded_count: u8, // embedded/professional BLE devices
    consumer_count: u8, // consumer devices (trackers, phones)
};

// ---- RSSI Tendency ----

/// Compute whether a device's RSSI is trending up (approaching),
/// down (fading), or steady. Returns null if insufficient data.
/// Uses the 5-sample rssi_history ring buffer in chronological order
/// (hidx points to the NEXT write slot, oldest is at hidx).
///
/// Accumulates in i8 (not i2) to avoid an overflow trap under
/// ReleaseSafe, then clamps to the ±2 range before returning.
fn rssiTendency(entry: main.TrackerEntry) ?i8 {
    var dir: i8 = 0; // negative = fading, positive = approaching
    var valid_pairs: u8 = 0;

    // Walk the ring buffer: hidx..hidx+4 (mod 5) is oldest→newest
    for (0..4) |i| {
        const a = entry.rssi_history[(@as(usize, entry.rssi_hidx) + i) % 5];
        const b = entry.rssi_history[(@as(usize, entry.rssi_hidx) + i + 1) % 5];
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
        const sa: i8 = ta.?;
        const sb: i8 = tb.?;

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

// ---- Cluster Formation ----

/// Similarity matrix: pairwise scores for all tracker entries.
/// 96×96 u8 = 9KB. Static to avoid stack allocation in the main loop.
var similarity: [main.MAX_TRACKERS][main.MAX_TRACKERS]u8 = undefined;

/// Static cluster buffer. Returned by reference from formClusters() — must
/// NOT be a stack local (that would return a dangling pointer). The main
/// loop is the single owner, so static storage is safe.
var clusters_buf: [MAX_CLUSTERS]Cluster = undefined;

/// Form clusters from the tracker table. Returns a slice of clusters
/// (length may be 0 if no clusters meet the minimum-size threshold).
/// Recomputes the similarity matrix each pass.
fn formClusters(now: u32) []Cluster {
    var cluster_count: u8 = 0;
    const n = main.tracker_count;

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
            clusters_buf[cluster_count] = clust;
            cluster_count += 1;
        }
    }

    return clusters_buf[0..cluster_count];
}

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
    if ((t.mac[0] & 0x02) != 0) return false;

    const m = t.methods;

    // Has manufacturer data?
    const has_manuf = (m & scanner.METHOD_MANUF) != 0;
    if (!has_manuf) return false;

    // Has human-readable device name?
    const has_name = (m & scanner.METHOD_BLE_NAME) != 0;
    if (has_name) return false;

    // Has known consumer service UUIDs?
    const has_consumer_service = (m & (scanner.METHOD_FINDMY |
        scanner.METHOD_TILE |
        scanner.METHOD_DRONE |
        scanner.METHOD_RAVEN |
        scanner.METHOD_SIDEWALK)) != 0;
    if (has_consumer_service) return false;

    // High duty cycle: seen frequently relative to how long it's been around.
    // A device seen > once per 3 seconds on average is broadcasting continuously
    // (consumer BLE typically duty-cycles when the phone screen is off).
    const dwell = t.last_seen -% t.first_seen;
    if (dwell > 0 and t.sightings > 0) {
        const avg_interval = dwell / @as(u32, t.sightings);
        if (avg_interval < 3000) return true; // < 3s average interval
    }

    return false;
}

// ---- Cluster Scoring ----

/// Score a cluster based on the types of devices it contains,
/// their diversity, the cluster's duration, and contextual factors.
/// Returns a score capped at 255.
fn scoreCluster(clust: *Cluster, now: u32) u16 {
    _ = now;
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

    // Time-of-day multiplier: night deployments are more suspicious.
    if (scanner.gps_utc_hour) |hour| {
        if (hour < 6 or hour >= 22) {
            score = score * 2;
        }
    }

    // ---- Duration multiplier ----
    const dur_sec = (latest_seen -% earliest_seen) / 1000;
    if (dur_sec > 3600) {
        score = score * 2; // >1 hour — persistent surveillance
    } else if (dur_sec > 1800) {
        score = score * 3 / 2; // >30 minutes
    } else if (dur_sec < 120) {
        score = score / 2; // <2 minutes — probably transient
    }
    // 2-60 minutes: baseline, no multiplier

    // Cap at 255.
    if (score > 255) score = 255;

    clust.score = score;
    return score;
}

// ---- Deployment CSV logger ----

/// Log a deployment cluster summary to the CSV log for post-walk analysis.
fn logDeployCluster(clusters: []Cluster) void {
    if (clusters.len == 0) return;
    var best_score: u16 = 0;
    var best_idx: u8 = 0;
    for (clusters, 0..) |*clust, i| {
        if (clust.score > best_score) {
            best_score = clust.score;
            best_idx = @intCast(i);
        }
    }
    if (best_score < DEPLOY_WARN) return;
    const clust = &clusters[best_idx];
    if (clust.count == 0) return;
    const dur_sec = if (main.tick_ms >= main.trackers[clust.members[0]].first_seen)
        (main.tick_ms - main.trackers[clust.members[0]].first_seen) / 1000
    else
        0;
    var line: [120]u8 = undefined;
    const s = std.fmt.bufPrint(&line, "{d},DEPLOY,{d},{d},{d},{d},{d},,,,0", .{
        main.tick_ms, best_score, clust.count, clust.surv_count, clust.embedded_count, dur_sec,
    }) catch return;
    scanner.csvLogAppendLine(s);
}

/// Persisted cluster state for reboot bridging.
const DEPLOY_STATE_MAGIC: u16 = 0xDE10;
const PersistedCluster = extern struct {
    magic: u16,
    score: u16,
    count: u8,
    hashes: [CLUSTER_MAX_DEVICES]u32,
};
var persisted_cluster: ?PersistedCluster = null;

/// Write the top cluster's MAC hashes to SPIFFS for persistence across reboots.
pub fn saveDeployCluster() void {
    if (!deployment_alert_active or deployment_score < DEPLOY_WARN) return;
    var pc = PersistedCluster{
        .magic = DEPLOY_STATE_MAGIC,
        .score = deployment_score,
        .count = @intCast(deployment_device_count),
        .hashes = [_]u32{0} ** CLUSTER_MAX_DEVICES,
    };
    // Hash the first deployment_device_count MACs for comparison on restore.
    var hash_count: u8 = 0;
    for (0..main.tracker_count) |i| {
        if (hash_count >= deployment_device_count) break;
        // Simple hash: XOR the 6 MAC bytes into a u32.
        const t = &main.trackers[i];
        var h: u32 = 0;
        for (t.mac) |b| h = h * 31 + b;
        pc.hashes[hash_count] = h;
        hash_count += 1;
    }
    const bytes = std.mem.asBytes(&pc);
    _ = main.spiffs_write_file("deploy.dat", bytes.ptr, bytes.len);
}

/// Read persisted cluster data from SPIFFS. If the stored MACs reappear
/// in the tracker table within 5 minutes of boot, bootstrap the cluster
/// with its previous score and duration for continuity.
pub fn restoreDeployCluster() void {
    var buf: [@sizeOf(PersistedCluster)]u8 = undefined;
    const n = main.spiffs_read_file("deploy.dat", &buf, buf.len);
    if (n < @sizeOf(PersistedCluster)) return;
    const pc = std.mem.bytesAsValue(PersistedCluster, &buf);
    if (pc.magic != DEPLOY_STATE_MAGIC) return;
    persisted_cluster = pc.*;
}

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
            .surv_count = deployment_surv_count,
            .embedded_count = deployment_embedded_count,
        };
    }
    last_analysis_ms = now;

    const clusters = formClusters(now);
    logDeployCluster(clusters);
    if (clusters.len == 0) {
        deployment_alert_active = false;
        deployment_score = 0;
        deployment_device_count = 0;
        deployment_surv_count = 0;
        deployment_embedded_count = 0;
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

    const best = clusters[best_idx];
    deployment_score = best_score;
    deployment_alert_active = best_score >= DEPLOY_WARN;
    deployment_device_count = best.count;
    deployment_surv_count = best.surv_count;
    deployment_embedded_count = best.embedded_count;

    if (best_score >= DEPLOY_WARN) {
        logDeployCluster(clusters);
    }

    return DeploymentResult{
        .active = deployment_alert_active,
        .score = best_score,
        .device_count = best.count,
        .surv_count = best.surv_count,
        .embedded_count = best.embedded_count,
    };
}
