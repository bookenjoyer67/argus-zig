//! === ARGUS — Surveillance Tracker Scanner ===
//!
//! Target:  Heltec WiFi LoRa 32 V3 (ESP32-S3FN8, 8MB flash, no PSRAM)
//! Toolchain: zig-espressif-bootstrap 0.16.0-xtensa + ESP-IDF v5.4
//! License: AGPLv3
//!
//! ## Architecture
//!
//! This file compiles to a static library (libargus.a) that is linked into an
//! ESP-IDF project. The C entry point (main/main.c) calls zig_main() after
//! initializing NVS flash. All application logic lives here in Zig.
//!
//! ## Why Zig on this hardware
//!
//! - No heap fragmentation: FixedBufferAllocator for tracker table, comptime for OUI db
//! - No C headers needed: extern fn declarations, linker resolves against ESP-IDF
//! - Compile-time OUI parsing: @embedFile + comptime = zero runtime cost
//! - Binary size: ~228 KB (vs ~530 KB C++ Arduino equivalent)
//!   - No Arduino framework overhead
//!   - Pure-Zig SSD1306 driver instead of U8g2 (500KB → 2KB)
//!   - @embedFile eliminates runtime file I/O for OUIs
//!
//! ## Zig 0.16 Notes
//!
//! - callconv(.c) not callconv(.C) — lowercase in 0.16
//! - @as(u3, @truncate(x)) required for shift amounts
//! - asm volatile ("") not asm volatile ("" ::: "memory")
//! - std.fmt.bufPrint replaces bufPrintIntToSlice
//! - build.zig: b.createModule + b.addLibrary (not addStaticLibrary)
//! - b.graph.environ_map.get() for env vars in build.zig
//! - ReleaseSafe for GNU ld compatibility (ReleaseSmall inlines+strips symbols)
//!
//! ## Pin Map (Heltec WiFi LoRa 32 V3 — top view, USB-C down)
//!
//!   GPIO 35 (J2-10):  Onboard white LED, active HIGH
//!   GPIO 3  (J3-14):  (free — was piezo buzzer)
//!   GPIO 0  (J2-8):   PRG button, active LOW, internal pullup
//!   GPIO 17 (internal): OLED SDA (I2C)
//!   GPIO 18 (internal): OLED SCL (I2C)
//!   GPIO 21 (J2-16):  OLED RST
//!   GPIO 1  (J3-12):  Battery ADC (resistor divider, VBAT = ADC * 490/100 * 3.3/4095)
//!   GPIO 36 (J2-9):   Vext control (LOW = external 3.3V on, P-channel MOSFET)
//!
//! Free for future: GPIO 2,4,5,6,7 (J3), GPIO 47,48 (J2)
//! Reserved/do not use: GPIO 33,34,37,38 (SPI flash), GPIO 26 (SubSPI CS),
//!   GPIO 45,46 (strapping), GPIO 8-14 (LoRa SX1262, not on headers),
//!   GPIO 43,44 (UART0 to CP2102)

const std = @import("std");
pub const display = @import("display.zig");
pub const scanner = @import("scanner.zig");
pub const mesh = @import("mesh.zig");

// Re-export for modules that need them
pub const TrackerType = display.TrackerType;

// ================================================================
// ESP-IDF C FUNCTION DECLARATIONS
// ================================================================
//
// These are resolved by the GNU linker at final link time.
// No @cImport needed — avoids the entire C header translation
// problem (which breaks on ESP-IDF v5.4's deeply nested include tree).
//
// The extern signatures must match the ESP-IDF ABI exactly.
// Return types are c_int (i32 on Xtensa), parameters are u32 for GPIO nums.

/// Configure a single GPIO pin: direction, pull resistor, interrupt (disabled).
/// mode: 0=INPUT, 1=OUTPUT.  pull: 0=NONE, 1=UP, 2=DOWN.
/// Wraps ESP-IDF gpio_config() — a real ABI symbol, unlike gpio_set_pull_mode
/// which is inlined in v5.4 headers and resolves to garbage at link time.
pub extern fn gpio_pin_init(pin: u32, mode: u32, pull: u32) i32;

/// Set GPIO output level: 0 = LOW, 1 = HIGH
pub extern fn gpio_write(pin: u32, level: u32) i32;

