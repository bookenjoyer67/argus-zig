//! === Heltec V3 OLED UI — 8-page layout ===
//!
//! The board-specific page layout for the 128x64 SSD1306. Extracted verbatim
//! from the original display.zig; drawing calls go through the shared gfx
//! primitives bound to the ssd1306 backend, and shared label helpers
//! (kindStr/scoreLevel/batteryPct) + page-cycle state live in display.zig.

const std = @import("std");
const main = @import("../main.zig");
const scanner = @import("../scanner.zig");
const display = @import("../display.zig");
const ssd1306 = @import("../hal/ssd1306.zig");
const g = @import("../hal/gfx.zig").Gfx(ssd1306);

// Preserve the original local names so page bodies are unchanged.
const oledClear = g.clear;
const oledUpdate = g.update;
const oledDrawStr = g.drawStr;
const oledDrawInt = g.drawInt;
const oledDrawStrScaled = g.drawStrScaled;
const oledDrawBar = g.drawBar;
const drawArrow = g.drawArrow;
const OLED_WIDTH = ssd1306.WIDTH;

const kindStr = display.kindStr;
const scoreLevel = display.scoreLevel;
const batteryPct = display.batteryPct;

/// Number of pages this board's UI cycles through.
pub const NUM_PAGES: u8 = 8;

// ================================================================
// SCREENS (boot / setup / pairing / OTA)
// ================================================================

/// Boot screen: big centered "ARGUS" with a status line below.
pub fn drawBoot(msg: []const u8) void {
    oledClear();
    // "ARGUS" scale 2 = 5 glyphs × 12px = 60px wide
    oledDrawStrScaled((OLED_WIDTH - 60) / 2, 16, "ARGUS", 2);
    const mw: u8 = @intCast(msg.len * 6);
    const mx: u8 = if (mw < OLED_WIDTH) (OLED_WIDTH - mw) / 2 else 0;
    oledDrawStr(mx, 44, msg);
    oledUpdate();
}

/// First-boot onboarding screen — shows AP name + setup URL.
pub fn drawSetup() void {
    oledClear();
    oledDrawStrScaled(4, 0, "SETUP", 2);
    oledDrawStr(0, 22, "Join WiFi:");
    oledDrawStr(0, 32, "  Argus Setup");
    oledDrawStr(0, 44, "Open in browser:");
    oledDrawStr(0, 54, "  192.168.4.1");
    oledUpdate();
}

/// BLE pairing screen — shows the 6-digit passkey to enter on the phone.
pub fn drawPasskey(passkey: u32) void {
    oledClear();
    oledDrawStrScaled(4, 0, "PAIR", 2);
    oledDrawStr(0, 24, "Enter on phone:");
    var buf: [8]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d:0>6}", .{passkey % 1000000}) catch return;
    // scale 2 = 6 glyphs x 12px = 72px wide; center it.
    oledDrawStrScaled((OLED_WIDTH - 72) / 2, 40, s, 2);
    oledUpdate();
}

/// Firmware-update progress screen (driven by ota.c via ota_progress_pct).
pub fn drawOtaProgress(pct: i32) void {
    oledClear();
    oledDrawStrScaled(4, 0, "UPDATE", 2);
    const p: u8 = if (pct < 0) 0 else @intCast(@min(pct, @as(i32, 100)));
    var buf: [8]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}%", .{p}) catch return;
    const w: u8 = @intCast(s.len * 12);
    oledDrawStrScaled((OLED_WIDTH - w) / 2, 26, s, 2);
    oledDrawBar(8, 50, 112, 10, p);
    oledUpdate();
}

// ================================================================
// DISPLAY PAGES
// ================================================================

/// Draw page number indicator top-right (e.g. "1/7").
fn drawPageNum(page: u8) void {
    var buf: [4]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}/{d}", .{ page + 1, NUM_PAGES }) catch return;
    oledDrawStr(96, 0, s);
}

