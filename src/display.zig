//! === Display facade ===
//!
//! Re-exports the active board's display driver + page UI, and keeps the
//! shared, board-agnostic display helpers (tracker labels, battery percent,
//! page-cycle state) that the detection engine and dashboard API reference.
//!
//! Board-specific page rendering lives in src/boards/<board>_ui.zig; the
//! low-level panel driver lives in src/hal/. The rest of the firmware keeps
//! calling `display.*` exactly as before — only the implementation moved.

const std = @import("std");
const scanner = @import("scanner.zig");
const board = @import("board.zig");

/// Known tracker types. Stored as u8 in the table.
pub const TrackerType = enum(u8) {
    airtag,
    tile,
    samsung,
    findmy,
    flock_camera,
    wifi_device,
    drone, // Drone Remote ID (ASTM F3411)
    raven, // Raven/ShotSpotter gunshot sensor (BLE UUID set)
    camera, // Consumer/commercial surveillance camera (WiFi OUI + SSID)
    unknown,
    _,
};

/// Confidence level label for display.
pub fn scoreLevel(score: u8) []const u8 {
    if (score >= scanner.SCORE_CERT) return "CERT";
    if (score >= scanner.SCORE_HIGH) return "HIGH";
    if (score >= scanner.SCORE_MED) return "MED ";
    return "LOW ";
}

/// Tracker type to short string.
pub fn kindStr(kind: TrackerType) []const u8 {
    return switch (kind) {
        .airtag => "AIR",
        .tile => "TLE",
        .samsung => "SAM",
        .findmy => "FMY",
        .flock_camera => "FLK",
        .wifi_device => "WIF",
        .drone => "DRN",
        .raven => "RAV",
        .camera => "CAM",
        .unknown => "???",
        else => "???",
    };
}

/// Map battery millivolts to a percentage using a piecewise-linear LiPo
/// discharge curve (the voltage→charge relationship is very nonlinear — a
/// flat linear 3.3–4.2 V map reads wrong in the middle of the range).
pub fn batteryPct(mv: i32) u8 {
    // (mV, %) breakpoints, high → low.
    const pts = [_][2]i32{
        .{ 4200, 100 }, .{ 4100, 90 }, .{ 4000, 80 }, .{ 3900, 70 },
        .{ 3800, 60 },  .{ 3700, 45 }, .{ 3600, 25 }, .{ 3500, 12 },
        .{ 3400, 5 },   .{ 3300, 0 },
    };
    if (mv >= pts[0][0]) return 100;
    if (mv <= pts[pts.len - 1][0]) return 0;
    var i: usize = 0;
    while (i < pts.len - 1) : (i += 1) {
        const hi = pts[i]; // higher voltage / higher %
        const lo = pts[i + 1]; // lower voltage / lower %
        if (mv <= hi[0] and mv >= lo[0]) {
            const p = lo[1] + @divTrunc((mv - lo[0]) * (hi[1] - lo[1]), hi[0] - lo[0]);
            return @intCast(p);
        }
    }
    return 0;
}

// ---- Page-cycle state (shared between main loop and the board UI) ----
pub var current_page: u8 = 0;
pub const NUM_PAGES = board.ui.NUM_PAGES;

// ---- Panel driver (re-exported from the active board) ----
pub const oledInit = board.display_driver.init;
pub const oledUpdate = board.display_driver.update;
pub const oledDisplayOff = board.display_driver.displayOff;
pub const oledDisplayOn = board.display_driver.displayOn;

// ---- Page UI (re-exported from the active board) ----
pub const drawPage = board.ui.drawPage;
pub const drawBoot = board.ui.drawBoot;
pub const drawSetup = board.ui.drawSetup;
pub const drawPasskey = board.ui.drawPasskey;
pub const drawOtaProgress = board.ui.drawOtaProgress;
