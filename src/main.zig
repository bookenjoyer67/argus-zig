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
pub const config = @import("config.zig");
pub const api = @import("api.zig");

/// Single source of truth for the firmware version (shown on the OLED System
/// page and reported by the JSON API). Bump this on each release.
pub const FIRMWARE_VERSION = "1.1.0";

// Force the dashboard API exports (in the non-root api.zig) to be analyzed
// and emitted into libargus.a — Zig only lazily analyzes imported files.
comptime {
    _ = &api.zig_api_status;
    _ = &api.zig_api_detections;
    _ = &api.zig_api_mesh;
    _ = &api.zig_api_config;
}

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

/// LEDC PWM on the white LED (GPIO 35). led_pwm_init() configures an
/// 8-bit channel at 5 kHz; led_pwm_set(duty) takes 0-255 (0=off, 255=full).
/// Used by updateLed() for smooth brightness ramps on the threat-level LED.
pub extern fn led_pwm_init() void;
pub extern fn led_pwm_set(duty: u32) void;

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

// BLE GATT phone stream (Nordic UART Service). Advertising + scanning run
// concurrently; these drive a paired phone's live view (see main/ble.c).
pub extern fn ble_gatt_is_connected() i32;
pub extern fn ble_gatt_is_subscribed() i32;
pub extern fn ble_gatt_send(buf: [*]const u8, len: u32) i32;
pub extern fn ble_gatt_get_request(out: [*]u8, max: i32) i32;
pub extern fn ble_gatt_take_passkey(out: *u32) i32;
pub extern fn ble_gatt_set_enabled(on: i32) i32;

// OTA progress (main/ota.c) — drives the OLED update screen.
pub extern fn ota_is_active() i32;
pub extern fn ota_progress_pct() i32;

// WiFi promiscuous sniffer — callback pushes simplified 802.11 frames
// to a ring buffer. wifi_scan_poll drains one result.
// Returns 1 if data available, 0 if buffer empty.
pub extern fn wifi_scan_poll(addr_out: [*]u8, receiver_out: [*]u8, rssi_out: *i8, channel_out: *u8, frame_type_out: *u8, ssid_out: [*]u8, ssid_len_out: *u8, rid_out: [*]u8, rid_len_out: *u8) i32;

// Diagnostic: total WiFi frames captured (to verify sniffer is running)
pub extern fn wifi_get_frame_count() u32;

// Diagnostic: frames dropped due to ring buffer overflow
pub extern fn wifi_get_dropped_count() u32;

// Retune the promiscuous sniffer to a specific 802.11 channel (mobile role).
pub extern fn wifi_set_channel(ch: u8) i32;

// Role check — non-zero if this unit is configured as a base station.
// Base units lock the radio to the home-WiFi channel and must not hop.
pub extern fn config_role_is_base() i32;

// Battery ADC — GPIO 1 with 390k/100k divider on Heltec V3.
// Returns battery voltage in millivolts (e.g. 4100 = 4.1V).
pub extern fn battery_read_mv() i32;

// SPIFFS persistence — CSV detection log on flash storage
pub extern fn spiffs_append_line(path: [*:0]const u8, line: [*:0]const u8) i32;
pub extern fn spiffs_read_file(path: [*:0]const u8, buf: [*]u8, max_len: u32) i32;
pub extern fn spiffs_write_file(path: [*:0]const u8, data: [*]const u8, len: u32) i32;

// Dump CSV log to serial (called on long press). Entirely in C — see spiffs.c.
pub extern fn spiffs_csv_export() void;

// Delete detections.csv to start fresh.
pub extern fn spiffs_clear_csv() i32;

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

/// Broad device category an OUI belongs to, derived from the ouis.txt section
/// it appears in. Used to give surveillance-specific chips (cameras, drones)
/// a higher OUI-only score cap than general-purpose modules (Liteon, Flock).
pub const OuiCategory = enum(u8) { flock, camera, drone, generic };

/// One OUI record: prefix + vendor name + category. The name is a fixed
/// buffer (not a slice) to avoid the comptime-slice-escape issue that forces
/// KNOWN_OUIS-style fixed arrays — comptime can't return slices into its own
/// temporaries, but a runtime const array of fixed buffers is fine.
pub const OuiEntry = struct {
    oui: [3]u8,
    name: [24]u8,
    name_len: u8,
    category: OuiCategory,
};