/// Draw a battery bar: label + voltage + bar graphic.
/// 3.3V = 0%, 4.2V = 100% (LiPo range).
fn drawBatteryBar(x: u8, y: u8, w: u8, h: u8) void {
    const mv = main.battery_read_mv();
    const pct: u8 = batteryPct(mv);

    var buf: [20]u8 = undefined;
    const v = @as(u32, @intCast(mv));
    const s = std.fmt.bufPrint(&buf, "Bat:{d}.{d}V", .{ v / 1000, (v / 100) % 10 }) catch return;
    oledDrawStr(x, y, s);
    oledDrawBar(x + 66, y, w, h, pct);
}

/// Format MAC as hex string: "XX:XX:XX:XX:XX:XX"
fn formatMac(mac: [6]u8, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "{X:0<2}:{X:0<2}:{X:0<2}:{X:0<2}:{X:0<2}:{X:0<2}", .{ mac[0], mac[1], mac[2], mac[3], mac[4], mac[5] }) catch "??:??:??:??:??:??";
}

/// Raven firmware version string from methods flags.
fn ravenFwStr(methods: u16) []const u8 {
    if (methods & scanner.RAVEN_FW_1_3 != 0) return "v1.3";
    if (methods & scanner.RAVEN_FW_1_2 != 0) return "v1.2";
    if (methods & scanner.RAVEN_FW_1_1 != 0) return "v1.1";
    return "";
}

/// Age in seconds since last_seen.
fn ageSec(last: u32) u32 {
    if (main.tick_ms >= last) return (main.tick_ms - last) / 1000;
    return 0;
}

/// Page 0: Threat summary
fn drawSummary() void {
    var surv_count: u32 = 0; // surveillance: ALPR, drone, raven, camera, stingray
    var track_count: u32 = 0; // consumer trackers: AirTag, Tile, Samsung, FindMy
    for (0..main.tracker_count) |i| {
        switch (main.trackers[i].kind) {
            .flock_camera, .drone, .raven, .camera => surv_count += 1,
            else => track_count += 1,
        }
    }
    if (scanner.stingray_alert_active) surv_count += 1;

    oledClear();
    drawPageNum(0);
    oledDrawStr(0, 0, "ARGUS");
    if (scanner.stingray_alert_active) oledDrawStr(0, 8, "!! STINGRAY ?");
    oledDrawStr(0, 18, "SURV:");
    oledDrawInt(48, 18, @intCast(surv_count));
    oledDrawStr(78, 18, "TRACK:");
    oledDrawInt(118, 18, @intCast(track_count));
    oledDrawStr(0, 28, "OUI:");
    oledDrawInt(48, 28, @intCast(main.KNOWN_OUIS_COUNT));
    drawBatteryBar(0, 44, 40, 8);
    // GPS status
    var gps_buf: [24]u8 = undefined;
    if (scanner.gps_fix) {
        _ = std.fmt.bufPrint(&gps_buf, "GPS:{d}.{d} {d}sats", .{
            @divTrunc(scanner.gps_lat, 1000000), @abs(@rem(@divTrunc(scanner.gps_lat, 10000), 100)), scanner.gps_sats,
        }) catch {};
    } else {
        _ = std.fmt.bufPrint(&gps_buf, "GPS: NOFIX     ", .{}) catch {};
    }
    oledDrawStr(0, 52, &gps_buf);
    oledUpdate();
}

