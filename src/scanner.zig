//! === ARGUS — Detection & Classification Engine ===
//!
//! Surveillance device detection logic extracted from main.zig:
//!   - BLE advertisement parsing (Find My, Tile, Drone Remote ID, Raven)
//!   - WiFi OUI + SSID classification (Flock ALPR cameras)
//!   - Confidence scoring from method-flag corroboration
//!   - Tracker table updates (no heap — fixed array lives in main)
//!   - CSV detection logging to SPIFFS
//!   - Session counter persistence
//!   - GPS NMEA sentence parsing ($GPGGA / $GPRMC)
//!
//! Shared state (tracker table, OUI database, SPIFFS extern fns) lives in
//! main.zig and is accessed through the `main` import. The TrackerType enum
//! lives in display.zig and is accessed through the `display` import.

const std = @import("std");
const main = @import("main.zig");
const display = @import("display.zig");

// ================================================================
// DETECTION METHOD FLAGS
// ================================================================
//
// Bitmask — each method contributes to the confidence score.
// Add new methods here, then add entries to BLE_SIGNATURES below.

/// Detection method flags (bitmask) — each method contributes to confidence score.
pub const METHOD_OUI: u16         = 1 << 0; // MAC OUI match (40 pts)
pub const METHOD_SSID_PREFIX: u16 = 1 << 1; // SSID starts with "Flock" (50 pts)
pub const METHOD_SSID_FLOCK: u16  = 1 << 2; // SSID "Flock-XXXX" full format (65 pts)
pub const METHOD_BLE_NAME: u16    = 1 << 3; // BLE advert contains device name (45 pts)
pub const METHOD_MANUF: u16       = 1 << 4; // Manufacturer 0x09C8 / 0x0075 (60 pts)
pub const METHOD_FINDMY: u16      = 1 << 5; // Apple Find My 0x4C00+type 0x12 (70 pts)
pub const METHOD_RAVEN: u16       = 1 << 6; // Raven gunshot sensor UUID (70 pts)
pub const METHOD_TILE: u16        = 1 << 7; // Tile 0xFEED service UUID (45 pts)
pub const METHOD_DRONE: u16       = 1 << 8; // Drone Remote ID (BLE 0xFFFA or OUI) (60 pts)
// Raven firmware version flags (encoded in methods for display)
pub const RAVEN_FW_1_1: u16      = 1 << 9;  // Legacy — UUIDs 0x1809/0x1819
pub const RAVEN_FW_1_2: u16      = 1 << 10; // UUIDs 0x31xx/0x32xx/0x3300
pub const RAVEN_FW_1_3: u16      = 1 << 11; // UUIDs 0x34xx/0x3500
pub const METHOD_CAM_SSID: u16   = 1 << 12; // SSID contains camera keyword (30 pts)
pub const METHOD_SIDEWALK: u16    = 1 << 13; // Amazon Sidewalk device (50 pts)
pub const METHOD_WIFI_DRONE: u16  = 1 << 14; // WiFi Remote ID tag 221 (85 pts)
pub const METHOD_RAVEN_LOW: u16   = 1 << 15; // Raven 1 UUID — possible, lower confidence (40 pts)

/// Carrier probe request counter — SSIDs like "attwifi", "VerizonWiFi", etc.
/// A spike in these from different MACs can indicate an IMSI catcher (Stingray)
/// forcing phones off cellular networks, making them probe for known WiFi.
pub var carrier_probes: u32 = 0;

// ================================================================
// STINGRAY / IMSI-CATCHER DETECTION (carrier-probe burst analysis)
// ================================================================
//
// Indirect detection: a Stingray forces phones off cellular, so they
// probe for carrier WiFi all at once. We bucket carrier-probe counts in
// 5s windows and flag a bucket exceeding 3x the rolling 60s average.
// Two flagged buckets within 30s raises a STINGRAY alert. See STINGRAY.md.

const BURST_BUCKET_MS: u32 = 5000;          // 5-second time buckets
const BURST_WINDOW_BUCKETS: usize = 12;     // 60s rolling window (12 × 5s)
const BURST_THRESHOLD_MULTIPLIER: u32 = 3;  // 3x average = spike
const BURST_CONFIRM_BUCKETS: u32 = 6;       // two spikes within 30s (6 × 5s)
const STINGRAY_CLEAR_MS: u32 = 300000;      // auto-clear after 5 min

