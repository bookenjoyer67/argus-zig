//! === Board: Heltec WiFi LoRa 32 V3 (ESP32-S3) ===
//!
//! Centralizes the Heltec V3 pin map and wires the board's drivers into the
//! common board interface (init / initSetup / led / button / ui /
//! display_driver). Selected at build time by build-zig.sh (BOARD=heltec_v3,
//! the default) and surfaced to the firmware via the generated board.zig shim.

const main = @import("../main.zig");
const display = @import("../display.zig");
const traits = @import("board.zig");
const ssd1306 = @import("../hal/ssd1306.zig");

// ---- Pin map (Heltec V3, top view, USB-C down) ----
pub const PIN_LED: u32 = 35; // Onboard white LED (J2 pin 10), active HIGH
pub const PIN_BUTTON: u32 = 0; // PRG button (J2 pin 8), active LOW, needs pullup
pub const PIN_OLED_SDA: u32 = 17; // OLED I2C SDA (internal)
pub const PIN_OLED_SCL: u32 = 18; // OLED I2C SCL (internal)
pub const PIN_OLED_RST: u32 = 21; // OLED reset (J2 pin 16)
pub const PIN_VEXT: u32 = 36; // Vext control: active LOW (P-channel MOSFET)
pub const PIN_BAT_ADC: u32 = 1; // Battery ADC (390k/100k divider)

// ---- Common board interface ----
/// SSD1306 framebuffer + I2C driver (the gfx backend).
pub const display_driver = ssd1306;
/// White-LED PWM + alert blink (Heltec's "audio").
pub const led = @import("../hal/led.zig").Led(PIN_LED);
/// PRG button input.
pub const button = @import("../hal/button.zig").Button(PIN_BUTTON);
/// Board-specific 8-page OLED UI.
pub const ui = @import("heltec_v3_ui.zig");

/// Audio alert hook. The Heltec has no speaker — its threat-level LED already
/// conveys this — so this is a no-op (kept for the common board interface).
pub fn alert(score: u8) void {
    _ = score;
}

/// PRG-button gesture FSM (was inline in zig_main). Blocking/timing-based:
/// debounce → hold (>=1.2s CSV dump, >=15s also clear) → else 350ms
/// double-press window (double = stealth, single = next page). Drives the
/// shared UI actions in main.zig. Behavior identical to the pre-refactor loop.
pub const input = struct {
    pub fn handle() void {
        if (!button.pressed()) return;
        main.delayMs(50);
        if (!button.pressed()) return;

        var hold_ms: u32 = 50;
        while (button.pressed() and hold_ms < 15200) {
            main.delayMs(50);
            hold_ms += 50;
        }

        if (hold_ms >= 1200) {
            // Long press — CSV dump over serial (suppressed in stealth).
            if (!main.stealth_mode) main.dumpCsv(hold_ms >= 15000);
            while (button.pressed()) main.delayMs(10);
        } else {
            // Short press released — watch ~350ms for a second press.
            var waited: u32 = 0;
            var double_press = false;
            while (waited < 350) {
                if (button.pressed()) {
                    double_press = true;
                    break;
                }
                main.delayMs(10);
                waited += 10;
            }
            if (double_press) {
                main.delayMs(40); // debounce second press
                main.toggleStealth();
                while (button.pressed()) main.delayMs(10);
            } else if (!main.stealth_mode) {
                main.nextPage();
            }
        }

        if (!main.stealth_mode) display.drawPage();
    }
};

/// Bring up the board for normal operation: LED PWM, button, Vext rail, OLED
/// reset + I2C + init, and the boot screen. Returns true if a hardware init
/// step failed (drives the LED error pattern). Extracted from zig_main().
pub fn init() bool {
    led.pwmInit();
    button.initPullup();

    // Boot LED: solid on (power good), then a quick double-blink (booted).
    led.on();
    main.delayMs(200);
    led.off();
    main.delayMs(80);
    led.on();
    main.delayMs(40);
    led.off();
    main.delayMs(80);
    led.on();
    main.delayMs(40);
    led.off();
    main.delayMs(80);

    // Vext (active LOW) powers the OLED rail; enable before reset/init.
    _ = main.gpio_pin_init(PIN_VEXT, main.GPIO_OUTPUT, main.GPIO_PULL_NONE);
    _ = main.gpio_write(PIN_VEXT, 0);
    main.delayMs(50);

    _ = main.gpio_pin_init(PIN_OLED_RST, main.GPIO_OUTPUT, main.GPIO_PULL_NONE);
    _ = main.gpio_write(PIN_OLED_RST, 0); // hold in reset
    main.delayMs(100);
    _ = main.gpio_write(PIN_OLED_RST, 1); // release reset
    main.delayMs(100);

    if (main.oled_i2c_init() != 0) {
        // OLED not responding — error blink, run headless.
        led.on();
        main.delayMs(50);
        led.off();
        main.delayMs(50);
        led.on();
        main.delayMs(50);
        led.off();
        main.delayMs(50);
        led.on();
        main.delayMs(50);
        led.off();
        return true;
    }

    display.oledInit();
    display.drawBoot(""); // big "ARGUS" logo
    main.delayMs(400);
    display.drawBoot("Scanning...");
    main.delayMs(400);
    display.drawPage(); // flip to summary
    return false;
}

/// Bring up the OLED for setup mode (first-boot onboarding). Extracted from
/// zig_main_setup().
pub fn initSetup() void {
    led.pwmInit();

    _ = main.gpio_pin_init(PIN_VEXT, main.GPIO_OUTPUT, main.GPIO_PULL_NONE);
    _ = main.gpio_write(PIN_VEXT, 0); // enable Vext (active LOW)
    main.delayMs(50);
    _ = main.gpio_pin_init(PIN_OLED_RST, main.GPIO_OUTPUT, main.GPIO_PULL_NONE);
    _ = main.gpio_write(PIN_OLED_RST, 0);
    main.delayMs(100);
    _ = main.gpio_write(PIN_OLED_RST, 1);
    main.delayMs(100);

    if (main.oled_i2c_init() == 0) {
        display.oledInit();
        display.drawSetup();
    }
}

// ---- Trait conformance (documents the contract; firmware calls drivers directly) ----
fn dispSetPixel(x: u16, y: u16, on: bool) void {
    ssd1306.setPixel(@intCast(x), @intCast(y), on);
}

pub const display_trait = traits.Display{
    .width = ssd1306.WIDTH,
    .height = ssd1306.HEIGHT,
    .clear = ssd1306.clear,
    .update = ssd1306.update,
    .setPixel = dispSetPixel,
};
