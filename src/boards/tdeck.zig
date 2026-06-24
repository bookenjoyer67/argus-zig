//! === Board: Lilygo T-Deck (ESP32-S3) ===
//!
//! Wires the T-Deck's drivers into the common board interface. Selected by
//! BOARD=tdeck. Phase 2 covers the display only; input (keyboard/trackball),
//! audio (I2S speaker), and storage (microSD) are stubbed until Phase 3.

const main = @import("../main.zig");
const display = @import("../display.zig");
const st7789 = @import("../hal/st7789.zig");
const scanner = @import("../scanner.zig");

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
// Mapping per Lilygo factory firmware: G01=up, G02=right, G03=down, G04=left.
pub const PIN_TB_UP: u32 = 3; // G01
pub const PIN_TB_DOWN: u32 = 15; // G03
pub const PIN_TB_LEFT: u32 = 1; // G04
pub const PIN_TB_RIGHT: u32 = 2; // G02
pub const PIN_TB_CLICK: u32 = 0; // center click (also the boot strap)

// T-Deck keyboard (main/keyboard.c, compiled only under BOARD_TDECK).
extern fn kbd_init() i32;
extern fn kbd_read() i32;

// T-Deck I2S speaker (main/speaker.c).
extern fn spk_init() i32;
extern fn spk_tone(freq_hz: i32, ms: i32, vol: i32) void;

// T-Deck microSD (main/sdcard.c) on the shared SPI2 bus.
extern fn sd_init() i32;
extern fn sd_append_line(path: [*:0]const u8, line: [*:0]const u8) i32;
extern fn sd_read_file(path: [*:0]const u8, buf: [*]u8, max: u32) i32;

// LoRa SX1262 (main/lora.c) on the shared SPI2 bus (T-Deck pins).
extern fn lora_init() i32;

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
    _ = spk_init();
    _ = sd_init(); // shared SPI2 bus is up now (tft_init); non-fatal if no card
    _ = lora_init(); // SX1262 on the shared bus (power gate + bus are up)
    // Trackball: direction GPIOs + center-click as input with pullup
    // (each pulses active-LOW as the ball rolls / is clicked).
    _ = main.gpio_pin_init(PIN_TB_UP, main.GPIO_INPUT, main.GPIO_PULL_UP);
    _ = main.gpio_pin_init(PIN_TB_DOWN, main.GPIO_INPUT, main.GPIO_PULL_UP);
    _ = main.gpio_pin_init(PIN_TB_LEFT, main.GPIO_INPUT, main.GPIO_PULL_UP);
    _ = main.gpio_pin_init(PIN_TB_RIGHT, main.GPIO_INPUT, main.GPIO_PULL_UP);
    _ = main.gpio_pin_init(PIN_TB_CLICK, main.GPIO_INPUT, main.GPIO_PULL_UP);

    ui.drawBoot(""); // big "ARGUS"
    spk_tone(660, 90, 45); // startup chime: two rising notes
    spk_tone(990, 130, 45);
    main.delayMs(300);
    ui.drawBoot("Scanning...");
    main.delayMs(400);
    ui.drawPage();
    return false;
}

/// Per-kind base frequency (Hz) — gives each threat type a distinct voice.
/// Flock=2000 (sharp), drone=1200 (mid-high), raven=800 (low rumble),
/// camera=1600 (standard), trackers=600 (low tone).
fn kindTone(kind: display.TrackerType) u16 {
    return switch (kind) {
        .flock_camera => 2000,
        .drone => 1200,
        .raven => 800,
        .camera => 1600,
        .airtag, .tile, .samsung, .findmy => 600,
        else => 880,
    };
}

/// Audio alert by threat score (called from the main loop on a rising tier).
/// CERT = urgent triple, HIGH = double, MED = single beep. Blocking (~0.1-0.4s).
pub fn alert(score: u8) void {
    if (main.audio_muted) return;
    if (score >= scanner.SCORE_CERT) {
        var i: u8 = 0;
        while (i < 3) : (i += 1) {
            spk_tone(1568, 80, 70);
            main.delayMs(50);
        }
    } else if (score >= scanner.SCORE_HIGH) {
        spk_tone(1175, 100, 60);
        main.delayMs(60);
        spk_tone(1175, 100, 60);
    } else if (score >= scanner.SCORE_MED) {
        spk_tone(880, 120, 50);
    }
}

/// Per-detection alert with a kind-specific tone (called on each new entry).
/// Score-to-pattern: CERT=rapid 3-pulse, HIGH=double beep, MED=single beep.
/// <MED is silent — don't alert on background noise.
pub fn alertKind(kind: display.TrackerType, score: u8) void {
    if (main.audio_muted) return;
    if (score < scanner.SCORE_MED) return;
    const freq: i32 = @intCast(kindTone(kind));
    if (score >= scanner.SCORE_CERT) {
        var i: u8 = 0;
        while (i < 3) : (i += 1) {
            spk_tone(freq, 100, 70);
            main.delayMs(50);
        }
    } else if (score >= scanner.SCORE_HIGH) {
        spk_tone(freq, 100, 60);
        main.delayMs(60);
        spk_tone(freq, 100, 60);
    } else {
        spk_tone(freq, 120, 50);
    }
}