/// True while a probable Stingray event is active. Read by display + LED.
pub var stingray_alert_active: bool = false;
/// Probe count of the spike that triggered the active alert.
pub var stingray_probe_count: u32 = 0;

var burst_buckets: [BURST_WINDOW_BUCKETS]u32 = [_]u32{0} ** BURST_WINDOW_BUCKETS;
var burst_bucket_idx: usize = 0;
var burst_bucket_start_ms: u32 = 0;
var burst_recent_count: u32 = 0;            // probes in the currently-filling bucket
var burst_last_spike_at: u32 = 0;           // tick_ms of the last flagged bucket
var stingray_alert_ms: u32 = 0;             // tick_ms the alert went active
var stingray_last_location: ?[2]i32 = null; // GPS at last suspected event

// ================================================================
// OUI MATCHING
// ================================================================

/// Check if a MAC address matches any known surveillance OUI.
/// Iterates over the database. At 31 entries, the compiler
/// will likely unroll this into a decision tree.
pub fn matchOui(mac: [6]u8) bool {
    for (main.KNOWN_OUIS[0..main.KNOWN_OUIS_COUNT]) |oui| {
        if (std.mem.eql(u8, &oui, mac[0..3])) return true;
    }
    return false;
}

// ================================================================
// CLASSIFICATION RESULT + SCORING
// ================================================================

/// Classification result from BLE or WiFi scanners.
/// BLE detection signature table — data-driven approach.
/// Each entry maps BLE advertisement patterns to tracker types
/// and method flags. First match wins in classifyBle().
/// Add new entries here without changing classifyBle().
const BleSignature = struct {
    company_id: ?u16,
    service_uuids: []const u16,
    tracker_type: display.TrackerType,
    method: u16,
};

const BLE_SIGNATURES = [_]BleSignature{
    // Apple Find My (AirTag, iPhone)
    .{ .company_id = 0x004C, .service_uuids = &.{}, .tracker_type = .airtag, .method = METHOD_FINDMY },
    // Tile trackers
    .{ .company_id = null, .service_uuids = &.{0xFEED}, .tracker_type = .tile, .method = METHOD_TILE },
    // Samsung SmartTag / SmartTag 2
    .{ .company_id = 0x0075, .service_uuids = &.{}, .tracker_type = .samsung, .method = METHOD_MANUF },
    // ASTM Drone Remote ID (BLE UUID 0xFFFA)
    .{ .company_id = null, .service_uuids = &.{0xFFFA}, .tracker_type = .drone, .method = METHOD_DRONE },
    // Amazon Sidewalk (Ring, Echo, Tile via Sidewalk)
    .{ .company_id = 0x0171, .service_uuids = &.{}, .tracker_type = .camera, .method = METHOD_SIDEWALK },
    // Chipolo trackers (Immediate Alert service 0x1802)
    .{ .company_id = null, .service_uuids = &.{0x1802}, .tracker_type = .unknown, .method = METHOD_TILE },
    // Fitbit / wearables (company ID 0x0059)
    .{ .company_id = 0x0059, .service_uuids = &.{}, .tracker_type = .unknown, .method = METHOD_BLE_NAME },
    // Tesla phone key (BLE key fob service 0x1530)
    .{ .company_id = null, .service_uuids = &.{0x1530}, .tracker_type = .unknown, .method = METHOD_BLE_NAME },
    // Tile (older style via manufacturer 0x0224)
    .{ .company_id = 0x0224, .service_uuids = &.{}, .tracker_type = .tile, .method = METHOD_TILE },
};

pub const ClassResult = struct {
    kind: display.TrackerType,
    methods: u16,
};

/// Confidence score thresholds — configurable constants.
pub const SCORE_MED: u8 = 40;
pub const SCORE_HIGH: u8 = 70;
pub const SCORE_CERT: u8 = 85;

