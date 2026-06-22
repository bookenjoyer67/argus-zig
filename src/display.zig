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

/// Draw a single 5x7 character scaled up by `scale`.
/// Each font pixel becomes a scale×scale block. Used for the big
/// RSSI readout on the proximity page (scale 3 ≈ 15x21px glyphs).
fn oledDrawCharScaled(x: u8, y: u8, c: u8, scale: u8) void {
    const glyph = fontChar(c);
    var col: u8 = 0;
    while (col < 5) : (col += 1) {
        var row: u8 = 0;
        while (row < 7) : (row += 1) {
            if ((glyph[col] & (@as(u8, 1) << @as(u3, @truncate(row)))) == 0) continue;
            var sx: u8 = 0;
            while (sx < scale) : (sx += 1) {
                var sy: u8 = 0;
                while (sy < scale) : (sy += 1) {
                    oledSetPixel(x +% col * scale +% sx, y +% row * scale +% sy, true);
                }
            }
        }
    }
}

/// Draw a scaled string. Character advance is (5+1)*scale pixels.
fn oledDrawStrScaled(x: u8, y: u8, s: []const u8, scale: u8) void {
    var cx = x;
    const advance: u8 = 6 *% scale;
    for (s) |c| {
        oledDrawCharScaled(cx, y, c, scale);
        cx +|= advance;
    }
}

/// Draw a small directional chevron at (x, y) in a 9x5 box.
///   dir > 0: up-pointing triangle   (signal rising — getting closer)
///   dir < 0: down-pointing triangle (signal falling — moving away)
///   dir == 0: horizontal dash       (stable)
/// Drawn pixel-by-pixel since the 5x7 font has no arrow glyphs.
fn drawArrow(x: u8, y: u8, dir: i8) void {
    if (dir == 0) {
        var i: u8 = 0;
        while (i < 9) : (i += 1) oledSetPixel(x + i, y + 2, true);
        return;
    }
    const up = dir > 0;
    var r: u8 = 0;
    while (r < 5) : (r += 1) {
        const row: u8 = if (up) r else 4 - r;
        var c: u8 = 0;
        while (c <= r) : (c += 1) {
            oledSetPixel(x + 4 - c, y + row, true);
            oledSetPixel(x + 4 + c, y + row, true);
        }
    }
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

/// Turn the SSD1306 panel off (0xAE) — used by stealth mode.
/// The display RAM is preserved; oledDisplayOn() restores it instantly.
pub fn oledDisplayOff() void {
    const cmd = [_]u8{0xAE};
    _ = main.oled_i2c_write(0x00, &cmd, cmd.len);
}

/// Turn the SSD1306 panel back on (0xAF) — used when waking from stealth.
pub fn oledDisplayOn() void {
    const cmd = [_]u8{0xAF};
    _ = main.oled_i2c_write(0x00, &cmd, cmd.len);
}

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

// ================================================================
// DISPLAY PAGES
// ================================================================
//
// Multiple pages cycled by short-pressing the PRG button.
// Pages are drawn on-demand (not continuously) to save CPU.

pub var current_page: u8 = 0;
pub const NUM_PAGES: u8 = 8;

/// Draw page number indicator top-right (e.g. "1/7").
fn drawPageNum(page: u8) void {
    var buf: [4]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}/{d}", .{ page + 1, NUM_PAGES }) catch return;
    oledDrawStr(96, 0, s);
}

/// Map battery millivolts to a percentage (3.3V = 0%, 4.2V = 100%).
pub fn batteryPct(mv: i32) u8 {
    if (mv < 3300) return 0;
    if (mv > 4200) return 100;
    return @intCast((@as(u32, @intCast(mv)) - 3300) * 100 / 900);
}

/// Draw a battery bar: label + voltage + bar graphic.
/// 3.3V = 0%, 4.2V = 100% (LiPo range).
pub fn drawBatteryBar(x: u8, y: u8, w: u8, h: u8) void {
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
    var surv_count: u32 = 0;  // surveillance: ALPR, drone, raven, camera, stingray
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
/// Stronger signal = closer. Tuned for BLE/WiFi at 0 dBm TX.
fn distanceWord(rssi: i8) []const u8 {
    if (rssi >= -50) return "HERE";
    if (rssi >= -65) return "CLOSE";
    if (rssi >= -80) return "NEAR";
    if (rssi >= -90) return "FAR";
    return "----";
}

/// RSSI delta tracking for the proximity arrow.
/// prox_prev_rssi holds the value sampled ~500ms ago; the proximity
/// page compares the live RSSI against it to pick an up/down/stable arrow.
var prox_prev_rssi: i8 = 0;
var prox_prev_ms: u32 = 0;

/// Page 2: Proximity finder — big RSSI readout, trend arrow, distance word.
/// Refreshed every ~500ms from the main loop so the readout tracks movement.
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
    // ±2 dBm deadband keeps a steady signal from flickering up/down.
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

/// Page 7: All OUI-matched devices — visibility without alerting.
/// Lists every tracker whose OUI matched the database, with the vendor name
/// and RSSI, regardless of score. The "?" flags these as OUI-only: the chip
/// vendor is known, but without SSID corroboration the device kind is a guess.
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
    switch (current_page) {
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
