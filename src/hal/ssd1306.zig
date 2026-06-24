//! === SSD1306 128x64 monochrome OLED driver (I2C) ===
//!
//! Pure-Zig, page-addressed framebuffer. Extracted from the original
//! display.zig. The low-level I2C transfer goes through main.oled_i2c_write
//! (a thin C wrapper resolved by the linker).
//!
//! Framebuffer layout:
//!   buf[page*WIDTH + x] — 8 pages of 128 bytes = 1024 bytes
//!   Each byte is 8 vertical pixels (bit 0 = top pixel of the page).
//!
//! This module satisfies the gfx backend contract: it exposes WIDTH, HEIGHT,
//! setPixel(), clear(), and update().

const main = @import("../main.zig");

pub const ADDR: u8 = 0x3C; // SSD1306 I2C address (SA0=GND)
pub const WIDTH: u8 = 128;
pub const HEIGHT: u8 = 64;

// 128 * 64 / 8 = 1024 bytes. usize cast avoids u8 overflow in the product.
pub const BUF_SIZE: usize = (@as(usize, WIDTH) * HEIGHT) / 8;
pub var buf: [BUF_SIZE]u8 = [_]u8{0} ** BUF_SIZE;

/// Set a single pixel. Coordinates outside bounds are clipped.
/// page = y / 8, bit = y % 8.  (u16 coords for a shared gfx layer.)
pub fn setPixel(x: u16, y: u16, on: bool) void {
    if (x >= @as(u16, WIDTH) or y >= @as(u16, HEIGHT)) return;
    const page: u16 = y / 8;
    const bit: u8 = @intCast(y % 8);
    const idx: usize = @as(usize, page) * @as(usize, WIDTH) + @as(usize, x);
    if (on) {
        buf[idx] |= (@as(u8, 1) << @as(u3, @truncate(bit)));
    } else {
        buf[idx] &= ~(@as(u8, 1) << @as(u3, @truncate(bit)));
    }
}

/// Clear the entire framebuffer to black.
pub fn clear() void {
    @memset(&buf, 0);
}

/// Send the SSD1306 init sequence. Call after oled_i2c_init() succeeds,
/// Vext is enabled, and OLED RST is released.
pub fn init() void {
    const init_seq = [_]u8{
        0xAE, // Display OFF (sleep mode)
        0xD5, 0x80, // Set display clock divide ratio/oscillator frequency
        0xA8, 0x3F, // Set multiplex ratio to 63 (64 rows)
        0xD3, 0x00, // Set display offset = 0
        0x40, // Set display start line to 0
        0x8D, 0x14, // Enable charge pump regulator
        0x20, 0x00, // Set memory addressing mode to horizontal
        0xA1, // Set segment re-map (column 127 = SEG0)
        0xC8, // Set COM output scan direction (remapped)
        0xDA, 0x12, // Set COM pins hardware configuration
        0x81, 0xCF, // Set contrast control
        0xD9, 0xF1, // Set pre-charge period
        0xDB, 0x40, // Set VCOMH deselect level
        0xA4, // Entire display ON (resume to RAM content)
        0xA6, // Set normal display (not inverted)
        0xAF, // Display ON
    };
    _ = main.oled_i2c_write(0x00, &init_seq, init_seq.len);
}

var i2c_fail_count: u8 = 0;
var i2c_reported: bool = false;

/// Transmit the framebuffer over I2C — 8 pages of 128 bytes each.
/// Tracks I2C failures; on repeated failures triggers board error pattern.
pub fn update() void {
    var page: u8 = 0;
    while (page < 8) : (page += 1) {
        const cmds = [_]u8{ 0xB0 + page, 0x00, 0x10 };
        if (main.oled_i2c_write(0x00, &cmds, cmds.len) != 0) {
            i2c_fail_count += 1;
            if (!i2c_reported) {
                i2c_reported = true;
                // First failure — log to serial
            }
            if (i2c_fail_count >= 16) {
                main.init_failed = true;
            }
            return;
        }

        const page_start: usize = @as(usize, page) * @as(usize, WIDTH);
        if (main.oled_i2c_write(0x40, buf[page_start..][0..WIDTH].ptr, WIDTH) != 0) {
            i2c_fail_count += 1;
            if (!i2c_reported) {
                i2c_reported = true;
            }
            if (i2c_fail_count >= 16) {
                main.init_failed = true;
            }
            return;
        }
    }
    if (i2c_fail_count > 0) i2c_fail_count -= 1;
}

/// Turn the panel off (0xAE) — used by stealth mode. RAM is preserved.
pub fn displayOff() void {
    const cmd = [_]u8{0xAE};
    _ = main.oled_i2c_write(0x00, &cmd, cmd.len);
}

/// Turn the panel back on (0xAF).
pub fn displayOn() void {
    const cmd = [_]u8{0xAF};
    _ = main.oled_i2c_write(0x00, &cmd, cmd.len);
}