/// The T-Deck has a microSD slot — continuous CSV logging is enabled.
pub const has_storage: bool = true;

/// Append a line to microSD (FATFS). Returns 0 on success, negative on error.
pub fn storageAppend(path: [*:0]const u8, line: [*:0]const u8) i32 {
    return sd_append_line(path, line);
}

/// Read bytes from microSD file. Returns bytes read, negative on error.
pub fn storageRead(path: [*:0]const u8, buf: [*]u8, max: u32) i32 {
    return sd_read_file(path, buf, max);
}

/// Keyboard + trackball input → shared UI actions.
/// Normal mode: keys 1-7 jump views, 'd' dumps CSV, 'l' enters label mode.
/// Label mode: keys 1-5 assign tags, trackball moves cursor, 'l' exits.
/// Trackball up/down pages prev/next; center-click toggles stealth.
/// Non-blocking (polled once per main loop).
pub const input = struct {
    var last_key: i32 = 0;
    var prev_up: i32 = 1;
    var prev_down: i32 = 1;
    var prev_left: i32 = 1;
    var prev_right: i32 = 1;
    var prev_click: i32 = 1;
    var reclassify_pending: bool = false;

    pub fn handle() void {
        // Center-click → stealth toggle (works in stealth too, to wake).
        const click = main.gpio_read(PIN_TB_CLICK);
        if (click == 0 and prev_click == 1) {
            main.toggleStealth();
            if (!main.stealth_mode) ui.drawPage();
        }
        prev_click = click;
        if (main.stealth_mode) return;

        const key = kbd_read();

        if (main.label_mode) {
            // --- Label mode ---
            if (key > 0 and key != last_key) {
                if (reclassify_pending) {
                    switch (key) {
                        '1' => { main.applyReclassify(.flock_camera); ui.drawPage(); },
                        '2' => { main.applyReclassify(.drone); ui.drawPage(); },
                        '3' => { main.applyReclassify(.raven); ui.drawPage(); },
                        '4' => { main.applyReclassify(.camera); ui.drawPage(); },
                        '5' => { main.applyReclassify(.wifi_device); ui.drawPage(); },
                        '0' => { main.applyReclassify(.unknown); ui.drawPage(); },
                        else => {},
                    }
                    reclassify_pending = false;
                } else {
                    switch (key) {
                        '1' => { main.applyLabelTag(main.TAG_CONF); ui.drawPage(); },
                        '2' => { main.applyLabelTag(main.TAG_FALSE); ui.drawPage(); },
                        '3' => { main.applyLabelTag(main.TAG_UNKN); ui.drawPage(); },
                        '4' => { main.applyLabelTag(main.TAG_MUNI); ui.drawPage(); },
                        '5' => { main.applyLabelTag(main.TAG_PRIV); ui.drawPage(); },
                        '0' => { main.applyLabelTag(main.TAG_NONE); ui.drawPage(); },
                        'l', 'L' => {
                            main.label_mode = false;
                            ui.drawPage();
                        },
                        'r', 'R' => {
                            reclassify_pending = true;
                        },
                        else => {},
                    }
                }
            }
            last_key = key;

            // Trackball up/down → move selection cursor (bounded).
            const up = main.gpio_read(PIN_TB_UP);
            if (up == 0 and prev_up == 1) {
                if (main.label_cursor > 0) {
                    main.label_cursor -= 1;
                } else {
                    // Wrap to last visible entry
                    const vis = countLabelVisible();
                    main.label_cursor = if (vis > 0) vis - 1 else 0;
                }
                ui.drawPage();
            }
            prev_up = up;

            const down = main.gpio_read(PIN_TB_DOWN);
            if (down == 0 and prev_down == 1) {
                const vis = countLabelVisible();
                if (main.label_cursor + 1 < vis) {
                    main.label_cursor += 1;
                } else {
                    main.label_cursor = 0;
                }
                ui.drawPage();
            }
            prev_down = down;
            return;
        }

        // --- Normal mode ---
        if (key > 0 and key != last_key) {
            // History view (page 7) filter/sort keys
            if (display.current_page == 7) {
                switch (key) {
                    'a', 'A' => { main.history_filter = 0; main.history_scroll = 0; ui.drawPage(); },
                    'f', 'F' => { main.history_filter = 1; main.history_scroll = 0; ui.drawPage(); },
                    'd', 'D' => { main.history_filter = 2; main.history_scroll = 0; ui.drawPage(); },
                    'r', 'R' => { main.history_filter = 3; main.history_scroll = 0; ui.drawPage(); },
                    'c', 'C' => { main.history_filter = 4; main.history_scroll = 0; ui.drawPage(); },
                    't', 'T' => { main.history_filter = 5; main.history_scroll = 0; ui.drawPage(); },
                    's', 'S' => { main.history_sort ^= 1; main.history_scroll = 0; ui.drawPage(); },
                    else => {},
                }
            } else {
                switch (key) {
                    '1'...'7', '8' => {
                        const page: u8 = if (key == '8') 7 else @intCast(key - '1');
                        main.gotoPage(page);
                        ui.drawPage();
                    },
                    'l', 'L' => {
                        // Enter label mode only on Surveillance (1) or Devices (5).
                        if (display.current_page == 1 or display.current_page == 5) {
                            main.label_mode = true;
                            main.label_cursor = 0;
                            main.page_scroll = 0;
                            main.label_view_kind = display.current_page;
                            ui.drawPage();
                        }
                    },
                    else => {},
                }
                // CSV dump key 'd' — only in non-history views (d=drone filter on history)
                if (key == 'd' or key == 'D') main.dumpCsv(false);
                if (key == 's' or key == 'S') {
                    main.gotoPage(8);
                    main.settings_cursor = 0;
                    ui.drawPage();
                }
                if (key == 'm' or key == 'M') {
                    main.audio_muted = !main.audio_muted;
                    ui.drawPage();
                }
            }
        }
        last_key = key;

        // Trackball left/right → previous/next page (resets scroll).
        const left = main.gpio_read(PIN_TB_LEFT);
        if (left == 0 and prev_left == 1) {
            main.prevPage();
            main.page_scroll = 0;
            ui.drawPage();
        }
        prev_left = left;

        const right = main.gpio_read(PIN_TB_RIGHT);
        if (right == 0 and prev_right == 1) {
            main.nextPage();
            main.page_scroll = 0;
            ui.drawPage();
        }
        prev_right = right;

        // Trackball up/down → scroll list views (wraps), cursor on settings/playback.
        const up = main.gpio_read(PIN_TB_UP);
        if (up == 0 and prev_up == 1) {
            if (display.current_page == 7 and main.history_scroll > 0) {
                main.history_scroll -= 1;
            } else if (display.current_page == 8 and main.settings_cursor > 0) {
                main.settings_cursor -= 1;
            } else if (isScrollablePage()) {
                if (main.page_scroll > 0) {
                    main.page_scroll -= 1;
                } else {
                    const vis = countScrollableEntries();
                    main.page_scroll = if (vis > 0) vis -| 1 else 0;
                }
            }
            ui.drawPage();
        }
        prev_up = up;

        const down = main.gpio_read(PIN_TB_DOWN);
        if (down == 0 and prev_down == 1) {
            if (display.current_page == 7) {
                main.history_scroll += 1;
            } else if (display.current_page == 8 and main.settings_cursor < 4) {
                main.settings_cursor += 1;
            } else if (isScrollablePage()) {
                const vis = countScrollableEntries();
                if (vis > 0) {
                    main.page_scroll += 1;
                    if (main.page_scroll >= vis) main.page_scroll = 0;
                }
            }
            ui.drawPage();
        }
        prev_down = down;
    }

    fn isScrollablePage() bool {
        return switch (display.current_page) {
            1, 4, 5 => true, // Surv, Trackers, Devices
            else => false,
        };
    }

    fn countScrollableEntries() u8 {
        var vis: u8 = 0;
        var i: usize = main.tracker_count;
        while (i > 0) {
            i -= 1;
            const v = switch (display.current_page) {
                1 => switch (main.trackers[i].kind) {
                    .flock_camera, .drone, .raven, .camera => true,
                    else => false,
                },
                4 => switch (main.trackers[i].kind) {
                    .airtag, .tile, .samsung, .findmy => true,
                    else => false,
                },
                5 => (main.trackers[i].methods & scanner.METHOD_OUI) != 0,
                else => false,
            };
            if (v) vis += 1;
        }
        return vis;
    }

    /// Count visible (label-able) entries on the current view for cursor wrapping.
    fn countLabelVisible() u8 {
        var vis: u8 = 0;
        var i: usize = main.tracker_count;
        while (i > 0) {
            i -= 1;
            const v = switch (main.label_view_kind) {
                1 => switch (main.trackers[i].kind) {
                    .flock_camera, .drone, .raven, .camera => true,
                    else => false,
                },
                5 => (main.trackers[i].methods & scanner.METHOD_OUI) != 0,
                else => false,
            };
            if (v) vis += 1;
        }
        return vis;
    }
};

/// Setup-mode display bring-up.
pub fn initSetup() void {
    _ = st7789.init();
    ui.drawSetup();
}
