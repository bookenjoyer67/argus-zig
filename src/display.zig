const std = @import("std");
const main = @import("main.zig");
const scanner = @import("scanner.zig");

// LED pin + helpers for the alert system.
// gpio_write is resolved through main.zig (extern fn → ESP-IDF).
const PIN_LED: u32 = 35; // Onboard white LED (J2 pin 10), active HIGH

fn ledOn() void {
    _ = main.gpio_write(PIN_LED, 1);
}

fn ledOff() void {
    _ = main.gpio_write(PIN_LED, 0);
}

/// Known tracker types. Stored as u8 in the table.
pub const TrackerType = enum(u8) {
    airtag,
    tile,
    samsung,
    findmy,
    flock_camera,
    wifi_device,
    drone,          // Drone Remote ID (ASTM F3411)
    raven,          // Raven/ShotSpotter gunshot sensor (BLE UUID set)
    camera,         // Consumer/commercial surveillance camera (WiFi OUI + SSID)
    unknown,
    _,
};

/// Confidence level label for display.
fn scoreLevel(score: u8) []const u8 {
    if (score >= scanner.SCORE_CERT) return "CERT";
    if (score >= scanner.SCORE_HIGH) return "HIGH";
    if (score >= scanner.SCORE_MED) return "MED ";
    return "LOW ";
}

// ================================================================
// SSD1306 OLED DISPLAY DRIVER (128x64, I2C, monochrome)
// ================================================================
//
// Pure Zig implementation — no U8g2, no C library.
// Saves ~500KB of flash compared to U8g2.
//
// Architecture:
//   oled_buf[page][column] — 8 pages of 128 bytes = 1024 bytes
//   Each byte represents 8 vertical pixels (bit 0 = top pixel of page)
//   SSD1306 page addressing mode: send page address, then 128 data bytes
//
// Font: 5x7 pixel monospace, ASCII 0x20-0x5A (space through Z).
// Each glyph is 5 bytes, each byte is a column (top-to-bottom).
// Characters are 6px wide (5px glyph + 1px spacing).

pub const OLED_ADDR: u8   = 0x3C;    // SSD1306 I2C address (SA0=GND)
pub const OLED_WIDTH: u8  = 128;
pub const OLED_HEIGHT: u8 = 64;

// Compute buffer size at compile time. The cast to usize prevents u8 overflow
// (128 * 64 = 8192 which exceeds u8::MAX, but 8192/8 = 1024 fits in u16).
pub const OLED_BUF_SIZE: usize = (@as(usize, OLED_WIDTH) * OLED_HEIGHT) / 8;
pub var oled_buf: [OLED_BUF_SIZE]u8 = [_]u8{0} ** OLED_BUF_SIZE;