/// Read GPIO input level. Returns 0 (LOW) or 1 (HIGH).
pub extern fn gpio_read(pin: u32) i32;

/// FreeRTOS delay: blocks calling task for (ticks * portTICK_PERIOD_MS) milliseconds
pub extern fn vTaskDelay(ticks: u32) void;

// GPIO mode/pull constants for gpio_pin_init()
pub const GPIO_INPUT: u32  = 0;
pub const GPIO_OUTPUT: u32 = 1;
pub const GPIO_PULL_NONE: u32 = 0;
pub const GPIO_PULL_UP: u32   = 1;
pub const GPIO_PULL_DOWN: u32 = 2;

// FreeRTOS tick period: 10ms on ESP-IDF default config
pub const portTICK_PERIOD_MS: u32 = 10;

// OLED I2C helpers — thin C wrappers in main/main.c
// oled_i2c_init configures I2C port 0 on GPIO 17/18 at 400kHz.
// oled_i2c_write prepends a control byte (0x00=cmd, 0x40=data) and transmits.
// Both return 0 on success, negative on error.
pub extern fn oled_i2c_init() i32;
pub extern fn oled_i2c_write(control_byte: u8, data: [*]const u8, len: u32) i32;

// BLE scanner — NimBLE runs in its own FreeRTOS task, pushing results
// to a lock-free ring buffer. ble_scan_poll drains one result.
// Returns 1 if data available, 0 if buffer empty.
pub extern fn ble_scan_poll(addr_out: [*]u8, rssi_out: *i8, adv_type_out: *u8, data_out: [*]u8, data_len_out: *u8) i32;

// WiFi promiscuous sniffer — callback pushes simplified 802.11 frames
// to a ring buffer. wifi_scan_poll drains one result.
// Returns 1 if data available, 0 if buffer empty.
pub extern fn wifi_scan_poll(addr_out: [*]u8, receiver_out: [*]u8, rssi_out: *i8, channel_out: *u8, frame_type_out: *u8, ssid_out: [*]u8, ssid_len_out: *u8, rid_out: [*]u8, rid_len_out: *u8) i32;

// Diagnostic: total WiFi frames captured (to verify sniffer is running)
pub extern fn wifi_get_frame_count() u32;

// Diagnostic: frames dropped due to ring buffer overflow
pub extern fn wifi_get_dropped_count() u32;

// Battery ADC — GPIO 1 with 390k/100k divider on Heltec V3.
// Returns battery voltage in millivolts (e.g. 4100 = 4.1V).
pub extern fn battery_read_mv() i32;

// SPIFFS persistence — CSV detection log on flash storage
pub extern fn spiffs_append_line(path: [*:0]const u8, line: [*:0]const u8) i32;
pub extern fn spiffs_read_file(path: [*:0]const u8, buf: [*]u8, max_len: u32) i32;
pub extern fn spiffs_write_file(path: [*:0]const u8, data: [*]const u8, len: u32) i32;

// Dump CSV log to serial (called on long press). Entirely in C — see spiffs.c.
pub extern fn spiffs_csv_export() void;

// LoRa SX1262 — mesh networking on 915 MHz
// lora_send: TX a packet (max 255 bytes), blocks until done.
// lora_poll_receive: check for received packet, returns length (0 if none).
pub extern fn lora_send(data: [*]const u8, len: u8) i32;
pub extern fn lora_poll_receive(buf: [*]u8) i32;

// GPS NEO-6M — UART1 on GPIO 4/5 at 9600 baud
pub extern fn gps_read(buf: [*]u8, max_len: i32) i32;

// ================================================================
// HELTEC V3 PIN DEFINITIONS
// ================================================================
// Board: Heltec WiFi LoRa 32 V3 (HTIT-WB32LA)
// Chip:  ESP32-S3FN8 (Xtensa LX7 dual-core, 240 MHz, 8MB flash, 512KB SRAM)
//
// The Heltec V3 has two 18-pin headers:
//   J2 (right side, viewed from top with USB-C at bottom)
//   J3 (left side)
//
// Onboard peripherals:
//   White LED on GPIO 35, active HIGH
//   SSD1306 OLED 128x64 on I2C (GPIO 17=SDA, 18=SCL, 21=RST) — internal, not on headers
//   SX1262 LoRa on SPI (GPIO 8-14) — not on headers
//   CP2102 USB-UART on GPIO 43(TX)/44(RX)
//   PRG button on GPIO 0, active LOW
//   RST button connected to EN pin
//   Vext: switched 3.3V for external sensors, controlled by GPIO 36 (active LOW)
//   Battery ADC on GPIO 1 (390k/100k divider)