/// Compute confidence score from method flags, RSSI, and MAC type.
/// Bonuses: multi-method corroboration, strong signal, static address.
pub fn computeScore(methods: u16, rssi: i8, mac: [6]u8) u8 {
    var score: u32 = 0;
    var count: u32 = 0;

    if (methods & METHOD_OUI != 0)         { score += 40; count += 1; }
    if (methods & METHOD_SSID_PREFIX != 0) { score += 50; count += 1; }
    if (methods & METHOD_SSID_FLOCK != 0)  { score += 65; count += 1; }
    if (methods & METHOD_BLE_NAME != 0)    { score += 45; count += 1; }
    if (methods & METHOD_MANUF != 0)       { score += 60; count += 1; }
    if (methods & METHOD_FINDMY != 0)      { score += 70; count += 1; }
    if (methods & METHOD_RAVEN != 0)       { score += 70; count += 1; }
    if (methods & METHOD_RAVEN_LOW != 0)   { score += 40; count += 1; }
    if (methods & METHOD_TILE != 0)        { score += 45; count += 1; }
    if (methods & METHOD_DRONE != 0)       { score += 60; count += 1; }
    if (methods & METHOD_SIDEWALK != 0)    { score += 50; count += 1; }
    if (methods & METHOD_WIFI_DRONE != 0)  { score += 85; count += 1; }

    if (count >= 2) score += 20;     // multi-method corroboration
    if (rssi > -50) score += 10;     // strong signal
    if ((mac[0] & 0x03) == 0) {      // static MAC
        score += 10;
    } else if ((mac[0] & 0x02) != 0) { // randomized (locally administered)
        if (score >= 20) score -= 20 else score = 0;
    }

    // Cap OUI-only WiFi hits below MEDIUM. An OUI match tells you what
    // chip is in the device, not what the device is. Without SSID
    // corroboration (Flock-XXXX, camera keywords, Remote ID), a Liteon
    // module in a laptop looks identical to one in a Flock camera.
    // Keep it in the tracker table for logging, but don't alert.
    if ((methods & METHOD_OUI != 0) and
        (methods & METHOD_SSID_PREFIX == 0) and
        (methods & METHOD_SSID_FLOCK == 0) and
        (methods & METHOD_CAM_SSID == 0) and
        (methods & METHOD_WIFI_DRONE == 0))
    {
        if (score > 25) score = 25;
    }

    return if (score > 100) 100 else @intCast(score);
}

// ================================================================
// BLE ADVERTISEMENT PARSER
// ================================================================