/// 5x7 bitmap font: ASCII 32 (space) through 90 (Z).
/// Each entry is 5 bytes, each byte is one column from top to bottom.
/// Bit 0 = top pixel, bit 6 = bottom pixel (bit 7 unused for 7-row font).
/// Extracted from classic 5x7 font commonly used in embedded displays.
pub const FONT_5X7 = [_]u8{
    0x00,0x00,0x00,0x00,0x00, // 32: space
    0x00,0x5F,0x00,0x00,0x00, // 33: !
    0x00,0x00,0x00,0x00,0x00, // 34: " (placeholder)
    0x14,0x7F,0x14,0x7F,0x14, // 35: #
    0x24,0x2A,0x7F,0x2A,0x12, // 36: $
    0x23,0x13,0x08,0x64,0x62, // 37: %
    0x36,0x49,0x55,0x22,0x50, // 38: &
    0x00,0x05,0x03,0x00,0x00, // 39: '
    0x1C,0x22,0x41,0x00,0x00, // 40: (
    0x41,0x22,0x1C,0x00,0x00, // 41: )
    0x08,0x2A,0x1C,0x2A,0x08, // 42: *
    0x08,0x08,0x3E,0x08,0x08, // 43: +
    0x50,0x30,0x00,0x00,0x00, // 44: ,
    0x08,0x08,0x08,0x08,0x08, // 45: -
    0x60,0x60,0x00,0x00,0x00, // 46: .
    0x20,0x10,0x08,0x04,0x02, // 47: /
    0x3E,0x51,0x49,0x45,0x3E, // 48: 0
    0x00,0x42,0x7F,0x40,0x00, // 49: 1
    0x42,0x61,0x51,0x49,0x46, // 50: 2
    0x21,0x41,0x45,0x4B,0x31, // 51: 3
    0x18,0x14,0x12,0x7F,0x10, // 52: 4
    0x27,0x45,0x45,0x45,0x39, // 53: 5
    0x3C,0x4A,0x49,0x49,0x30, // 54: 6
    0x01,0x71,0x09,0x05,0x03, // 55: 7
    0x36,0x49,0x49,0x49,0x36, // 56: 8
    0x06,0x49,0x49,0x29,0x1E, // 57: 9
    0x00,0x6C,0x6C,0x00,0x00, // 58: :
    0x00,0x56,0x36,0x00,0x00, // 59: ;
    0x00,0x08,0x14,0x22,0x41, // 60: <
    0x14,0x14,0x14,0x14,0x14, // 61: =
    0x41,0x22,0x14,0x08,0x00, // 62: >
    0x02,0x01,0x51,0x09,0x06, // 63: ?
    0x32,0x49,0x79,0x41,0x3E, // 64: @
    0x7E,0x09,0x09,0x09,0x7E, // 65: A
    0x7F,0x49,0x49,0x49,0x36, // 66: B
    0x3E,0x41,0x41,0x41,0x22, // 67: C
    0x7F,0x41,0x41,0x22,0x1C, // 68: D
    0x7F,0x49,0x49,0x49,0x41, // 69: E
    0x7F,0x09,0x09,0x01,0x01, // 70: F
    0x3E,0x41,0x49,0x49,0x7A, // 71: G
    0x7F,0x08,0x08,0x08,0x7F, // 72: H
    0x41,0x7F,0x41,0x00,0x00, // 73: I
    0x30,0x40,0x40,0x3F,0x00, // 74: J
    0x7F,0x08,0x14,0x22,0x41, // 75: K
    0x7F,0x40,0x40,0x40,0x40, // 76: L
    0x7F,0x02,0x04,0x02,0x7F, // 77: M
    0x7F,0x04,0x08,0x10,0x7F, // 78: N
    0x3E,0x41,0x41,0x41,0x3E, // 79: O
    0x7F,0x09,0x09,0x09,0x06, // 80: P
    0x3E,0x41,0x51,0x21,0x5E, // 81: Q
    0x7F,0x09,0x19,0x29,0x46, // 82: R
    0x26,0x49,0x49,0x49,0x32, // 83: S
    0x01,0x01,0x7F,0x01,0x01, // 84: T
    0x3F,0x40,0x40,0x40,0x3F, // 85: U
    0x1F,0x20,0x40,0x20,0x1F, // 86: V
    0x7F,0x20,0x18,0x20,0x7F, // 87: W
    0x63,0x14,0x08,0x14,0x63, // 88: X
    0x03,0x04,0x78,0x04,0x03, // 89: Y
    0x61,0x51,0x49,0x45,0x43, // 90: Z
};

/// Look up the 5-column bitmap for an ASCII character.
/// Lowercase is folded to uppercase.
/// Characters outside ASCII 32-90 render as space.
fn fontChar(c: u8) [5]u8 {
    if (c >= 'a' and c <= 'z') return fontChar(c - 32);
    const idx: usize = if (c >= ' ' and c <= 'Z') @intCast(c - ' ') else 0;
    const base = idx * 5;
    return FONT_5X7[base..][0..5].*;
}

/// Set a single pixel in the display buffer.
/// Coordinates are clipped to display bounds.
/// The buffer uses SSD1306 page format:
///   page = y / 8, bit = y % 8
fn oledSetPixel(x: u8, y: u8, on: bool) void {
    if (x >= OLED_WIDTH or y >= OLED_HEIGHT) return;
    const page = y / 8;
    const bit: u8 = @intCast(y % 8);
    const idx: usize = @as(usize, page) * OLED_WIDTH + @as(usize, x);
    if (on) {
        oled_buf[idx] |= (@as(u8, 1) << @as(u3, @truncate(bit)));
    } else {
        oled_buf[idx] &= ~(@as(u8, 1) << @as(u3, @truncate(bit)));
    }
}

/// Clear the entire display buffer to black.
pub fn oledClear() void {
    @memset(&oled_buf, 0);
}

/// Draw a single 5x7 character at pixel position (x, y).
/// Characters are 6px wide (5px glyph + 1px space).
fn oledDrawChar(x: u8, y: u8, c: u8) void {
    const glyph = fontChar(c);
    var col: u8 = 0;
    while (col < 5) : (col += 1) {
        var row: u8 = 0;
        while (row < 7) : (row += 1) {
            oledSetPixel(x + col, y + row, (glyph[col] & (@as(u8, 1) << @as(u3, @truncate(row)))) != 0);
        }
    }
}

/// Draw a null-terminated or sliced string at (x, y).
/// Wraps at display edge. No newline handling — single line only.
fn oledDrawStr(x: u8, y: u8, s: []const u8) void {
    var cx = x;
    for (s) |c| {
        if (cx + 5 > OLED_WIDTH) break;
        oledDrawChar(cx, y, c);
        cx += 6; // 5px glyph + 1px spacing
    }
}

