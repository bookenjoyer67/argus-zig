//! === T-Deck color dashboard UI ===
//!
//! Phase 2 minimal layout: a single status page (counts / battery / GPS) plus
//! boot/setup/pairing/OTA screens, rendered with the shared mono gfx (white on
//! black) into the ST7789 framebuffer. Full multi-pane color layout + input
//! come in later phases.

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
const W = st7789.WIDTH;

const batteryPct = display.batteryPct;
const kindStr = display.kindStr;
const scoreLevel = display.scoreLevel;

/// Views cycled by keys 1-6 / trackball. See drawPage().
pub const NUM_PAGES: u8 = 5;

// ================================================================
// Screens
// ================================================================

/// Boot screen: big centered "ARGUS" with a status line below.
pub fn drawBoot(msg: []const u8) void {
    clear();
    // "ARGUS" scale 4 = 5 glyphs × 24px = 120px wide.
    drawStrScaled((W - 120) / 2, 80, "ARGUS", 4);
    const mw: u16 = @intCast(msg.len * 12); // scale 2
    const mx: u16 = if (mw < W) (W - mw) / 2 else 0;
    if (msg.len > 0) drawStrScaled(mx, 140, msg, 2);
    update();
}

/// First-boot onboarding screen.
pub fn drawSetup() void {
    clear();
    drawStrScaled(10, 10, "SETUP", 3);
    drawStrScaled(10, 70, "Join WiFi:", 2);
    drawStrScaled(10, 95, "  Argus Setup", 2);
    drawStrScaled(10, 135, "Open in browser:", 2);
    drawStrScaled(10, 160, "  192.168.4.1", 2);
    update();
}

/// BLE pairing screen — 6-digit passkey.
pub fn drawPasskey(passkey: u32) void {
    clear();
    drawStrScaled(10, 20, "PAIR", 3);
    drawStrScaled(10, 80, "Enter on phone:", 2);
    var buf: [8]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d:0>6}", .{passkey % 1000000}) catch return;
    // scale 4 = 6 glyphs × 24px = 144px wide; center it.
    drawStrScaled((W - 144) / 2, 130, s, 4);
    update();
}

/// Firmware-update progress screen.
pub fn drawOtaProgress(pct: i32) void {
    clear();
    drawStrScaled(10, 20, "UPDATE", 3);
    const p: u8 = if (pct < 0) 0 else @intCast(@min(pct, @as(i32, 100)));
    var buf: [8]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}%", .{p}) catch return;
    drawStrScaled(20, 90, s, 4);
    drawBar(20, 150, 280, 20, p);
    update();
}

// ================================================================
// Views (keys 1-6 / trackball cycle these)
// ================================================================
//   1 Dashboard · 2 Surveillance · 3 Trackers · 4 Devices · 5 System

/// Clear + title + "n/N" page indicator. Body starts at y=44.
fn header(title: []const u8, page: u8) void {
    clear();
    drawStrScaled(8, 6, title, 3);
    var pb: [8]u8 = undefined;
    const ps = std.fmt.bufPrint(&pb, "{d}/{d}", .{ page + 1, NUM_PAGES }) catch "";
    drawStrScaled(268, 12, ps, 2);
}

/// Format a MAC's first two bytes as "XX:XX".
fn mac2(i: usize, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "{X:0>2}:{X:0>2}", .{ main.trackers[i].mac[0], main.trackers[i].mac[1] }) catch "??:??";
}

/// View 0 — Dashboard: counts, battery, GPS.
fn drawDashboard() void {
    var surv_count: u32 = 0;
    var track_count: u32 = 0;
    for (0..main.tracker_count) |i| {
        switch (main.trackers[i].kind) {
            .flock_camera, .drone, .raven, .camera => surv_count += 1,
            else => track_count += 1,
        }
    }
    if (scanner.stingray_alert_active) surv_count += 1;

    header("ARGUS", 0);
    if (scanner.stingray_alert_active) drawStrScaled(8, 44, "!! STINGRAY ?", 2);

    drawStrScaled(8, 76, "SURV:", 2);
    drawInt(120, 76, @intCast(surv_count));
    drawStrScaled(8, 104, "TRACK:", 2);
    drawInt(120, 104, @intCast(track_count));
    drawStrScaled(8, 132, "OUI:", 2);
    drawInt(120, 132, @intCast(main.KNOWN_OUIS_COUNT));

    const mv = main.battery_read_mv();
    const v = @as(u32, @intCast(mv));
    var bbuf: [20]u8 = undefined;
    const bs = std.fmt.bufPrint(&bbuf, "Bat:{d}.{d}V", .{ v / 1000, (v / 100) % 10 }) catch "";
    drawStrScaled(8, 168, bs, 2);
    drawBar(180, 170, 130, 16, batteryPct(mv));

    var gbuf: [24]u8 = undefined;
    const gs = if (scanner.gps_fix)
        std.fmt.bufPrint(&gbuf, "GPS:{d} sats", .{scanner.gps_sats}) catch ""
    else
        "GPS: NOFIX";
    drawStrScaled(8, 200, gs, 2);
    update();
}

