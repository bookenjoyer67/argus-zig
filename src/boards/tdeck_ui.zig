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
// Dashboard (single page in Phase 2)
// ================================================================

pub fn drawPage() void {
    var surv_count: u32 = 0;
    var track_count: u32 = 0;
    for (0..main.tracker_count) |i| {
        switch (main.trackers[i].kind) {
            .flock_camera, .drone, .raven, .camera => surv_count += 1,
            else => track_count += 1,
        }
    }
    if (scanner.stingray_alert_active) surv_count += 1;

    clear();
    drawStrScaled(8, 6, "ARGUS", 3);
    if (scanner.stingray_alert_active) drawStrScaled(8, 44, "!! STINGRAY ?", 2);

    drawStrScaled(8, 76, "SURV:", 2);
    drawInt(120, 76, @intCast(surv_count));
    drawStrScaled(8, 104, "TRACK:", 2);
    drawInt(120, 104, @intCast(track_count));
    drawStrScaled(8, 132, "OUI:", 2);
    drawInt(120, 132, @intCast(main.KNOWN_OUIS_COUNT));

    // Battery
    const mv = main.battery_read_mv();
    const v = @as(u32, @intCast(mv));
    var bbuf: [20]u8 = undefined;
    const bs = std.fmt.bufPrint(&bbuf, "Bat:{d}.{d}V", .{ v / 1000, (v / 100) % 10 }) catch "";
    drawStrScaled(8, 168, bs, 2);
    drawBar(180, 170, 130, 16, batteryPct(mv));

    // GPS
    var gbuf: [24]u8 = undefined;
    const gs = if (scanner.gps_fix)
        std.fmt.bufPrint(&gbuf, "GPS:{d} sats", .{scanner.gps_sats}) catch ""
    else
        "GPS: NOFIX";
    drawStrScaled(8, 200, gs, 2);

    update();
}
