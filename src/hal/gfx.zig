//! === Shared drawing primitives ===
//!
//! Board-agnostic text/shape rendering, extracted from the original
//! display.zig. `Gfx(D)` is generic over a display backend `D` that exposes:
//!   pub const WIDTH: u8;  pub const HEIGHT: u8;
//!   pub fn setPixel(x: u8, y: u8, on: bool) void;
//!   pub fn clear() void;  pub fn update() void;
//!
//! The 5x7 font table is shared across all instantiations.

const std = @import("std");

/// 5x7 bitmap font: ASCII 32 (space) through 90 (Z).
/// Each entry is 5 bytes, each byte one column (bit 0 = top pixel).
pub const FONT_5X7 = [_]u8{
    0x00, 0x00, 0x00, 0x00, 0x00, // 32: space
    0x00, 0x5F, 0x00, 0x00, 0x00, // 33: !
    0x00, 0x00, 0x00, 0x00, 0x00, // 34: " (placeholder)
    0x14, 0x7F, 0x14, 0x7F, 0x14, // 35: #
    0x24, 0x2A, 0x7F, 0x2A, 0x12, // 36: $
    0x23, 0x13, 0x08, 0x64, 0x62, // 37: %
    0x36, 0x49, 0x55, 0x22, 0x50, // 38: &
    0x00, 0x05, 0x03, 0x00, 0x00, // 39: '
    0x1C, 0x22, 0x41, 0x00, 0x00, // 40: (
    0x41, 0x22, 0x1C, 0x00, 0x00, // 41: )
    0x08, 0x2A, 0x1C, 0x2A, 0x08, // 42: *
    0x08, 0x08, 0x3E, 0x08, 0x08, // 43: +
    0x50, 0x30, 0x00, 0x00, 0x00, // 44: ,
    0x08, 0x08, 0x08, 0x08, 0x08, // 45: -
    0x60, 0x60, 0x00, 0x00, 0x00, // 46: .
    0x20, 0x10, 0x08, 0x04, 0x02, // 47: /
    0x3E, 0x51, 0x49, 0x45, 0x3E, // 48: 0
    0x00, 0x42, 0x7F, 0x40, 0x00, // 49: 1
    0x42, 0x61, 0x51, 0x49, 0x46, // 50: 2
    0x21, 0x41, 0x45, 0x4B, 0x31, // 51: 3
    0x18, 0x14, 0x12, 0x7F, 0x10, // 52: 4
    0x27, 0x45, 0x45, 0x45, 0x39, // 53: 5
    0x3C, 0x4A, 0x49, 0x49, 0x30, // 54: 6
    0x01, 0x71, 0x09, 0x05, 0x03, // 55: 7
    0x36, 0x49, 0x49, 0x49, 0x36, // 56: 8
    0x06, 0x49, 0x49, 0x29, 0x1E, // 57: 9
    0x00, 0x6C, 0x6C, 0x00, 0x00, // 58: :
    0x00, 0x56, 0x36, 0x00, 0x00, // 59: ;
    0x00, 0x08, 0x14, 0x22, 0x41, // 60: <
    0x14, 0x14, 0x14, 0x14, 0x14, // 61: =
    0x41, 0x22, 0x14, 0x08, 0x00, // 62: >
    0x02, 0x01, 0x51, 0x09, 0x06, // 63: ?
    0x32, 0x49, 0x79, 0x41, 0x3E, // 64: @
    0x7E, 0x09, 0x09, 0x09, 0x7E, // 65: A
    0x7F, 0x49, 0x49, 0x49, 0x36, // 66: B
    0x3E, 0x41, 0x41, 0x41, 0x22, // 67: C
    0x7F, 0x41, 0x41, 0x22, 0x1C, // 68: D
    0x7F, 0x49, 0x49, 0x49, 0x41, // 69: E
    0x7F, 0x09, 0x09, 0x01, 0x01, // 70: F
    0x3E, 0x41, 0x49, 0x49, 0x7A, // 71: G
    0x7F, 0x08, 0x08, 0x08, 0x7F, // 72: H
    0x41, 0x7F, 0x41, 0x00, 0x00, // 73: I
    0x30, 0x40, 0x40, 0x3F, 0x00, // 74: J
    0x7F, 0x08, 0x14, 0x22, 0x41, // 75: K
    0x7F, 0x40, 0x40, 0x40, 0x40, // 76: L
    0x7F, 0x02, 0x04, 0x02, 0x7F, // 77: M
    0x7F, 0x04, 0x08, 0x10, 0x7F, // 78: N
    0x3E, 0x41, 0x41, 0x41, 0x3E, // 79: O
    0x7F, 0x09, 0x09, 0x09, 0x06, // 80: P
    0x3E, 0x41, 0x51, 0x21, 0x5E, // 81: Q
    0x7F, 0x09, 0x19, 0x29, 0x46, // 82: R
    0x26, 0x49, 0x49, 0x49, 0x32, // 83: S
    0x01, 0x01, 0x7F, 0x01, 0x01, // 84: T
    0x3F, 0x40, 0x40, 0x40, 0x3F, // 85: U
    0x1F, 0x20, 0x40, 0x20, 0x1F, // 86: V
    0x7F, 0x20, 0x18, 0x20, 0x7F, // 87: W
    0x63, 0x14, 0x08, 0x14, 0x63, // 88: X
    0x03, 0x04, 0x78, 0x04, 0x03, // 89: Y
    0x61, 0x51, 0x49, 0x45, 0x43, // 90: Z
};

