//! === ARGUS — Dashboard JSON API renderers ===
//!
//! All detection state lives in Zig (tracker table, counts, mesh peers),
//! so the HTTP layer (main/httpd.c) delegates JSON serialization here.
//! Each exported function writes a JSON body into a caller-provided buffer
//! and returns the number of bytes written. The httpd worker is single-
//! threaded, so a shared scratch buffer on the C side is safe.

const std = @import("std");
const main = @import("main.zig");
const scanner = @import("scanner.zig");
const display = @import("display.zig");
const mesh = @import("mesh.zig");
const config = @import("config.zig");
const analysis = @import("analysis.zig");

const FIRMWARE_VERSION = main.FIRMWARE_VERSION;
const MAX_DETECTIONS = 50;

/// Minimal append-only JSON writer over a fixed buffer.
const Buf = struct {
    data: []u8,
    len: usize = 0,

    fn add(self: *Buf, comptime fmt: []const u8, args: anytype) void {
        if (self.len >= self.data.len) return;
        const s = std.fmt.bufPrint(self.data[self.len..], fmt, args) catch return;
        self.len += s.len;
    }

    /// Append a JSON string value with quotes and minimal escaping.
    fn addStr(self: *Buf, s: []const u8) void {
        self.add("\"", .{});
        for (s) |c| {
            switch (c) {
                '"' => self.add("\\\"", .{}),
                '\\' => self.add("\\\\", .{}),
                '\n', '\r', '\t' => self.add(" ", .{}),
                else => self.add("{c}", .{c}),
            }
        }
        self.add("\"", .{});
    }
};

fn boolStr(b: bool) []const u8 {
    return if (b) "true" else "false";
}

fn gpsStateStr() []const u8 {
    if (scanner.gps_fix) return "fix";
    if (scanner.gpsAlive()) return "searching";
    return "nosignal";
}

fn kindName(kind: display.TrackerType) []const u8 {
    return switch (kind) {
        .airtag => "airtag",
        .tile => "tile",
        .samsung => "samsung",
        .findmy => "findmy",
        .flock_camera => "flock_camera",
        .wifi_device => "wifi_device",
        .drone => "drone",
        .raven => "raven",
        .camera => "camera",
        .unknown => "unknown",
        else => "unknown",
    };
}

fn levelName(score: u8) []const u8 {
    if (score >= scanner.SCORE_CERT) return "CERT";
    if (score >= scanner.SCORE_HIGH) return "HIGH";
    if (score >= scanner.SCORE_MED) return "MED";
    return "LOW";
}

/// Append a '+'-joined list of the primary detection-method names.
fn addMethods(b: *Buf, methods: u32) void {
    b.add("\"", .{});
    var first = true;
    const Pair = struct { flag: u32, name: []const u8 };
    const map = [_]Pair{
        .{ .flag = scanner.METHOD_OUI, .name = "oui" },
        .{ .flag = scanner.METHOD_SSID_PREFIX, .name = "ssid" },
        .{ .flag = scanner.METHOD_SSID_FLOCK, .name = "flock" },
        .{ .flag = scanner.METHOD_BLE_NAME, .name = "name" },
        .{ .flag = scanner.METHOD_MANUF, .name = "manuf" },
        .{ .flag = scanner.METHOD_FINDMY, .name = "findmy" },
        .{ .flag = scanner.METHOD_RAVEN, .name = "raven" },
        .{ .flag = scanner.METHOD_TILE, .name = "tile" },
        .{ .flag = scanner.METHOD_DRONE, .name = "drone" },
        .{ .flag = scanner.METHOD_SIDEWALK, .name = "sidewalk" },
        .{ .flag = scanner.METHOD_WIFI_DRONE, .name = "wifi_drone" },
        .{ .flag = scanner.METHOD_CAM_SSID, .name = "cam" },
        .{ .flag = scanner.METHOD_WILDCARD_PROBE, .name = "wildcard" },
    };
    for (map) |m| {
        if (methods & m.flag != 0) {
            if (!first) b.add("+", .{});
            b.add("{s}", .{m.name});
            first = false;
        }
    }
    b.add("\"", .{});
}