/// View 1 — Surveillance: ALPR/drone/raven/camera rows.
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
        var buf: [40]u8 = undefined;
        var mbuf: [8]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{s} {s} {d} {s}", .{
            kindStr(main.trackers[i].kind), mac2(i, &mbuf),
            main.trackers[i].rssi, scoreLevel(main.trackers[i].score),
        }) catch continue;
        drawStrScaled(8, y, s, 2);
        row += 1;
    }
    if (scanner.stingray_alert_active and row < 8) {
        drawStrScaled(8, 48 + @as(u16, row) * 23, "!! STINGRAY ?", 2);
    } else if (row == 0) {
        drawStrScaled(8, 110, "None detected", 2);
    }
    update();
}

/// View 2 — Trackers: AirTag/Tile/Samsung/FindMy rows.
fn drawTrackers() void {
    header("TRACKERS", 2);
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
        const s = std.fmt.bufPrint(&buf, "{s} {s} {d}", .{
            kindStr(main.trackers[i].kind), mac2(i, &mbuf), main.trackers[i].rssi,
        }) catch continue;
        drawStrScaled(8, y, s, 2);
        row += 1;
    }
    if (row == 0) drawStrScaled(8, 110, "None nearby", 2);
    update();
}

/// View 3 — Devices: every OUI-matched device (vendor + RSSI).
fn drawDevices() void {
    header("DEVICES", 3);
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
        const s = std.fmt.bufPrint(&buf, "{s} {d}", .{ nshow, main.trackers[i].rssi }) catch continue;
        drawStrScaled(8, y, s, 2);
        row += 1;
    }
    var fbuf: [28]u8 = undefined;
    const fs = std.fmt.bufPrint(&fbuf, "{d} in OUI range", .{total}) catch "";
    drawStrScaled(8, 212, fs, 2);
    update();
}

/// View 4 — System: firmware, uptime, battery, GPS, WiFi.
fn drawSystem() void {
    header("SYSTEM", 4);
    drawStrScaled(8, 48, "FW v" ++ main.FIRMWARE_VERSION, 2);

    const up = main.tick_ms / 1000;
    var ubuf: [24]u8 = undefined;
    const us = std.fmt.bufPrint(&ubuf, "Up {d}h{d}m", .{ up / 3600, (up / 60) % 60 }) catch "";
    drawStrScaled(8, 76, us, 2);

    const mv = main.battery_read_mv();
    const v = @as(u32, @intCast(mv));
    var vbuf: [24]u8 = undefined;
    const vs = std.fmt.bufPrint(&vbuf, "Bat {d}.{d}V {d}%", .{ v / 1000, (v / 100) % 10, batteryPct(mv) }) catch "";
    drawStrScaled(8, 104, vs, 2);

    var gbuf: [24]u8 = undefined;
    const gs = if (scanner.gps_fix)
        std.fmt.bufPrint(&gbuf, "GPS {d} sat fix", .{scanner.gps_sats}) catch ""
    else
        "GPS no fix";
    drawStrScaled(8, 132, gs, 2);

    var wbuf: [24]u8 = undefined;
    const ws = std.fmt.bufPrint(&wbuf, "WiFi {d} frm", .{main.wifi_get_frame_count()}) catch "";
    drawStrScaled(8, 160, ws, 2);

    var obuf: [24]u8 = undefined;
    const os = std.fmt.bufPrint(&obuf, "OUI db {d}", .{main.KNOWN_OUIS_COUNT}) catch "";
    drawStrScaled(8, 188, os, 2);
    update();
}

/// Route to the current view.
pub fn drawPage() void {
    switch (display.current_page) {
        0 => drawDashboard(),
        1 => drawSurv(),
        2 => drawTrackers(),
        3 => drawDevices(),
        4 => drawSystem(),
        else => drawDashboard(),
    }
}