const NameBuf = struct { buf: [24]u8, len: u8 };

/// Clean a "# ..." section comment into a short vendor name: truncate at the
/// first " (", "/", or em-dash, then strip trailing descriptor words.
fn cleanVendorName(comment: []const u8) NameBuf {
    var s = comment;
    if (std.mem.indexOf(u8, s, " (")) |p| s = s[0..p];
    if (std.mem.indexOf(u8, s, "/")) |p| s = s[0..p];
    if (std.mem.indexOf(u8, s, " \u{2014}")) |p| s = s[0..p]; // em-dash
    s = std.mem.trim(u8, s, " \t");
    const suffixes = [_][]const u8{ " cameras", " camera", " surveillance", " OUIs" };
    var changed = true;
    while (changed) {
        changed = false;
        for (suffixes) |suf| {
            if (std.ascii.endsWithIgnoreCase(s, suf)) {
                s = std.mem.trim(u8, s[0 .. s.len - suf.len], " \t");
                changed = true;
            }
        }
    }
    var nb = NameBuf{ .buf = [_]u8{0} ** 24, .len = 0 };
    const n = @min(s.len, 24);
    @memcpy(nb.buf[0..n], s[0..n]);
    nb.len = @intCast(n);
    return nb;
}

/// Update the running category from a section comment. Keyword precedence:
/// commodity > flock > drone > camera. Headers without a keyword inherit `prev`.
fn deriveCategory(prev: OuiCategory, comment: []const u8) OuiCategory {
    if (std.ascii.indexOfIgnoreCase(comment, "commodity") != null) return .generic;
    if (std.ascii.indexOfIgnoreCase(comment, "flock") != null) return .flock;
    if (std.ascii.indexOfIgnoreCase(comment, "drone") != null or
        std.ascii.indexOfIgnoreCase(comment, "remote id") != null) return .drone;
    if (std.ascii.indexOfIgnoreCase(comment, "camera") != null or
        std.ascii.indexOfIgnoreCase(comment, "surveillance") != null) return .camera;
    return prev;
}

/// OUI database with vendor name + category — one comptime parse of ouis.txt.
/// Vendor name tracks the nearest preceding comment; category is a running
/// state changed only by category keywords (see ouis.txt header).
pub const OUI_DB: [OUI_MAX]OuiEntry = blk: {
    @setEvalBranchQuota(400000);
    const raw = @embedFile("ouis.txt");
    var list: [OUI_MAX]OuiEntry = undefined;
    for (&list) |*e| {
        e.* = .{ .oui = .{ 0xFF, 0xFF, 0xFF }, .name = [_]u8{0} ** 24, .name_len = 0, .category = .generic };
    }
    var count: usize = 0;
    var cur_name = NameBuf{ .buf = [_]u8{0} ** 24, .len = 0 };
    var cur_cat: OuiCategory = .generic;
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (trimmed[0] == '#') {
            const body = std.mem.trim(u8, trimmed[1..], " \t");
            if (body.len == 0) continue;
            cur_name = cleanVendorName(body);
            cur_cat = deriveCategory(cur_cat, body);
            continue;
        }
        if (trimmed.len != 8 or trimmed[2] != ':') continue;
        if (count >= OUI_MAX) @compileError("Too many OUIs — increase OUI_MAX");
        list[count] = .{
            .oui = .{
                std.fmt.parseInt(u8, trimmed[0..2], 16) catch continue,
                std.fmt.parseInt(u8, trimmed[3..5], 16) catch continue,
                std.fmt.parseInt(u8, trimmed[6..8], 16) catch continue,
            },
            .name = cur_name.buf,
            .name_len = cur_name.len,
            .category = cur_cat,
        };
        count += 1;
    }
    if (count == 0) @compileError("No OUIs parsed from ouis.txt");
    break :blk list;
};

/// Check if a MAC address matches any known surveillance OUI.
pub fn matchOui(mac: [6]u8) bool {
    for (OUI_DB[0..KNOWN_OUIS_COUNT]) |e| {
        if (std.mem.eql(u8, &e.oui, mac[0..3])) return true;
    }
    return false;
}