/// Format an integer and draw it at (x, y).
/// Uses std.fmt.bufPrint — may fail if the number doesn't fit in the buffer.
/// On failure, draws nothing (silent).
fn oledDrawInt(x: u8, y: u8, n: i32) void {
    var buf: [12]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{n}) catch return;
    oledDrawStr(x, y, s);
}

/// Draw a horizontal progress bar with border.
/// (x, y): top-left corner
/// w, h: width and height in pixels
/// pct: fill percentage (0-100)
/// Minimum size: 3x3 pixels (1px border + 1px fill)
fn oledDrawBar(x: u8, y: u8, w: u8, h: u8, pct: u8) void {
    var row: u8 = 0;
    while (row < h) : (row += 1) {
        if (row == 0 or row == h - 1) {
            // Top and bottom borders — full-width horizontal line
            var col: u8 = 0;
            while (col < w) : (col += 1) {
                oledSetPixel(x + col, y + row, true);
            }
        } else {
            // Side borders
            oledSetPixel(x, y + row, true);
            oledSetPixel(x + w - 1, y + row, true);
            // Fill proportional to pct (inner width = w - 2)
            const fill_w: u8 = @intCast((@as(u16, w) - 2) * pct / 100);
            var col: u8 = 1;
            while (col <= fill_w) : (col += 1) {
                oledSetPixel(x + col, y + row, true);
            }
        }
    }
}

/// Send SSD1306 initialization sequence.
/// Must be called after oled_i2c_init() succeeds, Vext is enabled,
/// and OLED RST is released.
/// The sequence configures clock, mux ratio, charge pump,
/// orientation, contrast, and turns the display on.
pub fn oledInit() void {
    const init_seq = [_]u8{
        0xAE,           // Display OFF (sleep mode)
        0xD5, 0x80,     // Set display clock divide ratio/oscillator frequency
        0xA8, 0x3F,     // Set multiplex ratio to 63 (64 rows)
        0xD3, 0x00,     // Set display offset = 0
        0x40,           // Set display start line to 0
        0x8D, 0x14,     // Enable charge pump regulator
        0x20, 0x00,     // Set memory addressing mode to horizontal
        0xA1,           // Set segment re-map (column 127 = SEG0)
        0xC8,           // Set COM output scan direction (remapped)
        0xDA, 0x12,     // Set COM pins hardware configuration
        0x81, 0xCF,     // Set contrast control
        0xD9, 0xF1,     // Set pre-charge period
        0xDB, 0x40,     // Set VCOMH deselect level
        0xA4,           // Entire display ON (resume to RAM content)
        0xA6,           // Set normal display (not inverted)
        0xAF,           // Display ON
    };
    _ = main.oled_i2c_write(0x00, &init_seq, init_seq.len);
}

/// Transmit the display buffer to the SSD1306 over I2C.
/// Sends 8 pages of 128 bytes each. Each page is preceded by
/// three command bytes: set page address (0xB0+page),
/// set low column (0x00), set high column (0x10).
pub fn oledUpdate() void {
    var page: u8 = 0;
    while (page < 8) : (page += 1) {
        const cmds = [_]u8{ 0xB0 + page, 0x00, 0x10 };
        _ = main.oled_i2c_write(0x00, &cmds, cmds.len);

        const page_start: usize = @as(usize, page) * @as(usize, OLED_WIDTH);
        _ = main.oled_i2c_write(0x40, oled_buf[page_start..][0..OLED_WIDTH].ptr, OLED_WIDTH);
    }
}

// ================================================================
// DISPLAY PAGES
// ================================================================
//
// Multiple pages cycled by short-pressing the PRG button.
// Pages are drawn on-demand (not continuously) to save CPU.

pub var current_page: u8 = 0;
pub const NUM_PAGES: u8 = 7;

/// Draw page number indicator top-right (e.g. "1/7").
fn drawPageNum(page: u8) void {
    var buf: [4]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}/{d}", .{ page + 1, NUM_PAGES }) catch return;
    oledDrawStr(96, 0, s);
}