/// Parse BLE advertisement data and classify the tracker type + method flags.
/// Iterates the BLE_SIGNATURES table for manufacturer/service UUID matches.
/// Raven detection has special multi-UUID counting for firmware classification.
pub fn classifyBle(adv_data: []const u8) ClassResult {
    var methods: u16 = 0;
    var kind: display.TrackerType = .unknown;
    var raven_uuids: u8 = 0;
    var raven_fw_major: u8 = 0;

    var pos: usize = 0;
    var handled_findmy: bool = false;
    while (pos + 1 < adv_data.len) {
        const len = adv_data[pos];
        if (len == 0) break;
        if (pos + 1 + len > adv_data.len) break;
        const ad_type = adv_data[pos + 1];
        const payload = adv_data[pos + 2 .. pos + 1 + len];

        // Manufacturer specific data (AD type 0xFF)
        if (ad_type == 0xFF and payload.len >= 2) {
            const company: u16 = @as(u16, payload[0]) | (@as(u16, payload[1]) << 8);

            // Apple Find My special check: company 0x004C + byte 2 == 0x12
            if (company == 0x004C and payload.len >= 3 and payload[2] == 0x12) {
                handled_findmy = true;
                // AirTags send 28+ bytes (status + full public key).
                // iPhones/iPads send only 4-8 bytes (short status).
                if (payload.len >= 22) {
                    kind = .airtag;
                    methods |= METHOD_FINDMY;
                }
            }

            // Iterate signature table for company_id matches
            for (BLE_SIGNATURES) |sig| {
                if (sig.company_id != null and sig.company_id.? == company) {
                    if (sig.company_id.? == 0x004C and handled_findmy) continue;
                    if (sig.tracker_type != .unknown) kind = sig.tracker_type;
                    methods |= sig.method;
                }
            }
        }

        // 16-bit service UUIDs (AD types 0x02/0x03)
        if ((ad_type == 0x02 or ad_type == 0x03) and payload.len >= 2) {
            var u: usize = 0;
            while (u + 1 < payload.len) : (u += 2) {
                const uuid: u16 = @as(u16, payload[u]) | (@as(u16, payload[u + 1]) << 8);

                // Raven — special multi-UUID counting (kept separate for FW classification)
                if (uuid == 0x180A or uuid == 0x3100 or uuid == 0x3200 or
                    uuid == 0x3300 or uuid == 0x3400 or uuid == 0x3500 or
                    uuid == 0x1809 or uuid == 0x1819) {
                    raven_uuids += 1;
                    if (uuid == 0x3400 or uuid == 0x3500) raven_fw_major = 3;
                    if (uuid == 0x3100 or uuid == 0x3200 or uuid == 0x3300) {
                        if (raven_fw_major < 2) raven_fw_major = 2;
                    }
                    if (uuid == 0x1809 or uuid == 0x1819) {
                        if (raven_fw_major < 1) raven_fw_major = 1;
                    }
                }

                // Iterate signature table for service UUID matches
                for (BLE_SIGNATURES) |sig| {
                    for (sig.service_uuids) |su| {
                        if (uuid == su) {
                            if (sig.tracker_type != .unknown) kind = sig.tracker_type;
                            methods |= sig.method;
                        }
                    }
                }
            }
        }

        if (ad_type == 0x08 or ad_type == 0x09) {
            if (payload.len > 0) methods |= METHOD_BLE_NAME;
        }

        pos += 1 + len;
    }

    // Raven classification: 2+ UUIDs = confirmed, 1 UUID = possible (generic 0x180A alone is not reliable)
    if (raven_uuids >= 2) {
        kind = .raven;
        methods |= METHOD_RAVEN;
        switch (raven_fw_major) {
            3 => methods |= RAVEN_FW_1_3,
            2 => methods |= RAVEN_FW_1_2,
            1 => methods |= RAVEN_FW_1_1,
            else => {},
        }
    } else if (raven_uuids == 1) {
        kind = .raven;
        methods |= METHOD_RAVEN_LOW;
    }

    return .{ .kind = kind, .methods = methods };
}

/// Classify a WiFi detection based on OUI match and SSID pattern.
pub fn classifyWiFi(mac: [6]u8, ssid: []const u8) ClassResult {
    const oui_match = matchOui(mac);
    var methods: u16 = 0;
    var kind: display.TrackerType = .unknown;

    if (oui_match) methods |= METHOD_OUI;

    // Camera SSID keywords — case-insensitive match
    const cam_keywords = [_][]const u8{ "hikvision", "dahua", "reolink", "camera", "cam_", "amcrest", "ring" };
    for (cam_keywords) |kw| {
        if (ssid.len >= kw.len) {
            var match = true;
            for (kw, 0..) |kc, ki| {
                const sc = std.ascii.toLower(ssid[ki]);
                if (sc != std.ascii.toLower(kc)) { match = false; break; }
            }
            if (match) {
                methods |= METHOD_CAM_SSID;
                break;
            }
        }
    }

    // Carrier SSID probes (IMSI catcher indicator) — count unique carrier SSIDs
    const carrier_ssids = [_][]const u8{ "attwifi", "VerizonWiFi", "xfinitywifi", "T-Mobile", "vodafone", "EE WiFi", "Orange", "o2wifi" };
    for (carrier_ssids) |cs| {
        if (ssid.len >= cs.len) {
            var match = true;
            for (cs, 0..) |kc, ki| {
                const sc = std.ascii.toLower(ssid[ki]);
                if (sc != std.ascii.toLower(kc)) { match = false; break; }
            }
            if (match) {
                carrier_probes += 1;
                burst_recent_count += 1;
                break;
            }
        }
    }

    if (ssid.len >= 5) {
        const prefix = [5]u8{ 'F', 'L', 'O', 'C', 'K' };
        if (std.mem.eql(u8, ssid[0..5], &prefix)) {
            methods |= METHOD_SSID_PREFIX;
            // Check full Flock-XXXX format: 10 chars total (Flock-XXXX)
            if (ssid.len == 10 and ssid[5] == '-') {
                // Validate XXXX is hex digits
                const hex = ssid[6..10];
                var valid_hex = true;
                for (hex) |h| {
                    if (!std.ascii.isHex(h)) { valid_hex = false; break; }
                }
                if (valid_hex) methods |= METHOD_SSID_FLOCK;
            }
        }
    }

    if (oui_match and (methods & METHOD_SSID_PREFIX != 0)) {
        kind = .flock_camera;
    } else if (oui_match and (methods & METHOD_CAM_SSID != 0)) {
        kind = .camera;
    } else if (oui_match) {
        kind = .wifi_device;
    } else if (methods & METHOD_CAM_SSID != 0) {
        kind = .camera; // camera SSID even without known OUI
    }

    return .{ .kind = kind, .methods = methods };
}