// ================================================================
// GET /api/status
// ================================================================
pub export fn zig_api_status(out: [*]u8, max: u32) callconv(.c) u32 {
    var b = Buf{ .data = out[0..max] };
    const c = scanner.countByKind();
    const mv = main.battery_read_mv();
    const surv = c.surv + @as(u32, if (scanner.stingray_alert_active) 1 else 0);

    b.add("{{", .{});
    b.add("\"uptime_seconds\":{d},", .{main.tick_ms / 1000});
    b.add("\"battery_mv\":{d},", .{mv});
    b.add("\"battery_pct\":{d},", .{display.batteryPct(mv)});
    b.add("\"surv_count\":{d},", .{surv});
    b.add("\"track_count\":{d},", .{c.track});
    b.add("\"followed_count\":{d},", .{scanner.followedCount()});
    b.add("\"surv_breakdown\":{{\"flock_camera\":{d},\"wifi_device\":{d},\"drone\":{d},\"raven\":{d},\"camera\":{d}}},", .{
        c.flock_camera, c.wifi_device, c.drone, c.raven, c.camera,
    });
    b.add("\"track_breakdown\":{{\"airtag\":{d},\"tile\":{d},\"samsung\":{d},\"findmy\":{d}}},", .{
        c.airtag, c.tile, c.samsung, c.findmy,
    });
    b.add("\"stingray_active\":{s},", .{boolStr(scanner.stingray_alert_active)});
    b.add("\"deployment_active\":{s},", .{boolStr(analysis.deployment_alert_active)});
    b.add("\"deployment_score\":{d},", .{analysis.deployment_score});
    b.add("\"deployment_devices\":{d},", .{analysis.deployment_device_count});
    b.add("\"mesh_peers\":{d},", .{mesh.onlinePeerCount()});
    b.add("\"total_detections\":{d},", .{scanner.session_total});
    b.add("\"threat_level\":\"{s}\",", .{main.threatLevelStr()});
    b.add("\"gps_state\":\"{s}\",", .{gpsStateStr()});
    b.add("\"gps_sats\":{d},", .{scanner.gps_sats});
    b.add("\"gps_sats_in_view\":{d},", .{scanner.gps_sats_in_view});
    b.add("\"gps_lat\":{d},", .{scanner.gps_lat});
    b.add("\"gps_lon\":{d},", .{scanner.gps_lon});
    b.add("\"free_heap_kb\":{d},", .{main.free_heap_kb()});
    b.add("\"wifi_dropped\":{d},", .{main.wifi_get_dropped_count()});
    b.add("\"ble_dropped\":{d},", .{main.ble_scan_dropped()});
    b.add("\"firmware_version\":\"{s}\"", .{FIRMWARE_VERSION});
    b.add("}}", .{});
    return @intCast(b.len);
}

// ================================================================
// GET /api/detections — newest-first snapshot of the tracker table
// ================================================================
pub export fn zig_api_detections(out: [*]u8, max: u32) callconv(.c) u32 {
    var b = Buf{ .data = out[0..max] };
    b.add("[", .{});

    var emitted: u32 = 0;
    var i: usize = main.tracker_count;
    while (i > 0 and emitted < MAX_DETECTIONS) {
        i -= 1;
        const t = main.trackers[i];
        if (emitted > 0) b.add(",", .{});
        b.add("{{", .{});
        b.add("\"time_ms\":{d},", .{t.last_seen});
        b.add("\"kind\":\"{s}\",", .{kindName(t.kind)});
        b.add("\"oui\":\"{X:0>2}:{X:0>2}:{X:0>2}\",", .{ t.mac[0], t.mac[1], t.mac[2] });
        b.add("\"mac_hash\":\"{X:0>2}{X:0>2}{X:0>2}\",", .{ t.mac[3], t.mac[4], t.mac[5] });
        b.add("\"rssi\":{d},", .{t.rssi});
        b.add("\"score\":{d},", .{t.score});
        b.add("\"level\":\"{s}\",", .{levelName(t.score)});
        b.add("\"methods\":", .{});
        addMethods(&b, t.methods);
        b.add(",", .{});
        b.add("\"source\":\"{s}\",", .{if (t.source == 1) "mesh" else "direct"});
        b.add("\"followed\":{s},", .{boolStr(scanner.isFollowed(t))});
        const dlat = if (t.source == 1) t.mesh_lat else scanner.gps_lat;
        const dlon = if (t.source == 1) t.mesh_lon else scanner.gps_lon;
        b.add("\"lat\":{d},", .{dlat});
        b.add("\"lon\":{d}", .{dlon});
        b.add("}}", .{});
        emitted += 1;
    }

    b.add("]", .{});
    return @intCast(b.len);
}

