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

// Trackball: 4 direction GPIOs (active-LOW pulses) + center-click on GPIO0.
pub const PIN_TB_UP: u32 = 3; // G01
pub const PIN_TB_DOWN: u32 = 2; // G02
pub const PIN_TB_LEFT: u32 = 15; // G03
pub const PIN_TB_RIGHT: u32 = 1; // G04
pub const PIN_TB_CLICK: u32 = 0; // center click (also the boot strap)

// T-Deck keyboard (main/keyboard.c, compiled only under BOARD_TDECK).
extern fn kbd_init() i32;
extern fn kbd_read() i32;

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

/// Bring up the ST7789 panel + PSRAM framebuffer, the keyboard, the trackball,
/// and show the boot screen. Returns true if init failed (e.g. framebuffer).
pub fn init() bool {
    if (st7789.init() != 0) return true;

    _ = kbd_init();
    // Trackball: direction GPIOs + center-click as input with pullup
    // (each pulses active-LOW as the ball rolls / is clicked).
    _ = main.gpio_pin_init(PIN_TB_UP, main.GPIO_INPUT, main.GPIO_PULL_UP);
    _ = main.gpio_pin_init(PIN_TB_DOWN, main.GPIO_INPUT, main.GPIO_PULL_UP);
    _ = main.gpio_pin_init(PIN_TB_LEFT, main.GPIO_INPUT, main.GPIO_PULL_UP);
    _ = main.gpio_pin_init(PIN_TB_RIGHT, main.GPIO_INPUT, main.GPIO_PULL_UP);
    _ = main.gpio_pin_init(PIN_TB_CLICK, main.GPIO_INPUT, main.GPIO_PULL_UP);

    ui.drawBoot(""); // big "ARGUS"
    main.delayMs(400);
    ui.drawBoot("Scanning...");
    main.delayMs(400);
    ui.drawPage();
    return false;
}

/// Keyboard + trackball input → shared UI actions.
/// Keys 1-6 jump to views; 'd' dumps CSV. Trackball up/down pages prev/next;
/// center-click toggles stealth. Non-blocking (polled once per main loop).
pub const input = struct {
    var last_key: i32 = 0;
    var prev_up: i32 = 1;
    var prev_down: i32 = 1;
    var prev_click: i32 = 1;

    pub fn handle() void {
        // Center-click → stealth toggle (works in stealth too, to wake).
        const click = main.gpio_read(PIN_TB_CLICK);
        if (click == 0 and prev_click == 1) {
            main.toggleStealth();
            if (!main.stealth_mode) ui.drawPage();
        }
        prev_click = click;
        if (main.stealth_mode) return;

        // Keyboard: act once per new keypress.
        const key = kbd_read();
        if (key > 0 and key != last_key) {
            switch (key) {
                '1'...'6' => {
                    main.gotoPage(@intCast(key - '1'));
                    ui.drawPage();
                },
                'd', 'D' => main.dumpCsv(false),
                else => {},
            }
        }
        last_key = key;

        // Trackball vertical axis → previous/next page (edge-triggered).
        const up = main.gpio_read(PIN_TB_UP);
        if (up == 0 and prev_up == 1) {
            main.prevPage();
            ui.drawPage();
        }
        prev_up = up;

        const down = main.gpio_read(PIN_TB_DOWN);
        if (down == 0 and prev_down == 1) {
            main.nextPage();
            ui.drawPage();
        }
        prev_down = down;
    }
};

/// Setup-mode display bring-up.
pub fn initSetup() void {
    _ = st7789.init();
    ui.drawSetup();
}
