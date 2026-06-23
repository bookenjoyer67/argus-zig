//! === Board: Lilygo T-Deck (ESP32-S3) ===
//!
//! Wires the T-Deck's drivers into the common board interface. Selected by
//! BOARD=tdeck. Phase 2 covers the display only; input (keyboard/trackball),
//! audio (I2S speaker), and storage (microSD) are stubbed until Phase 3.

const main = @import("../main.zig");
const st7789 = @import("../hal/st7789.zig");

// Verified pins (official Lilygo utilities.h). Most live in main/tft.c;
// kept here for documentation + future phases.
pub const PIN_POWERON: u32 = 10; // peripheral power gate (drive HIGH)
pub const PIN_SPI_SCK: u32 = 40;
pub const PIN_SPI_MOSI: u32 = 41;
pub const PIN_SPI_MISO: u32 = 38;
pub const PIN_TFT_CS: u32 = 12;
pub const PIN_TFT_DC: u32 = 11;
pub const PIN_TFT_BL: u32 = 42;
pub const PIN_I2C_SDA: u32 = 18; // keyboard/touch (Phase 3)
pub const PIN_I2C_SCL: u32 = 8;
pub const PIN_BAT_ADC: u32 = 4;

// ---- Common board interface ----
/// ST7789 framebuffer backend (the gfx backend).
pub const display_driver = st7789;

/// No user LED on the T-Deck — alerts are screen/speaker (Phase 3). No-op.
pub const led = struct {
    pub fn pwmInit() void {}
    pub fn set(_: u32) void {}
    pub fn on() void {}
    pub fn off() void {}
    pub fn alertLed(_: u8) void {}
};

/// No PRG button — input is the keyboard/trackball (Phase 3). Stub.
pub const button = struct {
    pub fn initPullup() void {}
    pub fn pressed() bool {
        return false;
    }
};

/// Board-specific color dashboard UI.
pub const ui = @import("tdeck_ui.zig");

/// Bring up the ST7789 panel + PSRAM framebuffer and show the boot screen.
/// Returns true if init failed (e.g. PSRAM framebuffer alloc).
pub fn init() bool {
    if (st7789.init() != 0) return true;
    ui.drawBoot(""); // big "ARGUS"
    main.delayMs(400);
    ui.drawBoot("Scanning...");
    main.delayMs(400);
    ui.drawPage();
    return false;
}

/// Setup-mode display bring-up.
pub fn initSetup() void {
    _ = st7789.init();
    ui.drawSetup();
}
