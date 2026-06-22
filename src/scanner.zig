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
pub const METHOD_CAM_SSID: u16  = 1 << 12; // SSID contains camera keyword (30 pts)
pub const METHOD_SIDEWALK: u16   = 1 << 13; // Amazon Sidewalk device (50 pts)
pub const METHOD_WIFI_DRONE: u16  = 1 << 14; // WiFi Remote ID tag 221 (85 pts)

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

    return if (score > 100) 100 else @intCast(score);
}

// ================================================================
// BLE ADVERTISEMENT PARSER
// ================================================================

/// Parse BLE advertisement data and classify the tracker type + method flags.
pub fn classifyBle(adv_data: []const u8) ClassResult {
    var methods: u16 = 0;
    var kind: display.TrackerType = .unknown;
    var raven_uuids: u8 = 0; // count of Raven UUIDs found
    var raven_fw_major: u8 = 0;

    var pos: usize = 0;
    while (pos + 1 < adv_data.len) {
        const len = adv_data[pos];
        if (len == 0) break;
        if (pos + 1 + len > adv_data.len) break;
        const ad_type = adv_data[pos + 1];
        const payload = adv_data[pos + 2 .. pos + 1 + len];

        if (ad_type == 0xFF and payload.len >= 3) {
            const company: u16 = @as(u16, payload[0]) | (@as(u16, payload[1]) << 8);
            if (company == 0x004C and payload.len >= 3 and payload[2] == 0x12) {
                kind = .airtag;
                methods |= METHOD_FINDMY;
            }
            if (company == 0x0075) {
                kind = .samsung;
                methods |= METHOD_MANUF;
            }
            // Amazon Sidewalk (Ring, Echo, Tile via Sidewalk)
            if (company == 0x0171) {
                methods |= METHOD_SIDEWALK;
            }
            if (company == 0x09C8) {
                methods |= METHOD_MANUF;
                if (kind == .unknown) kind = .unknown;
            }
        }

        if ((ad_type == 0x02 or ad_type == 0x03) and payload.len >= 2) {
            var u: usize = 0;
            while (u + 1 < payload.len) : (u += 2) {
                const uuid: u16 = @as(u16, payload[u]) | (@as(u16, payload[u + 1]) << 8);
                if (uuid == 0xFEED) {
                    kind = .tile;
                    methods |= METHOD_TILE;
                }
                if (uuid == 0xFFFA) {
                    kind = .drone;
                    methods |= METHOD_DRONE;
                }
                // Raven/ShotSpotter gunshot sensor UUIDs
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
            }
        }

        if (ad_type == 0x08 or ad_type == 0x09) {
            // Complete or shortened local name
            if (payload.len > 0) methods |= METHOD_BLE_NAME;
        }

        pos += 1 + len;
    }

    // Raven classification: 1+ service UUIDs = confirmed
    if (raven_uuids >= 1) {
        kind = .raven;
        methods |= METHOD_RAVEN;
        // Encode firmware version in method flags for display
        switch (raven_fw_major) {
            3 => methods |= RAVEN_FW_1_3,
            2 => methods |= RAVEN_FW_1_2,
            1 => methods |= RAVEN_FW_1_1,
            else => {},
        }
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
    const cam_keywords = [_][]const u8{ "hikvision", "dahua", "reolink", "camera", "cam_" };
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
// TRACKER TABLE UPDATES
// ================================================================

/// Add or update a tracker entry. Accumulates detection methods across
/// observations, keeps the best RSSI, and recomputes confidence score.
/// Returns true if this is a new tracker (for alert triggering).
pub fn trackDevice(mac: [6]u8, result: ClassResult, rssi: i8) bool {
    for (0..main.tracker_count) |i| {
        if (std.mem.eql(u8, &main.trackers[i].mac, &mac)) {
            main.trackers[i].methods |= result.methods;
            if (result.kind != .unknown) main.trackers[i].kind = result.kind;
            if (rssi > main.trackers[i].rssi) main.trackers[i].rssi = rssi;
            main.trackers[i].last_seen = main.tick_ms;
            main.trackers[i].score = computeScore(main.trackers[i].methods, main.trackers[i].rssi, mac);
            return false;
        }
    }

    // New tracker
    const score = computeScore(result.methods, rssi, mac);
    const entry = main.TrackerEntry{
        .mac = mac,
        .kind = result.kind,
        .rssi = rssi,
        .last_seen = main.tick_ms,
        .score = score,
        .methods = result.methods,
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

/// Parse ASTM F3411 WiFi Remote ID payload from tag 221 IE.
/// Message format: [type:1B][flags:1B][data...]
/// Type 0: Basic ID (drone serial)
/// Type 1: Location (lat/lon/alt/speed)
/// Type 2: Self-ID (free text, typically "DJI Mini 3 Pro")
/// Returns methods flags to OR into the classification result.
pub fn parseDroneRemoteId(rid: []const u8) u16 {
    if (rid.len < 2) return 0;

    const msg_type = rid[0] & 0x0F; // low nibble = message type
    const payload = rid[1..];

    if (msg_type == 2 and payload.len > 0) {
        // Self-ID message — drone model name in free text
        // Most DJI drones broadcast "DJI Mini 3 Pro" or similar
        const txt = payload[0..@min(payload.len, @as(usize, @intCast(payload[0]))) + 1];
        _ = txt; // model name text — for display, we just flag the detection
        return METHOD_WIFI_DRONE;
    }

    // Type 0 (Basic ID) or Type 1 (Location) also valid Remote ID
    if (msg_type == 0 or msg_type == 1) {
        return METHOD_WIFI_DRONE;
    }

    return 0;
}