// ================================================================
// STINGRAY BURST DETECTOR — bucket rotation + spike analysis
// ================================================================

/// Append a Stingray event to the CSV log. Uses the same 8-column schema
/// as logCsv() (time,kind,mac,rssi,score,lat,lon,methods) so the log stays
/// uniformly parseable; the probe count rides in the score column.
fn logStingray() void {
    const loc = stingray_last_location orelse [2]i32{ 0, 0 };
    var line: [80]u8 = undefined;
    const s = std.fmt.bufPrint(&line, "{d},STINGRAY,000000000000,0,{d},{d},{d},0000\n", .{
        main.tick_ms, stingray_probe_count, loc[0], loc[1],
    }) catch return;
    line[s.len] = 0; // null-terminate for the C spiffs_append_line()
    _ = main.spiffs_append_line("detections.csv", line[0..s.len :0].ptr);
}

/// Spike analysis on the just-closed bucket. Called after each rotation.
fn detectBurst() void {
    // Rolling average over every bucket EXCEPT the just-closed one at
    // burst_bucket_idx, so a spike never inflates its own baseline.
    var sum: u32 = 0;
    var active: u32 = 0;
    for (0..BURST_WINDOW_BUCKETS) |i| {
        if (i == burst_bucket_idx) continue;
        if (burst_buckets[i] > 0) {
            sum += burst_buckets[i];
            active += 1;
        }
    }
    if (active < 3) return; // need at least 3 buckets for a baseline
    const avg: u32 = sum / active;
    if (avg == 0) return;

    const recent = burst_buckets[burst_bucket_idx]; // the bucket we just closed
    if (recent < 4 or recent < avg * BURST_THRESHOLD_MULTIPLIER) return;

    const now = main.tick_ms;
    // Confirm: a prior spike within the confirm window → raise the alert.
    if (burst_last_spike_at != 0 and
        (now -% burst_last_spike_at) < BURST_CONFIRM_BUCKETS * BURST_BUCKET_MS)
    {
        if (!stingray_alert_active) { // rising edge — log exactly once
            stingray_alert_active = true;
            stingray_alert_ms = now;
            stingray_probe_count = recent;
            if (gps_fix) stingray_last_location = .{ gps_lat, gps_lon };
            logStingray();
        }
    }
    burst_last_spike_at = now;
}

/// Rotate the bucket window forward once BURST_BUCKET_MS has elapsed.
/// Call once per main-loop iteration from zig_main().
pub fn burstTick(now_ms: u32) void {
    if (burst_bucket_start_ms == 0) {
        burst_bucket_start_ms = now_ms;
        return;
    }
    if ((now_ms -% burst_bucket_start_ms) < BURST_BUCKET_MS) return;

    burst_bucket_idx = (burst_bucket_idx + 1) % BURST_WINDOW_BUCKETS;
    burst_buckets[burst_bucket_idx] = burst_recent_count;
    burst_recent_count = 0;
    burst_bucket_start_ms = now_ms;

    detectBurst();
}

/// Auto-clear an active alert after STINGRAY_CLEAR_MS with no new spike.
pub fn burstClearCheck(now_ms: u32) void {
    if (stingray_alert_active and (now_ms -% stingray_alert_ms) > STINGRAY_CLEAR_MS) {
        stingray_alert_active = false;
    }
}

// ================================================================
// TRACKER TABLE UPDATES
// ================================================================