// ================================================================
// GET /api/mesh — peer list
// ================================================================
pub export fn zig_api_mesh(out: [*]u8, max: u32) callconv(.c) u32 {
    var b = Buf{ .data = out[0..max] };
    b.add("[", .{});
    for (0..mesh.peer_count) |i| {
        const p = mesh.peers[i];
        if (i > 0) b.add(",", .{});
        b.add("{{", .{});
        b.add("\"id\":\"UNIT-{d:0>2}\",", .{p.id});
        b.add("\"last_seen_seconds\":{d},", .{(main.tick_ms -% p.last_seen) / 1000});
        b.add("\"rssi\":{d},", .{p.rssi});
        b.add("\"lat\":{d},", .{p.lat});
        b.add("\"lon\":{d},", .{p.lon});
        b.add("\"detections_shared\":{d}", .{p.shared});
        b.add("}}", .{});
    }
    b.add("]", .{});
    return @intCast(b.len);
}

// ================================================================
// GET /api/cameras — aggregated mesh camera map (base station)
// ================================================================
pub export fn zig_api_cameras(out: [*]u8, max: u32) callconv(.c) u32 {
    var b = Buf{ .data = out[0..max] };
    b.add("[", .{});
    var emitted: u32 = 0;
    for (0..mesh.camera_map_count) |i| {
        const c = mesh.camera_map[i];
        if (emitted > 0) b.add(",", .{});
        b.add("{{", .{});
        b.add("\"oui\":\"{X:0>2}:{X:0>2}:{X:0>2}\",", .{ c.oui[0], c.oui[1], c.oui[2] });
        b.add("\"id\":\"{X:0>8}\",", .{c.mac_hash});
        b.add("\"kind\":\"{s}\",", .{kindName(c.kind)});
        b.add("\"count\":{d},", .{c.count});
        b.add("\"reporters\":{d},", .{c.reporter_count});
        b.add("\"best_rssi\":{d},", .{c.best_rssi});
        b.add("\"lat\":{d},", .{c.lat});
        b.add("\"lon\":{d},", .{c.lon});
        b.add("\"last_seen_seconds\":{d}", .{(main.tick_ms -% c.last_seen) / 1000});
        b.add("}}", .{});
        emitted += 1;
    }
    b.add("]", .{});
    return @intCast(b.len);
}

// ================================================================
// GET /api/config — current configuration (password omitted)
// ================================================================
pub export fn zig_api_config(out: [*]u8, max: u32) callconv(.c) u32 {
    var b = Buf{ .data = out[0..max] };
    var name_buf: [64]u8 = undefined;
    var role_buf: [16]u8 = undefined;
    var ssid_buf: [64]u8 = undefined;
    var lat_buf: [16]u8 = undefined;
    var lon_buf: [16]u8 = undefined;

    b.add("{{", .{});
    b.add("\"device_name\":", .{});
    b.addStr(config.get("name", &name_buf));
    b.add(",\"role\":", .{});
    b.addStr(config.get("role", &role_buf));
    b.add(",\"wifi_ssid\":", .{});
    b.addStr(config.get("ssid", &ssid_buf));
    b.add(",\"lat\":", .{});
    b.addStr(config.get("lat", &lat_buf));
    b.add(",\"lon\":", .{});
    b.addStr(config.get("lon", &lon_buf));
    b.add(",\"configured\":{s}", .{boolStr(config.isConfigured())});
    b.add("}}", .{});
    return @intCast(b.len);
}

/// /api/history — read last N KB of the SD card detection log and return
/// as a JSON array of raw CSV lines (client-parsed for date/kind filtering).
pub export fn zig_api_history(buf: [*]u8, buf_len: u32) callconv(.c) u32 {
    var b = Buf{ .data = buf[0..buf_len] };
    b.add("[", .{});

    var sd_buf: [4096]u8 = undefined;
    const path: [14:0]u8 = "detections.csv".*;
    const n = main.board.storageRead(&path, &sd_buf, sd_buf.len);
    if (n > 0) {
        const data = sd_buf[0..@intCast(n)];
        var lines = std.mem.splitScalar(u8, data, '\n');
        var first: bool = true;
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;
            if (!first) b.add(",", .{});
            first = false;
            b.addStr(trimmed);
        }
    }

    b.add("]", .{});
    return @intCast(b.len);
}