/// Page 1: Surveillance — ALPR, drone, raven, camera only (not consumer trackers)
fn drawThreats() void {
    oledClear();
    drawPageNum(1);
    oledDrawStr(0, 0, "SURVEILLANCE");

    var row: u8 = 0;
    const start = if (main.tracker_count > 6) main.tracker_count - 6 else 0;
    for (start..main.tracker_count) |i| {
        if (row >= 6) break;
        // Filter to surveillance types only — skip consumer trackers
        switch (main.trackers[i].kind) {
            .flock_camera, .drone, .raven, .camera => {},
            else => continue,
        }
        const y: u8 = 10 + row * 8;
        var buf: [32]u8 = undefined;
        const ks = kindStr(main.trackers[i].kind);
        const s = scoreLevel(main.trackers[i].score);
        const fw = if (main.trackers[i].kind == .raven) ravenFwStr(main.trackers[i].methods) else "";
        const model = if (main.trackers[i].kind == .drone and scanner.drone_model_buf[0] != 0)
            std.mem.sliceTo(&scanner.drone_model_buf, 0) else "";
        _ = std.fmt.bufPrint(&buf, "{X:0<2}:{X:0<2} {s}{s}{s}{d} {s}", .{
            main.trackers[i].mac[0], main.trackers[i].mac[1],
            ks, fw, model, main.trackers[i].rssi, s,
        }) catch continue;
        oledDrawStr(0, y, &buf);
        row += 1;
    }
    // Stingray alert — indirect detection, show as special row
    if (scanner.stingray_alert_active and row < 6) {
        oledDrawStr(0, 10 + row * 8, "!! STINGRAY DETECT ?");
        row += 1;
    }
    oledDrawStr(0, 56, "PRG:next page");
    oledUpdate();
}

/// Map RSSI to a human-readable distance word.
fn distanceWord(rssi: i8) []const u8 {
    if (rssi >= -50) return "HERE";
    if (rssi >= -65) return "CLOSE";
    if (rssi >= -80) return "NEAR";
    if (rssi >= -90) return "FAR";
    return "----";
}

/// RSSI delta tracking for the proximity arrow.
var prox_prev_rssi: i8 = 0;
var prox_prev_ms: u32 = 0;

/// Page 2: Proximity finder — big RSSI readout, trend arrow, distance word.
fn drawProximity() void {
    oledClear();
    drawPageNum(2);

    if (main.tracker_count == 0) {
        oledDrawStr(0, 0, "PROXIMITY");
        oledDrawStr(0, 28, "No threats nearby");
        oledDrawStr(0, 57, "PRG:next page");
        oledUpdate();
        return;
    }

    // Find nearest by RSSI (highest = closest)
    var nearest_idx: usize = 0;
    var best_rssi: i8 = -128;
    for (0..main.tracker_count) |i| {
        if (main.trackers[i].rssi > best_rssi) {
            best_rssi = main.trackers[i].rssi;
            nearest_idx = i;
        }
    }

    const t = main.trackers[nearest_idx];

    // Header: device kind in the top-left corner (+ drone model if known)
    oledDrawStr(0, 0, kindStr(t.kind));
    if (t.kind == .drone and scanner.drone_model_buf[0] != 0) {
        oledDrawStr(24, 0, std.mem.sliceTo(&scanner.drone_model_buf, 0));
    }

    // Trend arrow: compare live RSSI against the sample taken ~500ms ago.
    if (prox_prev_ms == 0) {
        prox_prev_rssi = t.rssi;
        prox_prev_ms = main.tick_ms;
    }
    const diff: i32 = @as(i32, t.rssi) - @as(i32, prox_prev_rssi);
    const dir: i8 = if (diff > 2) 1 else if (diff < -2) -1 else 0;
    if ((main.tick_ms -% prox_prev_ms) >= 500) {
        prox_prev_rssi = t.rssi;
        prox_prev_ms = main.tick_ms;
    }

    // Big centered RSSI number (scale 3 ≈ 15x21px glyphs)
    var num_buf: [8]u8 = undefined;
    const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{t.rssi}) catch "?";
    const nwidth: u8 = @intCast(num_str.len * 18); // 6px glyph cell × scale 3
    const nx: u8 = if (nwidth < OLED_WIDTH) (OLED_WIDTH - nwidth) / 2 else 0;
    oledDrawStrScaled(nx, 9, num_str, 3);

    // "dBm" label centered below the number
    oledDrawStr((OLED_WIDTH - 18) / 2, 31, "dBm");

    // Arrow + distance word, centered as a group
    const word = distanceWord(t.rssi);
    const ww: u8 = @intCast(word.len * 6);
    const group: u8 = 9 + 4 + ww; // arrow(9) + gap(4) + word
    const gx: u8 = if (group < OLED_WIDTH) (OLED_WIDTH - group) / 2 else 0;
    drawArrow(gx, 40, dir);
    oledDrawStr(gx + 13, 40, word);

    // Full-width RSSI bar: -100 = 0%, -20 = 100%
    const rssi_pct: u8 = if (t.rssi < -100) 0 else if (t.rssi > -20) 100 else blk: {
        const val: u32 = @intCast(@as(i32, t.rssi) + 100);
        break :blk @intCast(val * 100 / 80);
    };
    oledDrawBar(0, 48, 128, 8, rssi_pct);

    oledDrawStr(0, 57, "PRG:next page");
    oledUpdate();
}

