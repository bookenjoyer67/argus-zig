//! === ST7789 320x240 TFT backend (T-Deck) ===
//!
//! gfx backend for the T-Deck's color panel. The SPI/esp_lcd plumbing and the
//! PSRAM framebuffer live in main/tft.c; this module writes RGB565 pixels into
//! that framebuffer and triggers the flush.
//!
//! Phase 2 is monochrome-on-color: setPixel(on) writes white (0xFFFF) or black
//! (0x0000), so the shared mono gfx renders unchanged. A color path comes later.

// C side (main/tft.c, compiled only under BOARD_TDECK).
extern fn tft_init() i32;
extern fn tft_fb() ?[*]u16;
extern fn tft_flush() void;
extern fn tft_backlight(on: i32) void;

pub const WIDTH: u16 = 320;
pub const HEIGHT: u16 = 240;

var fb: ?[*]u16 = null;

/// Bring up the panel + PSRAM framebuffer. Returns the C rc (0 = ok).
pub fn init() i32 {
    const rc = tft_init();
    fb = tft_fb();
    return rc;
}

/// Write one pixel into the framebuffer. on → white, off → black (Phase 2 mono).
pub fn setPixel(x: u16, y: u16, on: bool) void {
    if (x >= WIDTH or y >= HEIGHT) return;
    const f = fb orelse return;
    f[@as(usize, y) * WIDTH + @as(usize, x)] = if (on) 0xFFFF else 0x0000;
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
