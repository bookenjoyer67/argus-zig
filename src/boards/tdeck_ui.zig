//! === T-Deck color dashboard UI ===
//!
//! 7 views (keys 1-7 / trackball): Dashboard, Surveillance, Proximity, History,
//! Trackers, Devices, System. Rendered with the shared gfx into the ST7789
//! framebuffer; color is set per element via st7789.setColor(), using an RGB565
//! palette that mirrors the Argus web dashboard ("Argus the Unmaker" theme).

const std = @import("std");
const main = @import("../main.zig");
const scanner = @import("../scanner.zig");
const display = @import("../display.zig");
const st7789 = @import("../hal/st7789.zig");
const g = @import("../hal/gfx.zig").Gfx(st7789);

const clear = g.clear;
const update = g.update;
const drawStr = g.drawStr;
const drawInt = g.drawInt;
const drawStrScaled = g.drawStrScaled;
const drawBar = g.drawBar;
const drawArrow = g.drawArrow;
const W = st7789.WIDTH;

const batteryPct = display.batteryPct;
const kindStr = display.kindStr;
const scoreLevel = display.scoreLevel;

/// Views cycled by keys 1-7 / trackball. See drawPage().
pub const NUM_PAGES: u8 = 7;

// ---- Palette (RGB565, converted from web/dashboard.html) ----
const ACCENT: u16 = 0x1FF3; // #1eff9d emerald — titles, "clear", GPS fix, battery ok
const GOLD: u16 = 0xEE09; // #e8c24a — camera, "aware", battery mid
const SOUL: u16 = 0x3BDF; // #3a7bff — drone
const VOID_: u16 = 0x9AFF; // #9d5cff — raven
const CORRUPT: u16 = 0xF965; // #ff2e2e — flock/stingray/CERT, battery low
const TRACKER: u16 = 0x3718; // #37e0c0 — consumer trackers
const ORANGE: u16 = 0xFCC7; // #ff9a3c — "watched"/HIGH
const TEXT: u16 = 0xDF5C; // #dfeae4 — body text
const MUTED: u16 = 0x8D15; // #8fa3ad — labels, no-fix, page indicator

fn col(c: u16) void {
    st7789.setColor(c);
}

/// Color for a tracker kind (mirrors the web .k-* classes).
fn kindColor(kind: display.TrackerType) u16 {
    return switch (kind) {
        .flock_camera => CORRUPT,
        .camera => GOLD,
        .drone => SOUL,
        .raven => VOID_,
        .airtag, .tile, .samsung, .findmy => TRACKER,
        else => TEXT,
    };
}

/// Color for a confidence score (matches the threat pills).
fn levelColor(score: u8) u16 {
    if (score >= scanner.SCORE_CERT) return CORRUPT;
    if (score >= scanner.SCORE_HIGH) return ORANGE;
    if (score >= scanner.SCORE_MED) return GOLD;
    return TEXT;
}

fn batteryColor(pct: u8) u16 {
    if (pct >= 50) return ACCENT;
    if (pct >= 20) return GOLD;
    return CORRUPT;
}

// ================================================================
// Screens (boot / setup / pairing / OTA)
// ================================================================

pub fn drawBoot(msg: []const u8) void {
    clear();
    col(ACCENT);
    drawStrScaled((W - 120) / 2, 80, "ARGUS", 4);
    col(TEXT);
    const mw: u16 = @intCast(msg.len * 12);
    const mx: u16 = if (mw < W) (W - mw) / 2 else 0;
    if (msg.len > 0) drawStrScaled(mx, 140, msg, 2);
    update();
}

pub fn drawSetup() void {
    clear();
    col(ACCENT);
    drawStrScaled(10, 10, "SETUP", 3);
    col(TEXT);
    drawStrScaled(10, 70, "Join WiFi:", 2);
    col(GOLD);
    drawStrScaled(10, 95, "  Argus Setup", 2);
    col(TEXT);
    drawStrScaled(10, 135, "Open in browser:", 2);
    col(GOLD);
    drawStrScaled(10, 160, "  192.168.4.1", 2);
    update();
}

pub fn drawPasskey(passkey: u32) void {
    clear();
    col(ACCENT);
    drawStrScaled(10, 20, "PAIR", 3);
    col(TEXT);
    drawStrScaled(10, 80, "Enter on phone:", 2);
    var buf: [8]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d:0>6}", .{passkey % 1000000}) catch return;
    col(GOLD);
    drawStrScaled((W - 144) / 2, 130, s, 4);
    update();
}