/// Page 3: Detection history bar chart (last 60 minutes)
fn drawHistory() void {
    oledClear();
    drawPageNum(3);
    oledDrawStr(0, 0, "HISTORY");

    // Count detections in 5 × 12-min buckets
    var buckets = [_]u32{0} ** 5;
    const now_sec = main.tick_ms / 1000;
    for (0..main.tracker_count) |i| {
        const age = now_sec -| (main.trackers[i].last_seen / 1000);
        if (age > 3600) continue;
        const b: usize = @intCast(age / 720); // 12 min = 720s
        if (b < 5) {
            const bucket: usize = 4 - b; // rightmost=recent, leftmost=oldest
            buckets[bucket] += 1;
        }
    }

    // Find max for scaling
    var max_val: u32 = 1;
    for (buckets) |b| {
        if (b > max_val) max_val = b;
    }

    const bar_x = [_]u8{ 4, 28, 52, 76, 100 };
    for (0..5) |b| {
        const h: u8 = if (max_val == 0) 1 else @intCast(buckets[b] * 42 / max_val);
        oledDrawBar(bar_x[b], 50 - h, 20, h, 100);
    }

    oledDrawStr(0, 52, "60  48  36  24  now");
    oledDrawStr(0, 56, "PRG:next page");
    oledUpdate();
}

/// Page 4: BLE-only tracker list
fn drawBleList() void {
    oledClear();
    drawPageNum(4);
    oledDrawStr(0, 0, "TRACKERS");

    var row: u8 = 0;
    var rendered: u8 = 0;
    var i: usize = main.tracker_count;
    while (i > 0 and rendered < 6) {
        i -= 1;
        if (main.trackers[i].kind == .flock_camera or main.trackers[i].kind == .wifi_device) continue;
        const y: u8 = 10 + row * 8;
        var buf: [32]u8 = undefined;
        _ = std.fmt.bufPrint(&buf, "{X:0<2}:{X:0<2} {s} {d}", .{
            main.trackers[i].mac[0], main.trackers[i].mac[1],
            kindStr(main.trackers[i].kind), main.trackers[i].rssi,
        }) catch continue;
        oledDrawStr(0, y, &buf);
        row += 1;
        rendered += 1;
    }
    oledDrawStr(0, 56, "PRG:next page");
    oledUpdate();
}

/// Page 5: Session stats
fn drawStats() void {
    oledClear();
    drawPageNum(5);
    oledDrawStr(0, 0, "STATS");

    const uptime_sec = main.tick_ms / 1000;
    oledDrawStr(0, 14, "Up:");
    var buf: [16]u8 = undefined;
    _ = std.fmt.bufPrint(&buf, "{d}h{d}m", .{ uptime_sec / 3600, (uptime_sec / 60) % 60 }) catch {};
    oledDrawStr(30, 14, &buf);

    oledDrawStr(0, 24, "Uniq:");
    oledDrawInt(48, 24, @intCast(main.tracker_count));

    oledDrawStr(0, 34, "WiFi:");
    oledDrawInt(48, 34, @intCast(main.wifi_get_frame_count()));

    oledDrawStr(0, 44, "Bat:");
    const mv = main.battery_read_mv();
    const v = @as(u32, @intCast(mv));
    _ = std.fmt.bufPrint(&buf, "{d}.{d}V", .{ v / 1000, (v / 100) % 10 }) catch {};
    oledDrawStr(48, 44, &buf);

    oledDrawStr(0, 56, "PRG:next page");
    oledUpdate();
}