/// Draw a battery bar: label + voltage + bar graphic.
/// 3.3V = 0%, 4.2V = 100% (LiPo range).
pub fn drawBatteryBar(x: u8, y: u8, w: u8, h: u8) void {
    const mv = main.battery_read_mv();
    const pct: u8 = if (mv < 3300) 0 else if (mv > 4200) 100 else @intCast(((@as(u32, @intCast(mv)) - 3300) * 100 / 900));

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
    var alpr_count: u32 = 0;
    var ble_count: u32 = 0;
    var drone_count: u32 = 0;
    var raven_count: u32 = 0;
    var cam_count: u32 = 0;
    for (0..main.tracker_count) |i| {
        switch (main.trackers[i].kind) {
            .flock_camera, .wifi_device => alpr_count += 1,
            .drone => drone_count += 1,
            .raven => raven_count += 1,
            .camera => cam_count += 1,
            else => ble_count += 1,
        }
    }

    oledClear();
    drawPageNum(0);
    oledDrawStr(0, 0, "ARGUS");
    oledDrawStr(0, 18, "ALPR:");
    oledDrawInt(48, 18, @intCast(alpr_count));
    oledDrawStr(78, 18, "DRN:");
    oledDrawInt(108, 18, @intCast(drone_count));
    oledDrawStr(0, 28, "BLE:");
    oledDrawInt(48, 28, @intCast(ble_count));
    oledDrawStr(78, 28, "RAV:");
    oledDrawInt(108, 28, @intCast(raven_count));
    oledDrawStr(0, 36, "CAM:");
    oledDrawInt(48, 36, @intCast(cam_count));
    oledDrawInt(78, 36, @intCast(main.KNOWN_OUIS_COUNT));
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

/// Page 1: Active threats list (all trackers, sorted by last_seen desc)
fn drawThreats() void {
    oledClear();
    drawPageNum(1);
    oledDrawStr(0, 0, "THREATS");

    var row: u8 = 0;
    const start = if (main.tracker_count > 6) main.tracker_count - 6 else 0;
    for (start..main.tracker_count) |i| {
        if (row >= 6) break;
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
    oledDrawStr(0, 56, "PRG:next page");
    oledUpdate();
}

/// Page 2: Proximity gauge for nearest threat
fn drawProximity() void {
    oledClear();
    drawPageNum(2);
    oledDrawStr(0, 0, "PROXIMITY");

    if (main.tracker_count == 0) {
        oledDrawStr(0, 18, "No threats nearby");
        oledDrawStr(0, 56, "PRG:next page");
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
    var buf: [32]u8 = undefined;
    const mac_str = formatMac(t.mac, buf[0..17]);
    oledDrawStr(0, 12, mac_str);
    oledDrawStr(0, 22, kindStr(t.kind));

    // Drone model name if available (WiFi Remote ID Self-ID)
    if (t.kind == .drone and scanner.drone_model_buf[0] != 0) {
        const model = std.mem.sliceTo(&scanner.drone_model_buf, 0);
        oledDrawStr(30, 22, model);
    }

    // Score badge
    var score_buf: [16]u8 = undefined;
    _ = std.fmt.bufPrint(&score_buf, "SC: {d} {s}", .{ t.score, scoreLevel(t.score) }) catch {};
    oledDrawStr(0, 34, &score_buf);

    // GPS coordinates if fix available
    if (scanner.gps_fix) {
        var gps_buf: [32]u8 = undefined;
        _ = std.fmt.bufPrint(&gps_buf, "GPS:{d}.{d} {d}.{d}", .{
            @divTrunc(scanner.gps_lat, 1000000), @abs(@rem(@divTrunc(scanner.gps_lat, 10000), 100)),
            @divTrunc(scanner.gps_lon, 1000000), @abs(@rem(@divTrunc(scanner.gps_lon, 10000), 100)),
        }) catch {};
        oledDrawStr(0, 44, &gps_buf);
    }

    // RSSI bar: -100 = 0%, -20 = 100%
    const rssi_pct: u8 = if (t.rssi < -100) 0 else if (t.rssi > -20) 100 else blk: {
        const val: u32 = @intCast(@as(i32, t.rssi) + 100);
        break :blk @intCast(val * 100 / 80);
    };
    oledDrawBar(0, 44, 128, 10, rssi_pct);

    oledDrawStr(0, 56, "PRG:next page");
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
    oledDrawStr(0, 0, "BLE TRACKERS");

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
    oledDrawStr(0, 14, "Firmware: v1.0");
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

/// Route to the current page. Called on button press, at boot, and on new detection.
pub fn drawPage() void {
    switch (current_page) {
        0 => drawSummary(),
        1 => drawThreats(),
        2 => drawProximity(),
        3 => drawHistory(),
        4 => drawBleList(),
        5 => drawStats(),
        6 => drawSystem(),
        else => drawSummary(),
    }
}

/// LED alert pattern by confidence score.
/// 0-39: silent.  40-69: single blink.  70-84: three blinks.  85+: five blinks.
/// Each blink is 40ms on, 40ms off. Uses delayMs which yields to FreeRTOS.
pub fn alertLed(score: u8) void {
    if (score < scanner.SCORE_MED) return;
    const count: u32 = if (score >= scanner.SCORE_CERT) 5 else if (score >= scanner.SCORE_HIGH) 3 else 1;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        ledOn();  main.delayMs(40); ledOff(); main.delayMs(40);
    }
}