pub fn drawOtaProgress(pct: i32) void {
    clear();
    col(ACCENT);
    drawStrScaled(10, 20, "UPDATE", 3);
    const p: u8 = if (pct < 0) 0 else @intCast(@min(pct, @as(i32, 100)));
    var buf: [8]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}%", .{p}) catch return;
    col(TEXT);
    drawStrScaled(20, 90, s, 4);
    col(ACCENT);
    drawBar(20, 150, 280, 20, p);
    update();
}

// ================================================================
// Views
// ================================================================

/// Clear + title (accent) + "n/N" indicator (muted). Body starts at y≈48.
fn header(title: []const u8, page: u8) void {
    clear();
    col(ACCENT);
    drawStrScaled(8, 6, title, 3);
    col(MUTED);
    var pb: [8]u8 = undefined;
    const ps = std.fmt.bufPrint(&pb, "{d}/{d}", .{ page + 1, NUM_PAGES }) catch "";
    drawStrScaled(280, 12, ps, 2);
}

fn mac2(i: usize, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "{X:0>2}:{X:0>2}", .{ main.trackers[i].mac[0], main.trackers[i].mac[1] }) catch "??:??";
}

fn ageStr(last: u32, buf: []u8) []const u8 {
    const sec = if (main.tick_ms >= last) (main.tick_ms - last) / 1000 else 0;
    if (sec < 60) return std.fmt.bufPrint(buf, "{d}s", .{sec}) catch "";
    return std.fmt.bufPrint(buf, "{d}m", .{sec / 60}) catch "";
}

fn distanceWord(rssi: i8) []const u8 {
    if (rssi >= -50) return "HERE";
    if (rssi >= -65) return "CLOSE";
    if (rssi >= -80) return "NEAR";
    if (rssi >= -90) return "FAR";
    return "----";
}

/// View 0 — Dashboard: counts, battery, GPS, latest detections.
fn drawDashboard() void {
    var surv: u32 = 0;
    var track: u32 = 0;
    for (0..main.tracker_count) |i| {
        switch (main.trackers[i].kind) {
            .flock_camera, .drone, .raven, .camera => surv += 1,
            else => track += 1,
        }
    }
    if (scanner.stingray_alert_active) surv += 1;

    header("ARGUS", 0);
    if (scanner.stingray_alert_active) {
        col(CORRUPT);
        drawStrScaled(8, 44, "!! STINGRAY ?", 2);
    }

    col(MUTED);
    drawStrScaled(8, 74, "SURV", 2);
    drawStrScaled(168, 74, "TRACK", 2);
    col(if (surv > 0) CORRUPT else TEXT);
    drawStrScaled(80, 70, fmtU(surv), 3);
    col(TEXT);
    drawStrScaled(280, 70, fmtU(track), 3);

    // Battery
    const mv = main.battery_read_mv();
    const pct = batteryPct(mv);
    const v = @as(u32, @intCast(mv));
    var bbuf: [20]u8 = undefined;
    col(MUTED);
    drawStrScaled(8, 120, "Bat", 2);
    col(batteryColor(pct));
    drawStrScaled(56, 120, std.fmt.bufPrint(&bbuf, "{d}.{d}V", .{ v / 1000, (v / 100) % 10 }) catch "", 2);
    drawBar(180, 122, 130, 16, pct);

    // GPS — fix / searching / no signal
    col(MUTED);
    drawStrScaled(8, 150, "GPS", 2);
    var gbuf: [24]u8 = undefined;
    if (scanner.gps_fix) {
        col(ACCENT);
        drawStrScaled(56, 150, std.fmt.bufPrint(&gbuf, "{d} sat fix", .{scanner.gps_sats}) catch "", 2);
    } else if (scanner.gpsAlive()) {
        col(GOLD);
        drawStrScaled(56, 150, std.fmt.bufPrint(&gbuf, "searching ({d})", .{scanner.gps_sats_in_view}) catch "", 2);
    } else {
        col(MUTED);
        drawStrScaled(56, 150, "no signal", 2);
    }

    // Latest detections (up to 3)
    col(MUTED);
    drawStr(8, 184, "LATEST");
    var row: u8 = 0;
    var i: usize = main.tracker_count;
    while (i > 0 and row < 3) {
        i -= 1;
        const y: u16 = 196 + @as(u16, row) * 14;
        var buf: [40]u8 = undefined;
        var mbuf: [8]u8 = undefined;
        col(kindColor(main.trackers[i].kind));
        const s = std.fmt.bufPrint(&buf, "{s} {s} {d}", .{
            kindStr(main.trackers[i].kind), mac2(i, &mbuf), main.trackers[i].rssi,
        }) catch continue;
        drawStr(8, y, s);
        row += 1;
    }
    update();
}