/// Vendor name for a MAC's OUI, or null if not in the database.
pub fn vendorName(mac: [6]u8) ?[]const u8 {
    for (OUI_DB[0..KNOWN_OUIS_COUNT]) |*e| {
        if (std.mem.eql(u8, &e.oui, mac[0..3])) return e.name[0..e.name_len];
    }
    return null;
}

/// Category for a MAC's OUI. Unknown OUIs are treated as generic.
/// Informational only: as of the OUI-audit fix, the alert decision no longer
/// depends on category (OUI-only hits never alert — corroboration is required).
/// Retained for the OUI_DB and possible future grouping on the Devices page.
pub fn ouiCategory(mac: [6]u8) OuiCategory {
    for (OUI_DB[0..KNOWN_OUIS_COUNT]) |e| {
        if (std.mem.eql(u8, &e.oui, mac[0..3])) return e.category;
    }
    return .generic;
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
    source: u8,              // 0 = direct (this unit), 1 = mesh (peer-relayed)
    mesh_lat: i32 = 0,       // GPS from a mesh detection (source == 1)
    mesh_lon: i32 = 0,       // GPS from a mesh detection (source == 1)
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
    led_pwm_set(255);
}

pub fn ledOff() void {
    led_pwm_set(0);
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
// MODE + THREAT-LEVEL LED STATE MACHINE
// ================================================================
//
// The white LED communicates threat level at a glance via LEDC PWM
// brightness patterns. updateLed() is called every main-loop iteration
// and is fully non-blocking (it derives the pattern from tick_ms phase),
// except for the rare stealth aliveness micro-blink.

/// Stealth mode: OLED off, LED dark (except a 60s aliveness blink).
/// Scanning continues in the background. Toggled by double-press.
pub var stealth_mode: bool = false;

/// Set true if a hardware init step failed (e.g. OLED I2C). Drives the
/// LED error pattern at runtime so a headless device still reports the fault.
pub var init_failed: bool = false;

// ================================================================
// WiFi CHANNEL HOPPING (mobile role)
// ================================================================
//
// The promiscuous sniffer only ever receives frames on the channel the
// radio is tuned to. Without hopping it sits on a single channel and
// misses APs/cameras everywhere else. Mobile units rotate through the
// channel list below, dwelling longer on the common AP channels (1/6/11)
// where Flock cameras and most beacons live, and briefly on the rest.
//
// Base-station units leave the radio locked to the home-WiFi channel
// (the STA connection pins it) and never hop, so the dashboard link
// stays up. hopping_enabled is set once at startup from the role.
//
// Default list is channels 1-11 (US regulatory domain). For EU/JP,
// append 12, 13 here AND set the country via esp_wifi_set_country —
// esp_wifi_set_channel(12/13) fails under the default country.
const HOP_CHANNELS = [_]u8{ 1, 6, 11, 2, 3, 4, 5, 7, 8, 9, 10 };
const DWELL_PRIMARY_MS: u32 = 500; // 1/6/11
const DWELL_SECONDARY_MS: u32 = 200; // all others
var hop_index: usize = 0;
var last_hop_ms: u32 = 0;
var hopping_enabled: bool = false;

// ================================================================
// BLE PHONE STREAM (NUS) — render api.zig JSON, push over GATT notify
// ================================================================
//
// Rendered in the main-loop task (single owner of tracker/mesh state),
// then handed to main/ble.c which chunks it into MTU-sized notifications.
// Each message is one JSON object/array terminated by a newline so the
// phone client can frame the stream.
var ble_json_buf: [8192]u8 = undefined;
var ble_last_push_ms: u32 = 0;

/// Render a JSON body via one of the api.zig functions and stream it to the
/// connected/paired phone. Each message is `<tag><json>\n`: the 1-char tag
/// (S/D/M/C/G) lets the client route the stream unambiguously, including
/// empty arrays. The newline frames the message.
fn bleStream(tag: u8, render: *const fn ([*]u8, u32) callconv(.c) u32) void {
    ble_json_buf[0] = tag;
    const n = render(ble_json_buf[1..].ptr, ble_json_buf.len - 2);
    ble_json_buf[1 + n] = '\n';
    _ = ble_gatt_send(&ble_json_buf, n + 2);
}

/// Only threats seen within this window drive the LED (scores never decay).
const THREAT_RECENCY_MS: u32 = 15000;

/// Peak duty for the gentle "pulse" states (full strobe uses 255).
const LED_PULSE_PEAK: u32 = 200;

/// Timestamp of the last stealth aliveness micro-blink.
var led_alive_last: u32 = 0;

/// Highest confidence score among trackers seen in the last THREAT_RECENCY_MS.
pub fn currentThreatLevel() u8 {
    var best: u8 = 0;
    for (0..tracker_count) |i| {
        if ((tick_ms -% trackers[i].last_seen) > THREAT_RECENCY_MS) continue;
        if (trackers[i].score > best) best = trackers[i].score;
    }
    return best;
}

/// Threat-level label matching the LED state machine: used by the dashboard.
pub fn threatLevelStr() []const u8 {
    const level = currentThreatLevel();
    if (scanner.stingray_alert_active or level >= scanner.SCORE_CERT) return "targeted";
    if (level >= scanner.SCORE_HIGH) return "watched";
    if (level >= scanner.SCORE_MED) return "aware";
    return "clear";
}

/// Triangle-wave duty: ramps 0 → peak → 0 over `period` ms.
fn triangleDuty(phase: u32, period: u32, peak: u32) u32 {
    const half = period / 2;
    if (phase < half) return peak * phase / half;
    return peak * (period - phase) / half;
}

/// Drive the white LED based on mode and threat level. Non-blocking.
///   Error:    3 fast blinks + pause (overrides everything)
///   Stealth:  dark, 5ms aliveness blink every 60s
///   Targeted: 5 Hz full strobe        (score >= 85)
///   Watched:  double-blink / 1s        (score 70-84)
///   Aware:    slow fade pulse / 2s     (score 40-69)
///   Clear:    off
pub fn updateLed() void {
    if (init_failed) {
        const p = tick_ms % 1600;
        const on = (p < 60) or (p >= 160 and p < 220) or (p >= 320 and p < 380);
        led_pwm_set(if (on) 255 else 0);
        return;
    }

    if (stealth_mode) {
        if ((tick_ms -% led_alive_last) >= 60000) {
            led_alive_last = tick_ms;
            led_pwm_set(40);
            delayMs(5);
            led_pwm_set(0);
        } else {
            led_pwm_set(0);
        }
        return;
    }

    if (scanner.stingray_alert_active) {
        // Stingray: 5 Hz strobe. Priority below Error/Stealth, above trackers.
        const p = tick_ms % 200;
        led_pwm_set(if (p < 100) 255 else 0);
        return;
    }

    const level = currentThreatLevel();
    if (level >= scanner.SCORE_CERT) {
        const p = tick_ms % 200;
        led_pwm_set(if (p < 100) 255 else 0);
    } else if (level >= scanner.SCORE_HIGH) {
        const p = tick_ms % 1000;
        const on = (p < 60) or (p >= 180 and p < 240);
        led_pwm_set(if (on) 255 else 0);
    } else if (level >= scanner.SCORE_MED) {
        led_pwm_set(triangleDuty(tick_ms % 2000, 2000, LED_PULSE_PEAK));
    } else {
        led_pwm_set(0);
    }
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

    led_pwm_init();
    _ = gpio_pin_init(PIN_BUTTON, GPIO_INPUT, GPIO_PULL_UP);

    // --- Boot sequence ---
    // The LED is the earliest sign of life (OLED I2C isn't ready yet).
    //   0ms:   solid on (power good)
    //   ~200ms: off, then a quick double-blink (firmware booted)
    ledOn();  delayMs(200);
    ledOff(); delayMs(80);
    ledOn();  delayMs(40); ledOff(); delayMs(80);
    ledOn();  delayMs(40); ledOff(); delayMs(80);

    // --- Display init ---
    // Vext (GPIO 36) controls the switched 3.3V rail via P-channel MOSFET.
    // Active LOW: pull LOW to enable Vext, HIGH to disable.
    // Enable it before resetting/initializing the display.

    _ = gpio_pin_init(PIN_VEXT, GPIO_OUTPUT, GPIO_PULL_NONE);
    _ = gpio_write(PIN_VEXT, 0);   // enable Vext (active LOW)
    delayMs(50);                    // let power rail stabilize

    // Reset the SSD1306 via GPIO 21, then initialize I2C and send
    // the init sequence. If I2C init fails, set init_failed so the
    // runtime LED state machine shows the error pattern, and continue
    // headless — the device still scans without the OLED.

    _ = gpio_pin_init(PIN_OLED_RST, GPIO_OUTPUT, GPIO_PULL_NONE);
    _ = gpio_write(PIN_OLED_RST, 0);   // hold in reset
    delayMs(100);
    _ = gpio_write(PIN_OLED_RST, 1);   // release reset
    delayMs(100);

    if (oled_i2c_init() != 0) {
        // OLED not responding — flag the fault and blink an error code.
        // updateLed() then repeats the error pattern for the whole session.
        init_failed = true;
        ledOn();  delayMs(50); ledOff(); delayMs(50);
        ledOn();  delayMs(50); ledOff(); delayMs(50);
        ledOn();  delayMs(50); ledOff();
    } else {
        display.oledInit();
        display.drawBoot("");          // big "ARGUS" logo
        delayMs(400);
        display.drawBoot("Scanning...");
        delayMs(400);
        display.drawPage();            // flip to summary
    }

    // Restore session counter from SPIFFS
    scanner.restoreSession();

    // Enable WiFi channel hopping on mobile units only. Base units keep the
    // radio on the home-WiFi channel for the dashboard STA link.
    hopping_enabled = (config_role_is_base() == 0);
    if (hopping_enabled) {
        _ = wifi_set_channel(HOP_CHANNELS[0]);
    }

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
    var last_draw_ms: u32 = 0; // throttles live page refresh

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
        // Debounce 50ms, then measure hold time:
        //   >= 1200ms  → long press (CSV export, ignored in stealth)
        //   short      → wait ~350ms for a 2nd press:
        //                  2nd press → double-press toggles stealth mode
        //                  otherwise → single press cycles the page
        // Double-press works from any page/state so stealth is always reachable.

        if (buttonPressed()) {
            delayMs(50);
            if (buttonPressed()) {
                var hold_ms: u32 = 50;
                while (buttonPressed() and hold_ms < 15200) {
                    delayMs(50);
                    hold_ms += 50;
                }

                if (hold_ms >= 1200) {
                    // Long press — CSV dump over serial (suppressed in stealth)
                    if (!stealth_mode) {
                        ledOn();  delayMs(50); ledOff();
                        spiffs_csv_export();
                        // Very long press (>15s) — also clear CSV after dump
                        if (hold_ms >= 15000) {
                            delayMs(200);
                            _ = spiffs_clear_csv();
                        }
                    }
                    while (buttonPressed()) {
                        delayMs(10);
                    }
                } else {
                    // Short press released — watch for a second press
                    var waited: u32 = 0;
                    var double_press = false;
                    while (waited < 350) {
                        if (buttonPressed()) { double_press = true; break; }
                        delayMs(10);
                        waited += 10;
                    }

                    if (double_press) {
                        // Double-press — toggle stealth mode
                        delayMs(40); // debounce second press
                        stealth_mode = !stealth_mode;
                        if (stealth_mode) {
                            display.oledDisplayOff();
                            led_pwm_set(0);
                        } else {
                            display.oledDisplayOn();
                        }
                        // Stealth silences BLE advertising too (and drops any
                        // active phone connection); restored when stealth ends.
                        _ = ble_gatt_set_enabled(if (stealth_mode) @as(i32, 0) else 1);
                        while (buttonPressed()) {
                            delayMs(10);
                        }
                    } else if (!stealth_mode) {
                        // Single press — cycle to next page
                        display.current_page = (display.current_page + 1) % display.NUM_PAGES;
                    }
                }

                if (!stealth_mode) display.drawPage();
            }
        }

        // --- WiFi channel hop ---
        // Mobile role only. Non-blocking: retune when the per-channel dwell
        // elapses; scanning/BLE/display/mesh keep running in between.
        if (hopping_enabled) {
            const ch = HOP_CHANNELS[hop_index];
            const dwell = if (ch == 1 or ch == 6 or ch == 11) DWELL_PRIMARY_MS else DWELL_SECONDARY_MS;
            if ((tick_ms -% last_hop_ms) >= dwell) {
                hop_index = (hop_index + 1) % HOP_CHANNELS.len;
                _ = wifi_set_channel(HOP_CHANNELS[hop_index]);
                last_hop_ms = tick_ms;
            }
        }

        // --- OTA progress ---
        // While a firmware update streams (HTTPS or BLE), show progress on the
        // OLED and skip the normal page refresh.
        if (ota_is_active() != 0) {
            if (!stealth_mode) {
                display.drawOtaProgress(ota_progress_pct());
                last_draw_ms = tick_ms;
            }
        }

        // --- BLE phone stream (NUS) ---
        // Show the pairing passkey on the OLED while pairing; otherwise, once
        // a phone is paired + subscribed, push status ~1.5s and answer
        // on-demand commands (detections/mesh/cameras).
        var passkey: u32 = undefined;
        if (ble_gatt_take_passkey(&passkey) != 0 and !stealth_mode) {
            display.drawPasskey(passkey);
            last_draw_ms = tick_ms;
        } else if (ble_gatt_is_subscribed() != 0) {
            var cmd: [64]u8 = undefined;
            const clen = ble_gatt_get_request(&cmd, cmd.len);
            if (clen > 0) {
                const c = cmd[0..@intCast(clen)];
                if (std.mem.startsWith(u8, c, "detections")) {
                    bleStream('D', &api.zig_api_detections);
                } else if (std.mem.startsWith(u8, c, "mesh")) {
                    bleStream('M', &api.zig_api_mesh);
                } else if (std.mem.startsWith(u8, c, "cameras")) {
                    bleStream('C', &api.zig_api_cameras);
                } else if (std.mem.startsWith(u8, c, "config")) {
                    bleStream('G', &api.zig_api_config);
                } else {
                    bleStream('S', &api.zig_api_status);
                }
            }
            if ((tick_ms -% ble_last_push_ms) >= 1500) {
                bleStream('S', &api.zig_api_status);
                ble_last_push_ms = tick_ms;
            }
        }

        // --- Live page refresh ---
        // Redraw every page at ~2 Hz so counts, RSSI, history bars, and
        // mesh peer lists update without requiring a button press.
        if (!stealth_mode and (tick_ms -% last_draw_ms) >= 500) {
            display.drawPage();
            last_draw_ms = tick_ms;
        }

        // --- Threat-level LED ---
        // Non-blocking PWM pattern reflecting the highest recent threat score,
        // or the stealth / error state. Replaces the old heartbeat blink.
        updateLed();

        // --- Stingray burst detector ---
        // Roll the carrier-probe bucket window and check for / clear alerts.
        scanner.burstTick(tick_ms);
        scanner.burstClearCheck(tick_ms);

        // --- LoRa mesh heartbeat ---
        // Refresh diagnostics and broadcast presence every 30s so peers/base
        // know we're alive without waiting for a detection event.
        mesh.mesh_battery_mv = @intCast(@max(0, @min(65535, battery_read_mv())));
        mesh.mesh_uptime_sec = tick_ms / 1000;
        if ((tick_ms -% mesh.last_heartbeat_ms) >= mesh.HEARTBEAT_INTERVAL_MS) {
            mesh.last_heartbeat_ms = tick_ms;
            mesh.sendHeartbeat();
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

// ================================================================
// SETUP-MODE ENTRY POINT (first boot / onboarding)
// ================================================================
//
/// Called from C app_main() when the device is unconfigured. The C side
/// has already started the "Argus Setup" AP and the setup HTTP server.
/// This brings up the OLED and shows connection instructions, looping
/// until POST /api/setup saves the config and reboots the device.
export fn zig_main_setup() callconv(.c) void {
    led_pwm_init();

    // Bring up the OLED (same sequence as the normal boot path).
    _ = gpio_pin_init(PIN_VEXT, GPIO_OUTPUT, GPIO_PULL_NONE);
    _ = gpio_write(PIN_VEXT, 0); // enable Vext (active LOW)
    delayMs(50);
    _ = gpio_pin_init(PIN_OLED_RST, GPIO_OUTPUT, GPIO_PULL_NONE);
    _ = gpio_write(PIN_OLED_RST, 0);
    delayMs(100);
    _ = gpio_write(PIN_OLED_RST, 1);
    delayMs(100);

    if (oled_i2c_init() == 0) {
        display.oledInit();
        display.drawSetup();
    }

    // Loop forever — a gentle pulse signals "waiting for setup".
    while (true) {
        led_pwm_set(triangleDuty(tick_ms % 2000, 2000, LED_PULSE_PEAK));
        delayMs(50);
    }
}