pub const PIN_LED: u32    = 35;  // Onboard white LED (J2 pin 10), active HIGH
pub const PIN_BUTTON: u32 = 0;   // PRG button (J2 pin 8), active LOW, needs pullup

// OLED I2C bus — these are PCB traces, not exposed on headers
// The SSD1306 is addressed at 0x3C (SA0 pin tied to GND on this board)
const PIN_OLED_SDA: u32 = 17;
const PIN_OLED_SCL: u32 = 18;
pub const PIN_OLED_RST: u32 = 21;
pub const PIN_VEXT: u32 = 36;  // Vext control: active LOW (P-channel MOSFET)

// ================================================================
// COMPILE-TIME OUI DATABASE
// ================================================================
//
// Reads ouis.txt at compile time via @embedFile, parses colon-separated
// hex bytes, and bakes the result into a static array in the binary.
//
// Why comptime:
//   - No filesystem access on device (SPIFFS not required for OUIs)
//   - No runtime string parsing overhead
//   - No malloc for the OUI table
//   - Adding an OUI is editing a text file, not recompiling C arrays by hand
//
// Format of ouis.txt:
//   XX:XX:XX  — one MAC OUI per line
//   # comments skip this line
//   Blank lines ignored
//
// The inline for in matchOui() unrolls to a decision tree at compile time.
// On 31 entries this is a linear scan. Past ~50, switch to a perfect hash
// or sorted binary search generated at comptime.

/// OUI database — parsed at compile time from ouis.txt via @embedFile.
///
/// We store a fixed [64][3]u8 array and a separate count.
/// Unused slots are filled with 0xFF bytes — 0xFF never matches
/// a real OUI (FF:FF:FF is the broadcast address, filtered elsewhere).
///
/// This avoids the comptime-reference-escape problem in Zig 0.16:
/// comptime blocks can't return slices pointing to comptime memory.
const OUI_MAX = 96;
pub const KNOWN_OUIS_COUNT: usize = blk: {
    @setEvalBranchQuota(20000);
    const raw = @embedFile("ouis.txt");
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        if (trimmed.len == 8 and trimmed[2] == ':') count += 1;
    }
    break :blk count;
};

pub const KNOWN_OUIS: [OUI_MAX][3]u8 = blk: {
    @setEvalBranchQuota(20000);
    const raw = @embedFile("ouis.txt");
    var list: [OUI_MAX][3]u8 = [_][3]u8{[_]u8{0xFF} ** 3} ** OUI_MAX; // fill with sentinel
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        if (trimmed.len != 8 or trimmed[2] != ':') continue;
        if (count >= OUI_MAX) @compileError("Too many OUIs — increase OUI_MAX");

        list[count] = .{
            std.fmt.parseInt(u8, trimmed[0..2], 16) catch continue,
            std.fmt.parseInt(u8, trimmed[3..5], 16) catch continue,
            std.fmt.parseInt(u8, trimmed[6..8], 16) catch continue,
        };
        count += 1;
    }
    if (count == 0) @compileError("No OUIs parsed from ouis.txt");
    break :blk list;
};

/// Check if a MAC address matches any known surveillance OUI.
/// Iterates over the database. At 31 entries, the compiler
/// will likely unroll this into a decision tree.
pub fn matchOui(mac: [6]u8) bool {
    for (KNOWN_OUIS[0..KNOWN_OUIS_COUNT]) |oui| {
        if (std.mem.eql(u8, &oui, mac[0..3])) return true;
    }
    return false;
}

// ================================================================
// TRACKER TABLE
// ================================================================
//
// Fixed-capacity ring buffer. No heap allocation — the entire table
// lives in a static array. On a 512KB device with no MMU, this means:
//   - No fragmentation over weeks of uptime
//   - No out-of-memory error in the BLE callback (ISR context)
//   - Size known at compile time: MAX_TRACKERS * sizeof(TrackerEntry)
//
// When full, the oldest entry is evicted. For a pocket scanner,
// 64 entries is far more than you'll ever see simultaneously.