var fmt_buf: [12]u8 = undefined;
fn fmtU(n: u32) []const u8 {
    return std.fmt.bufPrint(&fmt_buf, "{d}", .{n}) catch "";
}

/// View 1 — Surveillance list.
fn drawSurv() void {
    header("SURVEIL", 1);
    var row: u8 = 0;
    var i: usize = main.tracker_count;
    while (i > 0 and row < 8) {
        i -= 1;
        switch (main.trackers[i].kind) {
            .flock_camera, .drone, .raven, .camera => {},
            else => continue,
        }
        const y: u16 = 48 + @as(u16, row) * 23;
        var buf: [44]u8 = undefined;
        var mbuf: [8]u8 = undefined;
        var abuf: [8]u8 = undefined;
        col(kindColor(main.trackers[i].kind));
        const s = std.fmt.bufPrint(&buf, "{s} {s} {d} {s} {s}", .{
            kindStr(main.trackers[i].kind),  mac2(i, &mbuf),
            main.trackers[i].rssi,           scoreLevel(main.trackers[i].score),
            ageStr(main.trackers[i].last_seen, &abuf),
        }) catch continue;
        drawStrScaled(8, y, s, 2);
        row += 1;
    }
    if (scanner.stingray_alert_active and row < 8) {
        col(CORRUPT);
        drawStrScaled(8, 48 + @as(u16, row) * 23, "!! STINGRAY ?", 2);
    } else if (row == 0) {
        col(MUTED);
        drawStrScaled(8, 110, "None detected", 2);
    }
    update();
}

/// View 2 — Proximity finder (nearest threat).
var prox_prev_rssi: i8 = 0;
var prox_prev_ms: u32 = 0;
fn drawProximity() void {
    header("PROXIMITY", 2);
    if (main.tracker_count == 0) {
        col(MUTED);
        drawStrScaled(8, 110, "No threats nearby", 2);
        update();
        return;
    }
    var idx: usize = 0;
    var best: i8 = -128;
    for (0..main.tracker_count) |i| {
        if (main.trackers[i].rssi > best) {
            best = main.trackers[i].rssi;
            idx = i;
        }
    }
    const t = main.trackers[idx];

    col(kindColor(t.kind));
    drawStrScaled(8, 50, kindStr(t.kind), 2);
    if (t.kind == .drone and scanner.drone_model_buf[0] != 0) {
        drawStrScaled(60, 50, std.mem.sliceTo(&scanner.drone_model_buf, 0), 2);
    }

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

    // Big RSSI number, colored by score.
    var nbuf: [8]u8 = undefined;
    const ns = std.fmt.bufPrint(&nbuf, "{d}", .{t.rssi}) catch "?";
    const nw: u16 = @intCast(ns.len * 30); // scale 5 cell = 30px
    col(levelColor(t.score));
    drawStrScaled(if (nw < W) (W - nw) / 2 else 0, 90, ns, 5);
    col(MUTED);
    drawStrScaled((W - 36) / 2, 150, "dBm", 2);

    // Arrow + distance word.
    col(TEXT);
    const word = distanceWord(t.rssi);
    drawArrow(120, 182, dir);
    drawStrScaled(140, 178, word, 2);

    // RSSI bar (-100..-20).
    const pct: u8 = if (t.rssi < -100) 0 else if (t.rssi > -20) 100 else blk: {
        const val: u32 = @intCast(@as(i32, t.rssi) + 100);
        break :blk @intCast(val * 100 / 80);
    };
    col(levelColor(t.score));
    drawBar(20, 212, 280, 16, pct);
    update();
}

/// View 3 — Detection history (last 60 min, 12-min buckets).
fn drawHistory() void {
    header("HISTORY", 3);
    var buckets = [_]u32{0} ** 5;
    const now_sec = main.tick_ms / 1000;
    for (0..main.tracker_count) |i| {
        const age = now_sec -| (main.trackers[i].last_seen / 1000);
        if (age > 3600) continue;
        const b: usize = @intCast(age / 720);
        if (b < 5) buckets[4 - b] += 1;
    }
    var max_val: u32 = 1;
    for (buckets) |b| {
        if (b > max_val) max_val = b;
    }
    const bar_x = [_]u16{ 20, 80, 140, 200, 260 };
    col(ACCENT);
    for (0..5) |b| {
        const h: u16 = @intCast(buckets[b] * 150 / max_val);
        if (h > 0) drawBar(bar_x[b], 200 - h, 44, h, 100);
        col(TEXT);
        drawInt(bar_x[b] + 16, 206, @intCast(buckets[b]));
        col(ACCENT);
    }
    col(MUTED);
    drawStr(20, 224, "60   48   36   24   now (min)");
    update();
}