/// Look up the 5-column bitmap for an ASCII character.
/// Lowercase folds to uppercase; out-of-range chars render as space.
pub fn fontChar(c: u8) [5]u8 {
    if (c >= 'a' and c <= 'z') return fontChar(c - 32);
    const idx: usize = if (c >= ' ' and c <= 'Z') @intCast(c - ' ') else 0;
    const base = idx * 5;
    return FONT_5X7[base..][0..5].*;
}

/// Build a gfx instance bound to display backend `D`.
/// Coordinates are u16 so the same primitives drive both the 128x64 SSD1306
/// and the 320x240 ST7789. `D` must expose WIDTH/HEIGHT, setPixel(u16,u16,bool),
/// clear(), and update().
pub fn Gfx(comptime D: type) type {
    return struct {
        pub fn clear() void {
            D.clear();
        }

        pub fn update() void {
            D.update();
        }

        /// Draw a single 5x7 character at (x, y). 6px wide (5px glyph + 1px space).
        pub fn drawChar(x: u16, y: u16, c: u8) void {
            const glyph = fontChar(c);
            var col: u16 = 0;
            while (col < 5) : (col += 1) {
                var row: u16 = 0;
                while (row < 7) : (row += 1) {
                    D.setPixel(x + col, y + row, (glyph[col] & (@as(u8, 1) << @as(u3, @truncate(row)))) != 0);
                }
            }
        }

        /// Draw a string at (x, y). Single line; stops at display edge.
        pub fn drawStr(x: u16, y: u16, s: []const u8) void {
            var cx = x;
            for (s) |c| {
                if (cx + 5 > @as(u16, D.WIDTH)) break;
                drawChar(cx, y, c);
                cx += 6; // 5px glyph + 1px spacing
            }
        }

        /// Format an integer and draw it at (x, y). Silent on format failure.
        pub fn drawInt(x: u16, y: u16, n: i32) void {
            var buf: [12]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d}", .{n}) catch return;
            drawStr(x, y, s);
        }

        /// Draw a single character scaled up by `scale` (scale×scale blocks).
        pub fn drawCharScaled(x: u16, y: u16, c: u8, scale: u8) void {
            const glyph = fontChar(c);
            const sc: u16 = scale;
            var col: u16 = 0;
            while (col < 5) : (col += 1) {
                var row: u16 = 0;
                while (row < 7) : (row += 1) {
                    if ((glyph[col] & (@as(u8, 1) << @as(u3, @truncate(row)))) == 0) continue;
                    var sx: u16 = 0;
                    while (sx < sc) : (sx += 1) {
                        var sy: u16 = 0;
                        while (sy < sc) : (sy += 1) {
                            D.setPixel(x +% col *% sc +% sx, y +% row *% sc +% sy, true);
                        }
                    }
                }
            }
        }

        /// Draw a scaled string. Character advance is (5+1)*scale pixels.
        pub fn drawStrScaled(x: u16, y: u16, s: []const u8, scale: u8) void {
            var cx = x;
            const advance: u16 = 6 *% @as(u16, scale);
            for (s) |c| {
                drawCharScaled(cx, y, c, scale);
                cx +|= advance;
            }
        }

        /// Directional chevron in a 9x5 box. dir>0 up, dir<0 down, 0 dash.
        pub fn drawArrow(x: u16, y: u16, dir: i8) void {
            if (dir == 0) {
                var i: u16 = 0;
                while (i < 9) : (i += 1) D.setPixel(x + i, y + 2, true);
                return;
            }
            const up = dir > 0;
            var r: u16 = 0;
            while (r < 5) : (r += 1) {
                const row: u16 = if (up) r else 4 - r;
                var c: u16 = 0;
                while (c <= r) : (c += 1) {
                    D.setPixel(x + 4 - c, y + row, true);
                    D.setPixel(x + 4 + c, y + row, true);
                }
            }
        }

        /// Horizontal progress bar with border. pct = 0..100. Min 3x3.
        pub fn drawBar(x: u16, y: u16, w: u16, h: u16, pct: u8) void {
            var row: u16 = 0;
            while (row < h) : (row += 1) {
                if (row == 0 or row == h - 1) {
                    var col: u16 = 0;
                    while (col < w) : (col += 1) {
                        D.setPixel(x + col, y + row, true);
                    }
                } else {
                    D.setPixel(x, y + row, true);
                    D.setPixel(x + w - 1, y + row, true);
                    const fill_w: u16 = @intCast((@as(u32, w) - 2) * pct / 100);
                    var col: u16 = 1;
                    while (col <= fill_w) : (col += 1) {
                        D.setPixel(x + col, y + row, true);
                    }
                }
            }
        }
    };
}