pub const MAX_TRACKERS = 64;

pub const TrackerEntry = struct {
    mac: [6]u8,
    kind: display.TrackerType,
    rssi: i8,
    last_seen: u32,
    score: u8,              // 0-100 confidence score
    methods: u16,            // bitmask of detection methods
    rssi_history: [5]i8,     // recent RSSI values (ring buffer)
    rssi_hidx: u3,           // write index into rssi_history
};

pub var trackers: [MAX_TRACKERS]TrackerEntry = undefined;
pub var tracker_count: usize = 0;
pub var tick_ms: u32 = 0;

// ================================================================
// GPIO HELPERS
// ================================================================
//
// Tiny wrappers around ESP-IDF GPIO functions.
// These are deliberately small — the compiler inlines them.

pub fn ledOn() void {
    _ = gpio_write(PIN_LED, 1);
}

pub fn ledOff() void {
    _ = gpio_write(PIN_LED, 0);
}

/// Read the PRG button. Returns true when pressed.
/// Active LOW — GPIO reads 0 when button is held down.
/// Internal pullup is enabled in zig_main().
pub fn buttonPressed() bool {
    return gpio_read(PIN_BUTTON) == 0;
}

/// Block for at least `ms` milliseconds using FreeRTOS vTaskDelay.
/// Also increments our monotonic tick counter.
/// Note: vTaskDelay resolution is portTICK_PERIOD_MS (10ms).
pub fn delayMs(ms: u32) void {
    vTaskDelay(ms / portTICK_PERIOD_MS);
    tick_ms +%= ms;
}

// ================================================================
// MAIN ENTRY POINT
// ================================================================
//
/// Called from C app_main() in main/main.c after NVS init.
/// This function never returns — it runs the main loop forever.
///
/// The FreeRTOS scheduler is already running when this is called,
/// so vTaskDelay is available. No other FreeRTOS tasks are created
/// yet (BLE scanner will add one later).
///
/// Memory: all globals use static allocation. No heap usage.
///   trackers:    MAX_TRACKERS * 10 bytes = 640 bytes
///   oled_buf:    1024 bytes
///   FONT_5X7:    ~300 bytes (59 chars * 5)
///   KNOWN_OUIS:  31 * 3 = 93 bytes
///   stack:       ~4KB default FreeRTOS task stack
///   Total:       ~6KB RAM of 512KB available