/// View 4 — Consumer trackers list.
fn drawTrackers() void {
    header("TRACKERS", 4);
    var row: u8 = 0;
    var i: usize = main.tracker_count;
    while (i > 0 and row < 8) {
        i -= 1;
        switch (main.trackers[i].kind) {
            .airtag, .tile, .samsung, .findmy => {},
            else => continue,
        }
        const y: u16 = 48 + @as(u16, row) * 23;
        var buf: [40]u8 = undefined;
        var mbuf: [8]u8 = undefined;
        var abuf: [8]u8 = undefined;
        col(TRACKER);
        const s = std.fmt.bufPrint(&buf, "{s} {s} {d} {s}", .{
            kindStr(main.trackers[i].kind), mac2(i, &mbuf),
            main.trackers[i].rssi,          ageStr(main.trackers[i].last_seen, &abuf),
        }) catch continue;
        drawStrScaled(8, y, s, 2);
        row += 1;
    }
    if (row == 0) {
        col(MUTED);
        drawStrScaled(8, 110, "None nearby", 2);
    }
    update();
}

/// View 5 — All OUI-matched devices.
fn drawDevices() void {
    header("DEVICES", 5);
    var row: u8 = 0;
    var total: u32 = 0;
    var i: usize = main.tracker_count;
    while (i > 0) {
        i -= 1;
        if (main.trackers[i].methods & scanner.METHOD_OUI == 0) continue;
        total += 1;
        if (row >= 7) continue;
        const y: u16 = 48 + @as(u16, row) * 23;
        const name = main.vendorName(main.trackers[i].mac) orelse "Unknown";
        const nshow = if (name.len > 14) name[0..14] else name;
        var buf: [40]u8 = undefined;
        col(kindColor(main.trackers[i].kind));
        const s = std.fmt.bufPrint(&buf, "{s} {d}", .{ nshow, main.trackers[i].rssi }) catch continue;
        drawStrScaled(8, y, s, 2);
        row += 1;
    }
    col(MUTED);
    var fbuf: [28]u8 = undefined;
    drawStrScaled(8, 212, std.fmt.bufPrint(&fbuf, "{d} in OUI range", .{total}) catch "", 2);
    update();
}

/// View 6 — System info.
fn drawSystem() void {
    header("SYSTEM", 6);
    const mv = main.battery_read_mv();
    const v = @as(u32, @intCast(mv));
    const up = main.tick_ms / 1000;

    col(TEXT);
    drawStrScaled(8, 48, "FW v" ++ main.FIRMWARE_VERSION, 2);

    var ubuf: [24]u8 = undefined;
    drawStrScaled(8, 76, std.fmt.bufPrint(&ubuf, "Up {d}h{d}m", .{ up / 3600, (up / 60) % 60 }) catch "", 2);

    col(batteryColor(batteryPct(mv)));
    var vbuf: [24]u8 = undefined;
    drawStrScaled(8, 104, std.fmt.bufPrint(&vbuf, "Bat {d}.{d}V {d}%", .{ v / 1000, (v / 100) % 10, batteryPct(mv) }) catch "", 2);

    var gbuf: [24]u8 = undefined;
    if (scanner.gps_fix) {
        col(ACCENT);
        drawStrScaled(8, 132, std.fmt.bufPrint(&gbuf, "GPS {d} sat fix", .{scanner.gps_sats}) catch "", 2);
    } else if (scanner.gpsAlive()) {
        col(GOLD);
        drawStrScaled(8, 132, std.fmt.bufPrint(&gbuf, "GPS searching ({d})", .{scanner.gps_sats_in_view}) catch "", 2);
    } else {
        col(MUTED);
        drawStrScaled(8, 132, "GPS no signal", 2);
    }

    col(TEXT);
    var wbuf: [24]u8 = undefined;
    drawStrScaled(8, 160, std.fmt.bufPrint(&wbuf, "WiFi {d} frm", .{main.wifi_get_frame_count()}) catch "", 2);

    var obuf: [24]u8 = undefined;
    drawStrScaled(8, 188, std.fmt.bufPrint(&obuf, "OUI db {d}", .{main.KNOWN_OUIS_COUNT}) catch "", 2);
    update();
}

/// Route to the current view.
pub fn drawPage() void {
    switch (display.current_page) {
        0 => drawDashboard(),
        1 => drawSurv(),
        2 => drawProximity(),
        3 => drawHistory(),
        4 => drawTrackers(),
        5 => drawDevices(),
        6 => drawSystem(),
        else => drawDashboard(),
    }
}