/// Detect rise-peak-fall RSSI pattern — indicates a stationary transmitter
/// (camera, sensor) that the scanner approached then passed.
/// Checks the 5-value ring buffer for a multi-sighting trend.
fn detectRssiTrend(history: [5]i8) bool {
    // Need at least 3 valid values (non-zero, since 0 = uninitialized)
    const values = history;
    var count: u8 = 0;
    for (values) |v| {
        if (v != 0) count += 1;
    }
    if (count < 3) return false;

    // Rotate to chronological order based on hidx (older → newer)
    // For simplicity: check if any 3 consecutive values show rise then fall
    var rising: bool = false;
    for (0..4) |i| {
        if (values[i] == 0 or values[i+1] == 0) continue;
        if (values[i] < values[i+1]) {
            rising = true;
        } else if (rising and values[i] > values[i+1]) {
            return true; // rise followed by fall = stationary
        }
    }
    return false;
}

/// Add or update a tracker entry. Accumulates detection methods across
/// observations, keeps the best RSSI, and recomputes confidence score.
/// Returns true if this is a new tracker (for alert triggering).
pub fn trackDevice(mac: [6]u8, result: ClassResult, rssi: i8) bool {
    // Reject unclassified devices — don't waste tracker slots on noise
    if (result.methods == 0) return false;

    // Pre-compute score for filter check
    const score = computeScore(result.methods, rssi, mac);

    // Skip randomized MACs with low confidence — phones rotate addresses
    // and appear as new entries. Don't waste tracker table slots on them.
    if (score < SCORE_MED and (mac[0] & 0x02) != 0) return false;

    for (0..main.tracker_count) |i| {
        if (std.mem.eql(u8, &main.trackers[i].mac, &mac)) {
            main.trackers[i].methods |= result.methods;
            if (result.kind != .unknown) main.trackers[i].kind = result.kind;
            if (rssi > main.trackers[i].rssi) main.trackers[i].rssi = rssi;
            main.trackers[i].last_seen = main.tick_ms;
            // Push RSSI into 5-value history ring buffer for trend detection
            main.trackers[i].rssi_history[main.trackers[i].rssi_hidx] = rssi;
            main.trackers[i].rssi_hidx +%= 1;
            main.trackers[i].score = computeScore(main.trackers[i].methods, main.trackers[i].rssi, mac);
            // RSSI trend bonus: rise-peak-fall = stationary device (camera, sensor)
            if (detectRssiTrend(main.trackers[i].rssi_history)) {
                if (main.trackers[i].score < 90) main.trackers[i].score += 10;
            }
            return false;
        }
    }

    // New tracker
    const entry = main.TrackerEntry{
        .mac = mac,
        .kind = result.kind,
        .rssi = rssi,
        .last_seen = main.tick_ms,
        .score = score,
        .methods = result.methods,
        .rssi_history = [_]i8{0} ** 5,
        .rssi_hidx = 0,
        .source = 0,
    };

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
    return true;
}

// ================================================================
// DETECTION COUNTS BY KIND (shared by OLED summary + dashboard API)
// ================================================================

/// Per-kind detection counts plus surveillance/tracker rollups.
pub const KindCounts = struct {
    flock_camera: u32 = 0,
    wifi_device: u32 = 0,
    drone: u32 = 0,
    raven: u32 = 0,
    camera: u32 = 0,
    airtag: u32 = 0,
    tile: u32 = 0,
    samsung: u32 = 0,
    findmy: u32 = 0,
    surv: u32 = 0,
    track: u32 = 0,
};

/// Tally the tracker table by kind. Surveillance = flock/wifi/drone/raven/camera;
/// everything else counts as a consumer tracker.
pub fn countByKind() KindCounts {
    var c = KindCounts{};
    for (0..main.tracker_count) |i| {
        switch (main.trackers[i].kind) {
            .flock_camera => { c.flock_camera += 1; c.surv += 1; },
            .wifi_device => { c.wifi_device += 1; c.surv += 1; },
            .drone => { c.drone += 1; c.surv += 1; },
            .raven => { c.raven += 1; c.surv += 1; },
            .camera => { c.camera += 1; c.surv += 1; },
            .airtag => { c.airtag += 1; c.track += 1; },
            .tile => { c.tile += 1; c.track += 1; },
            .samsung => { c.samsung += 1; c.track += 1; },
            .findmy => { c.findmy += 1; c.track += 1; },
            else => { c.track += 1; },
        }
    }
    return c;
}

