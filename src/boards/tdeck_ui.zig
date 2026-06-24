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
const analysis = @import("../analysis.zig");
const config = @import("../config.zig");
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
pub const NUM_PAGES: u8 = 10;

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
    if (main.audio_muted) {
        col(CORRUPT);
        drawStrScaled(220, 12, "[M]", 2);
    }
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
    if (main.label_mode and main.label_view_kind == 1) {
        col(MUTED);
        drawStrScaled(8, 200, "1=CONF 2=FALSE 3=UNKN 4=MUNI 5=PRIV 0=clr", 1);
    }
    const scroll: u8 = if (main.label_mode and main.label_view_kind == 1) 0 else main.page_scroll;
    var skipped: u8 = 0;
    var row: u8 = 0;
    var i: usize = main.tracker_count;
    while (i > 0 and row < 8) {
        i -= 1;
        switch (main.trackers[i].kind) {
            .flock_camera, .drone, .raven, .camera => {},
            else => continue,
        }
        if (skipped < scroll) { skipped += 1; continue; }
        const y: u16 = 48 + @as(u16, row) * 23;
        const selected = main.label_mode and main.label_view_kind == 1 and (skipped + row) == main.label_cursor;
        var buf: [50]u8 = undefined;
        var mbuf: [8]u8 = undefined;
        var abuf: [8]u8 = undefined;
        if (selected) {
            col(ACCENT);
            drawStrScaled(2, y, ">", 2);
        }
        col(kindColor(main.trackers[i].kind));
        const ovr = if (main.lookupOverride(main.trackers[i].mac) != null) " [OVR]" else "";
        const s = std.fmt.bufPrint(&buf, "{s} {s} {d} {s} {s}{s}{s}", .{
            kindStr(main.trackers[i].kind),  mac2(i, &mbuf),
            main.trackers[i].rssi,           scoreLevel(main.trackers[i].score),
            ageStr(main.trackers[i].last_seen, &abuf),
            if (main.trackers[i].tag != 0) main.tagLabel(main.trackers[i].tag) else "",
            ovr,
        }) catch continue;
        drawStrScaled(if (selected) 16 else 8, y, s, 2);
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
    var skipped: u8 = 0;
    var row: u8 = 0;
    var i: usize = main.tracker_count;
    while (i > 0 and row < 8) {
        i -= 1;
        switch (main.trackers[i].kind) {
            .airtag, .tile, .samsung, .findmy => {},
            else => continue,
        }
        if (skipped < main.page_scroll) { skipped += 1; continue; }
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
    if (main.label_mode and main.label_view_kind == 5) {
        col(MUTED);
        drawStrScaled(8, 200, "1=CONF 2=FALSE 3=UNKN 4=MUNI 5=PRIV 0=clr", 1);
    }
    const scroll: u8 = if (main.label_mode and main.label_view_kind == 5) 0 else main.page_scroll;
    var skipped: u8 = 0;
    var row: u8 = 0;
    var total: u32 = 0;
    var i: usize = main.tracker_count;
    while (i > 0) {
        i -= 1;
        if (main.trackers[i].methods & scanner.METHOD_OUI == 0) continue;
        total += 1;
        if (skipped < scroll) { skipped += 1; continue; }
        if (row >= 7) continue;
        const y: u16 = 48 + @as(u16, row) * 23;
        const selected = main.label_mode and main.label_view_kind == 5 and (skipped + row) == main.label_cursor;
        const name = main.vendorName(main.trackers[i].mac) orelse "Unknown";
        const nshow = if (name.len > 14) name[0..14] else name;
        var buf: [50]u8 = undefined;
        if (selected) {
            col(ACCENT);
            drawStrScaled(2, y, ">", 2);
        }
        col(kindColor(main.trackers[i].kind));
        const ovr = if (main.lookupOverride(main.trackers[i].mac) != null) " [OVR]" else "";
        const s = std.fmt.bufPrint(&buf, "{s} {d}{s}{s}", .{ nshow, main.trackers[i].rssi,
            if (main.trackers[i].tag != 0) main.tagLabel(main.trackers[i].tag) else "",
            ovr,
        }) catch continue;
        drawStrScaled(if (selected) 16 else 8, y, s, 2);
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

    // Free heap
    col(TEXT);
    var hbuf: [24]u8 = undefined;
    drawStrScaled(8, 132, std.fmt.bufPrint(&hbuf, "Heap {d} KB", .{main.free_heap_kb()}) catch "", 2);

    // GPS status
    var gbuf: [24]u8 = undefined;
    if (scanner.gps_fix) {
        col(ACCENT);
        drawStrScaled(8, 160, std.fmt.bufPrint(&gbuf, "GPS {d} sat fix", .{scanner.gps_sats}) catch "", 2);
    } else if (scanner.gpsAlive()) {
        col(GOLD);
        drawStrScaled(8, 160, std.fmt.bufPrint(&gbuf, "GPS searching ({d})", .{scanner.gps_sats_in_view}) catch "", 2);
    } else {
        col(MUTED);
        drawStrScaled(8, 160, "GPS no signal", 2);
    }

    col(TEXT);
    var wbuf: [24]u8 = undefined;
    drawStrScaled(8, 188, std.fmt.bufPrint(&wbuf, "WiFi {d} frm", .{main.wifi_get_frame_count()}) catch "", 2);

    // Drop counters
    var drop_buf: [32]u8 = undefined;
    drawStrScaled(8, 216, std.fmt.bufPrint(&drop_buf, "WiFi drop {d}  BLE drop {d}", .{
        main.wifi_get_dropped_count(), main.ble_scan_dropped(),
    }) catch "", 2);

    update();
}

/// View 7 — Detection playback (scrollable history log).
fn drawHistoryPlayback() void {
    header("PLAYBACK", 7);
    // Filter + sort indicator
    col(MUTED);
    var fbuf: [40]u8 = undefined;
    const fltr = switch (main.history_filter) {
        1 => "FLOCK",
        2 => "DRONE",
        3 => "RAVEN",
        4 => "CAMERA",
        5 => "TRACKER",
        else => "ALL",
    };
    const srt = if (main.history_sort == 0) "time" else "score";
    _ = std.fmt.bufPrint(&fbuf, "{s} / {s}  f/d/r/c/t/a  s=sort", .{ fltr, srt }) catch {};
    drawStr(8, 38, &fbuf);

    // Collect filtered entries into a list (up to main.HISTORY_MAX).
    // Walk from newest (history_write-1) backwards.
    var filtered: [64]u16 = undefined; // indices into history[]
    var fcount: u16 = 0;
    const count = if (main.history_count < main.HISTORY_MAX) main.history_count else main.HISTORY_MAX;
    var n: usize = 0;
    while (n < count) : (n += 1) {
        const idx = (main.history_write + main.HISTORY_MAX - 1 - n) % main.HISTORY_MAX;
        const e = main.history[idx];
        // Filter
        const match = switch (main.history_filter) {
            1 => e.kind == .flock_camera,
            2 => e.kind == .drone,
            3 => e.kind == .raven,
            4 => e.kind == .camera,
            5 => switch (e.kind) { .airtag, .tile, .samsung, .findmy => true, else => false },
            else => true,
        };
        if (!match) continue;
        if (fcount < 64) {
            filtered[fcount] = @intCast(idx);
            fcount += 1;
        }
    }

    // Sort by score if requested (stable: preserve time order within same score).
    if (main.history_sort == 1 and fcount > 1) {
        var swapped = true;
        while (swapped) {
            swapped = false;
            var j: u16 = 1;
            while (j < fcount) : (j += 1) {
                if (main.history[filtered[j]].score > main.history[filtered[j - 1]].score) {
                    const tmp = filtered[j];
                    filtered[j] = filtered[j - 1];
                    filtered[j - 1] = tmp;
                    swapped = true;
                }
            }
        }
    }

    // Clamp scroll
    if (main.history_scroll >= fcount and fcount > 0) {
        main.history_scroll = fcount - 1;
    }

    // Draw up to 8 rows starting at scroll offset.
    var row: u8 = 0;
    var r: u16 = main.history_scroll;
    while (r < fcount and row < 8) : ({
        r += 1;
        row += 1;
    }) {
        const e = main.history[filtered[r]];
        const y: u16 = 48 + @as(u16, row) * 23;
        var buf: [50]u8 = undefined;
        col(kindColor(e.kind));
        const s = std.fmt.bufPrint(&buf, "{s} {X:0>2}:{X:0>2} {d} {s}{s}", .{
            kindStr(e.kind),
            e.mac[0], e.mac[1],
            e.rssi,
            scoreLevel(e.score),
            if (e.tag != 0) main.tagLabel(e.tag) else "",
        }) catch continue;
        drawStrScaled(8, y, s, 2);
    }

    if (fcount == 0) {
        col(MUTED);
        drawStrScaled(8, 110, "No matching entries", 2);
    }

    // Scroll position indicator
    if (fcount > 8) {
        col(MUTED);
        var sbuf: [24]u8 = undefined;
        _ = std.fmt.bufPrint(&sbuf, "{d}-{d}/{d}", .{ main.history_scroll + 1, @min(main.history_scroll + 8, fcount), fcount }) catch {};
        drawStrScaled(200, 214, &sbuf, 2);
    }

    update();
}

/// View 8 — Deployment cluster detail.
fn drawDeploy() void {
    header("DEPLOY", 8);
    if (!analysis.deployment_alert_active) {
        col(MUTED);
        drawStrScaled(8, 110, "No deployment detected", 2);
        update();
        return;
    }
    col(ACCENT);
    var buf: [40]u8 = undefined;
    const sev: []const u8 = if (analysis.deployment_score >= analysis.DEPLOY_ALERT) "HIGH" else "WARN";
    _ = std.fmt.bufPrint(&buf, "{d} {s}  {d}dev {d}surv", .{
        analysis.deployment_score, sev,
        analysis.deployment_device_count,
        analysis.deployment_surv_count,
    }) catch {};
    drawStrScaled(8, 48, &buf, 2);

    var row: u8 = 0;
    for (0..main.tracker_count) |i| {
        if (row >= 6) break;
        const t = main.trackers[i];
        if (t.sightings < 2) continue;
        const y: u16 = 80 + @as(u16, row) * 23;
        var lbuf: [40]u8 = undefined;
        col(kindColor(t.kind));
        const nm = display.kindStr(t.kind);
        _ = std.fmt.bufPrint(&lbuf, "{s} {X:0<2}:{X:0<2} {d} {s}", .{
            nm, t.mac[0], t.mac[1], t.rssi, scoreLevel(t.score),
        }) catch continue;
        drawStrScaled(16, y, &lbuf, 2);
        row += 1;
    }
    update();
}

/// View 9 — Settings (read-only config viewer).
fn drawSettings() void {
    header("SETTINGS", 9);

    // Name
    var name_buf: [32]u8 = undefined;
    const name: [*:0]const u8 = "name";
    const name_val = config.get(name, &name_buf);
    col(if (main.settings_cursor == 0) ACCENT else MUTED);
    drawStrScaled(8, 48, "Name:", 2);
    col(if (main.settings_cursor == 0) TEXT else MUTED);
    drawStrScaled(80, 48, if (name_val.len > 0) name_val else "-", 2);

    // Role
    var role_buf: [8]u8 = undefined;
    const role: [*:0]const u8 = "role";
    const role_val = config.get(role, &role_buf);
    col(if (main.settings_cursor == 1) ACCENT else MUTED);
    drawStrScaled(8, 76, "Role:", 2);
    col(if (main.settings_cursor == 1) TEXT else MUTED);
    drawStrScaled(80, 76, if (role_val.len > 0) role_val else "mobile", 2);

    // WiFi SSID
    var ssid_buf: [32]u8 = undefined;
    const ssid: [*:0]const u8 = "ssid";
    const ssid_val = config.get(ssid, &ssid_buf);
    col(if (main.settings_cursor == 2) ACCENT else MUTED);
    drawStrScaled(8, 104, "WiFi:", 2);
    col(if (main.settings_cursor == 2) TEXT else MUTED);
    drawStrScaled(80, 104, if (ssid_val.len > 0) ssid_val else "-", 2);

    // Location
    var lat_buf: [16]u8 = undefined;
    var lon_buf: [16]u8 = undefined;
    const latk: [*:0]const u8 = "lat";
    const lonk: [*:0]const u8 = "lon";
    const lat_val = config.get(latk, &lat_buf);
    const lon_val = config.get(lonk, &lon_buf);
    col(if (main.settings_cursor == 3) ACCENT else MUTED);
    drawStrScaled(8, 132, "Lat:", 2);
    col(if (main.settings_cursor == 3) TEXT else MUTED);
    drawStrScaled(80, 132, if (lat_val.len > 0) lat_val else "-", 2);
    col(if (main.settings_cursor == 4) ACCENT else MUTED);
    drawStrScaled(8, 160, "Lon:", 2);
    col(if (main.settings_cursor == 4) TEXT else MUTED);
    drawStrScaled(80, 160, if (lon_val.len > 0) lon_val else "-", 2);

    // Firmware
    col(MUTED);
    drawStrScaled(8, 200, "FW: " ++ main.FIRMWARE_VERSION, 2);

    // Navigation hint
    col(MUTED);
    drawStrScaled(8, 222, "TB=nav  s=exit  web: setup", 1);

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
        7 => drawHistoryPlayback(),
        8 => drawDeploy(),
        9 => drawSettings(),
        else => drawDashboard(),
    }
}