export fn zig_main() callconv(.c) void {
    // --- GPIO initialization ---
    // Configure all pins before the main loop. gpio_pin_init() wraps
    // ESP-IDF gpio_config() — a real ABI symbol that configures direction,
    // pull resistors, and interrupt state in a single call.

    _ = gpio_pin_init(PIN_LED, GPIO_OUTPUT, GPIO_PULL_NONE);
    _ = gpio_pin_init(PIN_BUTTON, GPIO_INPUT, GPIO_PULL_UP);

    // --- Boot animation ---
    // Two quick LED blinks to confirm the board is alive.
    // This runs before the OLED is initialized (I2C not ready yet),
    // so the LED is the earliest sign of life.

    ledOn();  delayMs(150);
    ledOff(); delayMs(100);
    ledOn();  delayMs(150);
    ledOff();

    // Quick LED blink — visual boot confirmation
    ledOn();  delayMs(50); ledOff();

    // --- Display init ---
    // Vext (GPIO 36) controls the switched 3.3V rail via P-channel MOSFET.
    // Active LOW: pull LOW to enable Vext, HIGH to disable.
    // The OLED may be powered from Vext on some Heltec V3 revisions.
    // Enable it before resetting/initializing the display.

    _ = gpio_pin_init(PIN_VEXT, GPIO_OUTPUT, GPIO_PULL_NONE);
    _ = gpio_write(PIN_VEXT, 0);   // enable Vext (active LOW)
    delayMs(50);                    // let power rail stabilize

    // Reset the SSD1306 via GPIO 21, then initialize I2C and send
    // the init sequence. If I2C init fails, blink LED 3x fast and
    // continue headless — the device works without the OLED.
    //
    // Timing: RST low for 10ms ensures a clean reset regardless of
    // power-on state. 10ms post-reset lets the SSD1306 stabilize
    // before we start sending commands.

    _ = gpio_pin_init(PIN_OLED_RST, GPIO_OUTPUT, GPIO_PULL_NONE);
    _ = gpio_write(PIN_OLED_RST, 0);   // hold in reset
    delayMs(100);
    _ = gpio_write(PIN_OLED_RST, 1);   // release reset
    delayMs(100);

    if (oled_i2c_init() != 0) {
        // OLED not responding — blink LED 3x fast, continue headless
        ledOn();  delayMs(50); ledOff(); delayMs(50);
        ledOn();  delayMs(50); ledOff(); delayMs(50);
        ledOn();  delayMs(50); ledOff();
    } else {
        display.oledInit();
        display.oledClear();
        display.drawPage();
    }

    // Restore session counter from SPIFFS
    scanner.restoreSession();

    // ================================================================
    // MAIN LOOP
    // ================================================================
    //
    // Single-threaded cooperative loop. NimBLE and WiFi sniffing run
    // in their own tasks and push results into ring buffers. This loop:
    //   1. Drains the BLE ring buffer, classifies devices, updates table
    //   2. Drains the WiFi ring buffer, OUI/SSID match, updates table
    //   3. Checks button (with debounce)
    //   4. Heartbeat LED every 3 seconds
    //   5. Sleeps 10ms

    var had_new: bool = false; // true if a new tracker was detected this iteration

    while (true) {
        had_new = false;

        // --- BLE scan polling ---
        // Drain all available results from the NimBLE ring buffer.
        // Classify each device and update the tracker table.
        // Flag new detections for alert + display refresh.

        var ble_addr: [6]u8 = undefined;
        var ble_rssi: i8 = undefined;
        var ble_adv_type: u8 = undefined;
        var ble_data: [31]u8 = undefined;
        var ble_data_len: u8 = undefined;

        var poll_count: u32 = 0;
        while (ble_scan_poll(&ble_addr, &ble_rssi, &ble_adv_type, &ble_data, &ble_data_len) != 0) {
            poll_count += 1;
            const result = scanner.classifyBle(ble_data[0..ble_data_len]);
            const is_new = scanner.trackDevice(ble_addr, result, ble_rssi);

            if (is_new) {
                had_new = true;
                scanner.session_total += 1;
                scanner.saveSession();
                scanner.logCsv(ble_addr, ble_rssi);
            }

            // Yield every 8 events to avoid watchdog timeout
            if (poll_count % 8 == 0) {
                delayMs(5);
            }
        }

        if (had_new) {
            var best: u8 = 0;
            for (0..tracker_count) |i| {
                if (trackers[i].score > best) best = trackers[i].score;
            }
            display.alertLed(best);
            // Broadcast highest-scoring detection over LoRa mesh
            if (best >= scanner.SCORE_MED) {
                for (0..tracker_count) |i| {
                    if (trackers[i].score == best) {
                        mesh.meshSend(trackers[i]);
                        break;
                    }
                }
            }
        }

        // --- WiFi scan polling ---
        // Drain all available results from the WiFi promiscuous ring buffer.
        // Match transmitter MAC against known Flock Safety OUIs and check
        // probe request SSIDs for "Flock" pattern.

        var wifi_addr: [6]u8 = undefined;
        var wifi_receiver: [6]u8 = undefined;
        var wifi_rssi: i8 = undefined;
        var wifi_channel: u8 = undefined;
        var wifi_frame_type: u8 = undefined;
        var wifi_ssid: [32]u8 = undefined;
        var wifi_ssid_len: u8 = undefined;
        var wifi_rid: [128]u8 = undefined;
        var wifi_rid_len: u8 = undefined;

        poll_count = 0;
        while (wifi_scan_poll(&wifi_addr, &wifi_receiver, &wifi_rssi, &wifi_channel, &wifi_frame_type, &wifi_ssid, &wifi_ssid_len, &wifi_rid, &wifi_rid_len) != 0) {
            poll_count += 1;

            // Skip unknown MACs — only track OUI matches or "Flock" SSIDs.
            // This avoids flooding the tracker table with every passing phone.
            var result = scanner.classifyWiFi(wifi_addr, wifi_ssid[0..wifi_ssid_len]);
            if (wifi_rid_len > 0) {
                const rid_methods = scanner.parseDroneRemoteId(wifi_rid[0..wifi_rid_len]);
                if (rid_methods != 0) {
                    result.kind = .drone;
                    result.methods |= rid_methods;
                }
            }
            if (result.kind == .unknown) {
                // Yield periodically even when skipping
                if (poll_count % 16 == 0) {
                    delayMs(5);
                }
                continue;
            }

            const is_new = scanner.trackDevice(wifi_addr, result, wifi_rssi);

            if (is_new) {
                had_new = true;
                scanner.session_total += 1;
                scanner.saveSession();
                scanner.logCsv(wifi_addr, wifi_rssi);
            }

            // Yield every 4 events to avoid watchdog timeout
            if (poll_count % 4 == 0) {
                delayMs(5);
            }
        }

        if (had_new) {
            var best: u8 = 0;
            for (0..tracker_count) |i| {
                if (trackers[i].score > best) best = trackers[i].score;
            }
            display.alertLed(best);
            if (best >= scanner.SCORE_MED) {
                for (0..tracker_count) |i| {
                    if (trackers[i].score == best) {
                        mesh.meshSend(trackers[i]);
                        break;
                    }
                }
            }
        }

        // --- Button handling ---
        // Debounce: wait 50ms after first press, re-read.
        // If still pressed, it's a real press (not noise).
        // Block until released to avoid re-triggering.

        if (buttonPressed()) {
            delayMs(50);
            if (buttonPressed()) {
                // Check for long press (>1 second hold)
                var hold_ms: u32 = 50;
                while (buttonPressed() and hold_ms < 1200) {
                    delayMs(50);
                    hold_ms += 50;
                }

                if (hold_ms >= 1200) {
                    // Long press — LED blinks, then CSV dump over serial
                    ledOn();  delayMs(50); ledOff();
                    spiffs_csv_export();
                    // Wait for release
                    while (buttonPressed()) {
                        delayMs(10);
                    }
                } else {
                    // Short press: cycle to next page
                    display.current_page = (display.current_page + 1) % display.NUM_PAGES;
                    delayMs(40); // brief delay for tactile feel
                    while (buttonPressed()) {
                        delayMs(10);
                    }
                }

                display.drawPage();
            }
        }

        // --- Heartbeat LED ---
        // Brief flash every 3 seconds to show the device is alive.
        // 10ms on, then off. Uses ~0.003% duty cycle, negligible power.

        if (tick_ms % 1500 == 0) {
            ledOn();
            delayMs(10);
            ledOff();
        }

        // --- LoRa mesh polling ---
        // Check for received mesh packets, process into tracker table.
        var lora_buf: [255]u8 = undefined;
        const lora_len = lora_poll_receive(&lora_buf);
        if (lora_len > 0) {
            mesh.meshRecv(lora_buf[0..@intCast(lora_len)]);
        }

        // --- GPS NMEA accumulator ---
        // Read available bytes from GPS UART, accumulate lines,
        // parse complete NMEA sentences on newline.
        var gps_buf: [64]u8 = undefined;
        const gps_n = gps_read(&gps_buf, 64);
        if (gps_n > 0) {
            const gps_data = gps_buf[0..@intCast(gps_n)];
            for (gps_data, 0..) |c, ci| {
                if (c == '\n' and scanner.gps_line_pos > 0) {
                    scanner.parseNmea(scanner.gps_line[0..scanner.gps_line_pos]);
                    scanner.gps_line_pos = 0;
                } else if (scanner.gps_line_pos < scanner.gps_line.len and c != '\r') {
                    scanner.gps_line[scanner.gps_line_pos] = c;
                    scanner.gps_line_pos += 1;
                }
                // Yield periodically during burst reads
                if (ci % 32 == 31) delayMs(5);
            }
        }

        // --- Yield to FreeRTOS ---
        // 10ms sleep lets other tasks run (idle task, WiFi task if enabled).
        // This is the minimum sleep — vTaskDelay(1) = one tick = 10ms.

        delayMs(10);
    }
}