// ================================================================
// SESSION PERSISTENCE
// ================================================================

/// Session counter — total unique detections since first boot.
/// Saved to /spiffs/session.dat and restored on boot.
pub var session_total: u32 = 0;

/// Persist session counter to SPIFFS.
pub fn saveSession() void {
    var buf: [16]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{session_total}) catch return;
    _ = main.spiffs_write_file("session.dat", s.ptr, s.len);
}

/// Restore session counter from SPIFFS on boot.
pub fn restoreSession() void {
    var buf: [16]u8 = undefined;
    const n = main.spiffs_read_file("session.dat", &buf, buf.len);
    if (n > 0) {
        session_total = std.fmt.parseInt(u32, buf[0..@intCast(n)], 10) catch 0;
    }
}

// ================================================================
// GPS POSITION + NMEA PARSER
// ================================================================

/// GPS position — lat/lon in decimal degrees × 10^6.
/// 0 means no fix yet. Updated by parseNmea().
pub var gps_lat: i32 = 0;   // e.g. 38117300 = 38.117300°
pub var gps_lon: i32 = 0;   // e.g. -90199400 = -90.199400°
pub var gps_fix: bool = false;
pub var gps_sats: u8 = 0;

/// NMEA sentence line accumulator. gps_read() fills this buffer,
/// and on '\n', parseNmea() processes the complete sentence.
pub var gps_line: [128]u8 = undefined;
pub var gps_line_pos: usize = 0;

/// Parse a complete NMEA sentence and extract GPS fix data.
/// Handles $GPGGA (fix, sats) and $GPRMC (time, lat, lon).
pub fn parseNmea(line: []const u8) void {
    // Must start with '$'
    if (line.len < 10 or line[0] != '$') return;

    // Find first comma
    var start: usize = 0;
    for (line, 0..) |c, i| {
        if (c == ',') { start = i + 1; break; }
        if (i > 6) return; // sentence ID too long
    }
    if (start == 0) return;

    // Check sentence type (2nd char after $)
    const talker = line[1..start-1];

    // $GPGGA — fix data
    if (talker.len >= 5 and std.mem.eql(u8, talker[talker.len-5..], "GPGGA")) {
        var fields: [15][]const u8 = undefined;
        var fi: usize = 0;
        var pos: usize = start;
        while (fi < 15 and pos < line.len) : (fi += 1) {
            const end = std.mem.indexOfScalarPos(u8, line, pos, ',') orelse line.len;
            fields[fi] = line[pos..end];
            pos = end + 1;
        }

        // Field 2: lat (DDMM.MMMM), 6: quality, 7: sats, 4: lon (DDDMM.MMMM)
        if (fi >= 8 and fields[2].len > 0 and fields[4].len > 0) {
            gps_lat = parseNmeaCoord(fields[2], if (fi >= 4) fields[3] else "N");
            gps_lon = parseNmeaCoord(fields[4], if (fi >= 6) fields[5] else "E");

            // Fix quality: 0=invalid, 1=GPS, 2=DGPS
            gps_fix = fi >= 7 and fields[6].len > 0 and fields[6][0] != '0';

            // Satellite count
            if (fi >= 8 and fields[7].len > 0) {
                gps_sats = std.fmt.parseInt(u8, fields[7], 10) catch 0;
            }
        }
        return;
    }

    // $GPRMC — recommended minimum (fallback for lat/lon)
    if (talker.len >= 5 and std.mem.eql(u8, talker[talker.len-5..], "GPRMC")) {
        var fields: [10][]const u8 = undefined;
        var fi: usize = 0;
        var pos: usize = start;
        while (fi < 10 and pos < line.len) : (fi += 1) {
            const end = std.mem.indexOfScalarPos(u8, line, pos, ',') orelse line.len;
            fields[fi] = line[pos..end];
            pos = end + 1;
        }

        // Field 2: status (A=valid), 3: lat, 4: NS, 5: lon, 6: EW
        if (fi >= 6 and fields[2].len > 0 and fields[2][0] == 'A') {
            const lat = parseNmeaCoord(fields[3], fields[4]);
            const lon = parseNmeaCoord(fields[5], fields[6]);
            if (lat != 0) gps_lat = lat;
            if (lon != 0) gps_lon = lon;
            gps_fix = true;
        }
    }
}

