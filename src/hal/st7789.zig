//! === ST7789 320x240 TFT backend (T-Deck) ===
//!
//! gfx backend for the T-Deck's color panel. The SPI/esp_lcd plumbing and the
//! PSRAM framebuffer live in main/tft.c; this module writes RGB565 pixels into
//! that framebuffer and triggers the flush.
//!
//! The shared mono gfx stays boolean: setPixel(on) writes the current
//! foreground color (set via setColor, RGB565), off writes the background.
//! tdeck_ui sets the color per element to match the web dashboard palette.

// C side (main/tft.c, compiled only under BOARD_TDECK).
extern fn tft_init() i32;
extern fn tft_fb() ?[*]u16;
extern fn tft_flush() void;
extern fn tft_backlight(on: i32) void;

pub const WIDTH: u16 = 320;
pub const HEIGHT: u16 = 240;
pub const BG: u16 = 0x0000; // background (black)

var fb: ?[*]u16 = null;
var fg: u16 = 0xFFFF; // current foreground color (RGB565)

/// Set the foreground color used by subsequent setPixel(on=true) writes.
pub fn setColor(c: u16) void {
    fg = c;
}

/// Bring up the panel + PSRAM framebuffer. Returns the C rc (0 = ok).
pub fn init() i32 {
    const rc = tft_init();
    fb = tft_fb();
    return rc;
}

/// Write one pixel: on → current foreground color, off → background.
pub fn setPixel(x: u16, y: u16, on: bool) void {
    if (x >= WIDTH or y >= HEIGHT) return;
    const f = fb orelse return;
    f[@as(usize, y) * WIDTH + @as(usize, x)] = if (on) fg else BG;
}

/// Clear the framebuffer to black.
pub fn clear() void {
    const f = fb orelse return;
    const n: usize = @as(usize, WIDTH) * HEIGHT;
    var i: usize = 0;
    while (i < n) : (i += 1) f[i] = 0x0000;
}

/// Push the framebuffer to the panel over SPI/DMA.
pub fn update() void {
    tft_flush();
}

/// Stealth mode: kill the backlight (panel RAM preserved).
pub fn displayOff() void {
    tft_backlight(0);
}

/// Wake from stealth.
pub fn displayOn() void {
    tft_backlight(1);
}