/// Page 6: System info
fn drawSystem() void {
    oledClear();
    drawPageNum(6);
    oledDrawStr(0, 0, "SYSTEM");

    // Free heap (simplified — ESP-IDF provides this)
    oledDrawStr(0, 14, "Firmware: v" ++ main.FIRMWARE_VERSION);
    oledDrawStr(0, 24, "Flash: 3MB app");
    // Carrier probes (IMSI catcher indicator)
    var probe_buf: [24]u8 = undefined;
    _ = std.fmt.bufPrint(&probe_buf, "Carrier:{d}", .{scanner.carrier_probes}) catch {};
    oledDrawStr(0, 34, &probe_buf);
    if (scanner.gps_fix) {
        var gps_buf: [24]u8 = undefined;
        _ = std.fmt.bufPrint(&gps_buf, "GPS:{d}sat 3Dfix", .{scanner.gps_sats}) catch {};
        oledDrawStr(0, 34, &gps_buf);
    } else {
        oledDrawStr(0, 34, "GPS: no fix    ");
    }

    const mv = main.battery_read_mv();
    const v = @as(u32, @intCast(mv));
    var buf: [16]u8 = undefined;
    _ = std.fmt.bufPrint(&buf, "V: {d}.{d}V", .{ v / 1000, (v / 100) % 10 }) catch {};
    oledDrawStr(0, 44, &buf);

    // WiFi ring buffer overflow counter
    const dropped = main.wifi_get_dropped_count();
    if (dropped > 0) {
        var drop_buf: [24]u8 = undefined;
        _ = std.fmt.bufPrint(&drop_buf, "Dropped:{d}", .{dropped}) catch {};
        oledDrawStr(0, 50, &drop_buf);
    }

    oledDrawStr(0, 56, "PRG:next page");
    oledUpdate();
}

/// Page 7: All OUI-matched devices — visibility without alerting.
fn drawAllDevices() void {
    oledClear();
    drawPageNum(7);
    oledDrawStr(0, 0, "DEVICES");

    var row: u8 = 0;
    var total: u32 = 0;
    var i: usize = main.tracker_count;
    while (i > 0) {
        i -= 1;
        if (main.trackers[i].methods & scanner.METHOD_OUI == 0) continue;
        total += 1;
        if (row >= 5) continue; // keep counting, but only 5 rows fit
        const y: u8 = 10 + row * 8;
        const name = main.vendorName(main.trackers[i].mac) orelse "Unknown";
        const nshow = if (name.len > 12) name[0..12] else name;
        var buf: [32]u8 = undefined;
        _ = std.fmt.bufPrint(&buf, "{s} {d} ?", .{ nshow, main.trackers[i].rssi }) catch continue;
        oledDrawStr(0, y, &buf);
        row += 1;
    }

    if (total == 0) oledDrawStr(0, 28, "No OUI devices");
    var fbuf: [24]u8 = undefined;
    _ = std.fmt.bufPrint(&fbuf, "{d} in OUI range", .{total}) catch {};
    oledDrawStr(0, 48, &fbuf);
    oledDrawStr(0, 56, "PRG:next page");
    oledUpdate();
}

/// Route to the current page. Called on button press, at boot, and on new detection.
pub fn drawPage() void {
    switch (display.current_page) {
        0 => drawSummary(),
        1 => drawThreats(),
        2 => drawProximity(),
        3 => drawHistory(),
        4 => drawBleList(),
        5 => drawStats(),
        6 => drawSystem(),
        7 => drawAllDevices(),
        else => drawSummary(),
    }
}