/// Parse NMEA coordinate: DDMM.MMMM or DDDMM.MMMM → decimal degrees × 10^6.
/// direction: "N"/"S"/"E"/"W" — determines sign.
pub fn parseNmeaCoord(raw: []const u8, dir: []const u8) i32 {
    if (raw.len < 4) return 0;

    // Find decimal point
    const dot = std.mem.indexOfScalar(u8, raw, '.') orelse return 0;
    const deg_part = raw[0..dot-2];    // everything before MM
    const min_part = raw[dot-2..];     // MM.MMMM

    const deg: i32 = std.fmt.parseInt(i32, deg_part, 10) catch return 0;
    const min: i32 = std.fmt.parseInt(i32, min_part[0..2], 10) catch return 0;
    // Minutes fraction
    var frac: i32 = 0;
    if (min_part.len > 3) {
        frac = std.fmt.parseInt(i32, min_part[3..], 10) catch 0;
    }

    // Convert: degrees + minutes/60, then × 10^6
    // min_fraction = min * 1000000 / 60 + frac_factor
    const min_scaled = @divTrunc(min * 1000000, 60) + @divTrunc(frac * 10000, 6000);
    var result = deg * 1000000 + min_scaled;

    // Apply sign
    if (dir.len > 0 and (dir[0] == 'S' or dir[0] == 'W')) {
        result = -result;
    }

    return result;
}

// ================================================================
// CSV DETECTION LOG
// ================================================================

/// Append a detection event to the CSV log.
/// Looks up the tracker entry to get the accumulated score.
pub fn logCsv(mac: [6]u8, rssi: i8) void {
    // Find the tracker entry for this MAC to get accumulated score
    for (0..main.tracker_count) |i| {
        if (std.mem.eql(u8, &main.trackers[i].mac, &mac)) {
            const ks = display.kindStr(main.trackers[i].kind);
            const methods = main.trackers[i].methods;
            const score = main.trackers[i].score;

            // Skip unclassified noise — don't waste SPIFFS space
            if (methods == 0) return;

            var line: [110]u8 = undefined;
            const s = std.fmt.bufPrint(&line, "{d},{s},{X:0>2}{X:0>2}{X:0>2}{X:0>2}{X:0>2}{X:0>2},{d},{d},{d},{d},{X:0>2}\n", .{
                main.tick_ms, ks,
                mac[0], mac[1], mac[2], mac[3], mac[4], mac[5],
                rssi, score, gps_lat, gps_lon, methods,
            }) catch return;
            line[s.len] = 0; // null-terminate for C
            _ = main.spiffs_append_line("detections.csv", line[0..s.len :0].ptr);
            return;
        }
    }
}

/// Drone model name extracted from WiFi Remote ID Self-ID message.
/// Set by parseDroneRemoteId(), read by display.zig for threats + proximity pages.
pub var drone_model_buf: [24]u8 = [_]u8{0} ** 24;

/// Parse ASTM F3411 WiFi Remote ID payload from tag 221 IE.
/// Message format: [type:1B][flags:1B][data...]
/// Type 0: Basic ID (drone serial)
/// Type 1: Location (lat/lon/alt/speed)
/// Type 2: Self-ID (free text, typically "DJI Mini 3 Pro")
/// Returns detection method flags.
pub fn parseDroneRemoteId(rid: []const u8) u16 {
    if (rid.len < 2) return 0;

    const msg_type = rid[0] & 0x0F; // low nibble = message type
    const payload = rid[1..];

    if (msg_type == 2 and payload.len > 0) {
        const txt_len = @min(payload.len, @as(usize, @intCast(payload[0]))) + 1;
        const txt = payload[0..txt_len];
        // Store model name for display
        const copy_len = @min(txt.len, drone_model_buf.len - 1);
        @memcpy(drone_model_buf[0..copy_len], txt[0..copy_len]);
        drone_model_buf[copy_len] = 0;
        return METHOD_WIFI_DRONE;
    }

    // Type 0 (Basic ID) or Type 1 (Location) also valid Remote ID
    if (msg_type == 0 or msg_type == 1) {
        return METHOD_WIFI_DRONE;
    }

    return 0;
}
