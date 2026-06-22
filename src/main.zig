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
//!   GPIO 3  (J3-14):  Piezo buzzer
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
extern fn gpio_pin_init(pin: u32, mode: u32, pull: u32) i32;

/// Set GPIO output level: 0 = LOW, 1 = HIGH
extern fn gpio_write(pin: u32, level: u32) i32;

/// Read GPIO input level. Returns 0 (LOW) or 1 (HIGH).
extern fn gpio_read(pin: u32) i32;

/// FreeRTOS delay: blocks calling task for (ticks * portTICK_PERIOD_MS) milliseconds
extern fn vTaskDelay(ticks: u32) void;

// GPIO mode/pull constants for gpio_pin_init()
const GPIO_INPUT: u32  = 0;
const GPIO_OUTPUT: u32 = 1;
const GPIO_PULL_NONE: u32 = 0;
const GPIO_PULL_UP: u32   = 1;
const GPIO_PULL_DOWN: u32 = 2;

// FreeRTOS tick period: 10ms on ESP-IDF default config
const portTICK_PERIOD_MS: u32 = 10;

// OLED I2C helpers — thin C wrappers in main/main.c
// oled_i2c_init configures I2C port 0 on GPIO 17/18 at 400kHz.
// oled_i2c_write prepends a control byte (0x00=cmd, 0x40=data) and transmits.
// Both return 0 on success, negative on error.
extern fn oled_i2c_init() i32;
extern fn oled_i2c_write(control_byte: u8, data: [*]const u8, len: u32) i32;

// BLE scanner — NimBLE runs in its own FreeRTOS task, pushing results
// to a lock-free ring buffer. ble_scan_poll drains one result.
// Returns 1 if data available, 0 if buffer empty.
extern fn ble_scan_poll(addr_out: [*]u8, rssi_out: *i8, adv_type_out: *u8, data_out: [*]u8, data_len_out: *u8) i32;

// WiFi promiscuous sniffer — callback pushes simplified 802.11 frames
// to a ring buffer. wifi_scan_poll drains one result.
// Returns 1 if data available, 0 if buffer empty.
extern fn wifi_scan_poll(addr_out: [*]u8, receiver_out: [*]u8, rssi_out: *i8, channel_out: *u8, frame_type_out: *u8, ssid_out: [*]u8, ssid_len_out: *u8) i32;

// Diagnostic: total WiFi frames captured (to verify sniffer is running)
extern fn wifi_get_frame_count() u32;

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

const PIN_LED: u32    = 35;  // Onboard white LED (J2 pin 10), active HIGH
const PIN_BUZZER: u32 = 3;   // Piezo buzzer (J3 pin 14)
const PIN_BUTTON: u32 = 0;   // PRG button (J2 pin 8), active LOW, needs pullup

// OLED I2C bus — these are PCB traces, not exposed on headers
// The SSD1306 is addressed at 0x3C (SA0 pin tied to GND on this board)
const PIN_OLED_SDA: u32 = 17;
const PIN_OLED_SCL: u32 = 18;
const PIN_OLED_RST: u32 = 21;
const PIN_VEXT: u32 = 36;  // Vext control: active LOW (P-channel MOSFET)

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
const OUI_MAX = 64;
const KNOWN_OUIS_COUNT: usize = blk: {
    @setEvalBranchQuota(10000);
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

const KNOWN_OUIS: [OUI_MAX][3]u8 = blk: {
    @setEvalBranchQuota(10000);
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
fn matchOui(mac: [6]u8) bool {
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

const MAX_TRACKERS = 64;

/// Known tracker types. Stored as u8 in the table.
const TrackerType = enum(u8) {
    airtag,        // Apple AirTag (Find My protocol, 0x4C00 type 0x12)
    tile,          // Tile (service UUID 0xFEED)
    samsung,       // Samsung SmartTag (manufacturer ID 0x0075)
    findmy,        // Generic Apple Find My device (couldn't narrow)
    flock_camera,  // Flock Safety ALPR camera (OUI match + SSID pattern)
    wifi_device,   // WiFi device with known surveillance OUI
    unknown,       // Detected but unclassified
    _,
};

const TrackerEntry = struct {
    mac: [6]u8,
    kind: TrackerType,
    rssi: i8,         // dBm, -128 to 0
    last_seen: u32,   // tick_ms when last observed
};

var trackers: [MAX_TRACKERS]TrackerEntry = undefined;
var tracker_count: usize = 0;
var tick_ms: u32 = 0; // monotonic millisecond counter, wraps after ~49 days

// ================================================================
// BLE ADVERTISEMENT PARSER
// ================================================================
//
// BLE advertisement data uses TLV format:
//   [length:1][type:1][value: length-1]...
//
// Key AD types:
//   0xFF = Manufacturer Specific Data (2-byte company ID LE + payload)
//   0x02,0x03 = 16-bit Service UUIDs (incomplete/complete list)
//   0x06,0x07 = 128-bit Service UUIDs
//
// Tracker identification:
//   Apple Find My:  AD 0xFF, company 0x004C, payload byte 0 == 0x12
//   Tile:           AD 0x03 or 0x02, UUID 0xFEED
//   Samsung:        AD 0xFF, company 0x0075

/// Parse BLE advertisement data and classify the tracker type.
fn classifyBle(adv_data: []const u8) TrackerType {
    var pos: usize = 0;
    while (pos + 1 < adv_data.len) {
        const len = adv_data[pos];
        if (len == 0) break;
        if (pos + 1 + len > adv_data.len) break;
        const ad_type = adv_data[pos + 1];
        const payload = adv_data[pos + 2 .. pos + 1 + len];

        if (ad_type == 0xFF and payload.len >= 3) {
            // Manufacturer Specific Data
            const company: u16 = @as(u16, payload[0]) | (@as(u16, payload[1]) << 8);
            if (company == 0x004C and payload.len >= 3 and payload[2] == 0x12) {
                return .airtag;
            }
            if (company == 0x0075) {
                return .samsung;
            }
        }

        if ((ad_type == 0x02 or ad_type == 0x03) and payload.len >= 2) {
            // 16-bit Service UUID (incomplete or complete list)
            var uuid_pos: usize = 0;
            while (uuid_pos + 1 < payload.len) : (uuid_pos += 2) {
                const uuid: u16 = @as(u16, payload[uuid_pos]) | (@as(u16, payload[uuid_pos + 1]) << 8);
                if (uuid == 0xFEED) return .tile;
            }
        }

        pos += 1 + len;
    }
    return .unknown;
}

/// Classify a WiFi detection based on OUI match and SSID pattern.
/// Flock Safety cameras probe for networks named "Flock-XXXX" and
/// have MAC OUIs matching the known surveillance database.
fn classifyWiFi(mac: [6]u8, ssid: []const u8) TrackerType {
    const oui_match = matchOui(mac);

    const ssid_flock = blk: {
        if (ssid.len < 5) break :blk false;
        const prefix = [5]u8{ 'F', 'L', 'O', 'C', 'K' };
        break :blk std.mem.eql(u8, ssid[0..5], &prefix);
    };

    if (oui_match and ssid_flock) return .flock_camera;
    if (oui_match) return .wifi_device;
    return .unknown;
}

/// Add or update a tracker entry for the given MAC address.
/// If the MAC is already in the table, update RSSI and last_seen.
/// Otherwise, add a new entry (evict oldest if full).
fn trackBle(mac: [6]u8, kind: TrackerType, rssi: i8) void {
    // Check if already tracked
    for (0..tracker_count) |i| {
        if (std.mem.eql(u8, &trackers[i].mac, &mac)) {
            trackers[i].rssi = rssi;
            trackers[i].last_seen = tick_ms;
            if (kind != .unknown) trackers[i].kind = kind;
            return;
        }
    }

    // New tracker — add to table
    if (tracker_count < MAX_TRACKERS) {
        trackers[tracker_count] = .{
            .mac = mac,
            .kind = kind,
            .rssi = rssi,
            .last_seen = tick_ms,
        };
        tracker_count += 1;
    } else {
        // Evict oldest entry
        var oldest_idx: usize = 0;
        var oldest_time: u32 = trackers[0].last_seen;
        for (1..MAX_TRACKERS) |i| {
            if (trackers[i].last_seen < oldest_time) {
                oldest_time = trackers[i].last_seen;
                oldest_idx = i;
            }
        }
        trackers[oldest_idx] = .{
            .mac = mac,
            .kind = kind,
            .rssi = rssi,
            .last_seen = tick_ms,
        };
    }
}

// ================================================================
// GPIO HELPERS
// ================================================================
//
// Tiny wrappers around ESP-IDF GPIO functions.
// These are deliberately small — the compiler inlines them.

fn ledOn() void {
    _ = gpio_write(PIN_LED, 1);
}

fn ledOff() void {
    _ = gpio_write(PIN_LED, 0);
}

fn buzzerOn() void {
    _ = gpio_write(PIN_BUZZER, 1);
}

fn buzzerOff() void {
    _ = gpio_write(PIN_BUZZER, 0);
}

/// Read the PRG button. Returns true when pressed.
/// Active LOW — GPIO reads 0 when button is held down.
/// Internal pullup is enabled in zig_main().
fn buttonPressed() bool {
    return gpio_read(PIN_BUTTON) == 0;
}

/// Block for at least `ms` milliseconds using FreeRTOS vTaskDelay.
/// Also increments our monotonic tick counter.
/// Note: vTaskDelay resolution is portTICK_PERIOD_MS (10ms).
/// Delays < 10ms use busy-wait instead (see buzzerTone/busyWaitUs).
fn delayMs(ms: u32) void {
    vTaskDelay(ms / portTICK_PERIOD_MS);
    tick_ms +%= ms;
}

// ================================================================
// BUZZER TONE GENERATION
// ================================================================
//
// The piezo buzzer is driven by toggling GPIO 3 at the desired frequency.
// This is a blocking implementation — it busy-waits for the duration.
//
// Trade-off: blocking is fine for 50-200ms alert chirps. For longer tones
// (>500ms), switch to ESP-IDF's LEDC PWM peripheral (to be added).
//
// The busy-wait is calibrated for 240 MHz ESP32-S3:
//   cycles = microseconds * 240
// Each iteration of the empty asm loop is roughly 1 clock cycle,
// but pipeline effects and memory latency make this approximate (±20%).
// For buzzer tones this is precise enough — humans can't hear ±20% at 55ms.

/// Generate a square wave on PIN_BUZZER at freq_hz for dur_ms.
/// Blocks until complete. For short alert chirps (50-200ms).
fn buzzerTone(freq_hz: u32, dur_ms: u32) void {
    if (freq_hz == 0) return;
    const half_period_us = 1000000 / freq_hz / 2; // microseconds per half-cycle
    const cycles = freq_hz * dur_ms / 1000;        // total full cycles
    var i: u32 = 0;
    while (i < cycles) : (i += 1) {
        _ = gpio_write(PIN_BUZZER, 1);
        busyWaitUs(half_period_us);
        _ = gpio_write(PIN_BUZZER, 0);
        busyWaitUs(half_period_us);
    }
}

/// Rough busy-wait for `us` microseconds on 240MHz ESP32-S3.
/// The asm volatile ("") prevents the compiler from optimizing the loop away.
/// Accuracy is ~±20% — good enough for buzzer tones, not for timing-critical I/O.
fn busyWaitUs(us: u32) void {
    const cycles = us * 240; // 240 cycles per microsecond at 240 MHz
    var i: u32 = 0;
    while (i < cycles) : (i += 1) {
        asm volatile ("");
    }
}

// ================================================================
// SSD1306 OLED DISPLAY DRIVER (128x64, I2C, monochrome)
// ================================================================
//
// Pure Zig implementation — no U8g2, no C library.
// Saves ~500KB of flash compared to U8g2.
//
// Architecture:
//   oled_buf[page][column] — 8 pages of 128 bytes = 1024 bytes
//   Each byte represents 8 vertical pixels (bit 0 = top pixel of page)
//   SSD1306 page addressing mode: send page address, then 128 data bytes
//
// I2C communication is NOT YET IMPLEMENTED. The oledUpdate() function
// is a placeholder. To complete:
//   1. Add extern fn for ESP-IDF I2C driver (i2c_master_init, i2c_master_write)
//   2. Send SSD1306 init sequence (30+ bytes of commands)
//   3. In oledUpdate(), send oled_buf over I2C in 8 pages
//
// Font: 5x7 pixel monospace, ASCII 0x20-0x5A (space through Z).
// Each glyph is 5 bytes, each byte is a column (top-to-bottom).
// Characters are 6px wide (5px glyph + 1px spacing).

const OLED_ADDR: u8   = 0x3C;    // SSD1306 I2C address (SA0=GND)
const OLED_WIDTH: u8  = 128;
const OLED_HEIGHT: u8 = 64;

// Compute buffer size at compile time. The cast to usize prevents u8 overflow
// (128 * 64 = 8192 which exceeds u8::MAX, but 8192/8 = 1024 fits in u16).
const OLED_BUF_SIZE: usize = (@as(usize, OLED_WIDTH) * OLED_HEIGHT) / 8;
var oled_buf: [OLED_BUF_SIZE]u8 = [_]u8{0} ** OLED_BUF_SIZE;

/// 5x7 bitmap font: ASCII 32 (space) through 90 (Z).
/// Each entry is 5 bytes, each byte is one column from top to bottom.
/// Bit 0 = top pixel, bit 6 = bottom pixel (bit 7 unused for 7-row font).
/// Extracted from classic 5x7 font commonly used in embedded displays.
const FONT_5X7 = [_]u8{
    0x00,0x00,0x00,0x00,0x00, // 32: space
    0x00,0x5F,0x00,0x00,0x00, // 33: !
    0x00,0x00,0x00,0x00,0x00, // 34: " (placeholder)
    0x14,0x7F,0x14,0x7F,0x14, // 35: #
    0x24,0x2A,0x7F,0x2A,0x12, // 36: $
    0x23,0x13,0x08,0x64,0x62, // 37: %
    0x36,0x49,0x55,0x22,0x50, // 38: &
    0x00,0x05,0x03,0x00,0x00, // 39: '
    0x1C,0x22,0x41,0x00,0x00, // 40: (
    0x41,0x22,0x1C,0x00,0x00, // 41: )
    0x08,0x2A,0x1C,0x2A,0x08, // 42: *
    0x08,0x08,0x3E,0x08,0x08, // 43: +
    0x50,0x30,0x00,0x00,0x00, // 44: ,
    0x08,0x08,0x08,0x08,0x08, // 45: -
    0x60,0x60,0x00,0x00,0x00, // 46: .
    0x20,0x10,0x08,0x04,0x02, // 47: /
    0x3E,0x51,0x49,0x45,0x3E, // 48: 0
    0x00,0x42,0x7F,0x40,0x00, // 49: 1
    0x42,0x61,0x51,0x49,0x46, // 50: 2
    0x21,0x41,0x45,0x4B,0x31, // 51: 3
    0x18,0x14,0x12,0x7F,0x10, // 52: 4
    0x27,0x45,0x45,0x45,0x39, // 53: 5
    0x3C,0x4A,0x49,0x49,0x30, // 54: 6
    0x01,0x71,0x09,0x05,0x03, // 55: 7
    0x36,0x49,0x49,0x49,0x36, // 56: 8
    0x06,0x49,0x49,0x29,0x1E, // 57: 9
    0x00,0x6C,0x6C,0x00,0x00, // 58: :
    0x00,0x56,0x36,0x00,0x00, // 59: ;
    0x00,0x08,0x14,0x22,0x41, // 60: <
    0x14,0x14,0x14,0x14,0x14, // 61: =
    0x41,0x22,0x14,0x08,0x00, // 62: >
    0x02,0x01,0x51,0x09,0x06, // 63: ?
    0x32,0x49,0x79,0x41,0x3E, // 64: @
    0x7E,0x09,0x09,0x09,0x7E, // 65: A
    0x7F,0x49,0x49,0x49,0x36, // 66: B
    0x3E,0x41,0x41,0x41,0x22, // 67: C
    0x7F,0x41,0x41,0x22,0x1C, // 68: D
    0x7F,0x49,0x49,0x49,0x41, // 69: E
    0x7F,0x09,0x09,0x01,0x01, // 70: F
    0x3E,0x41,0x49,0x49,0x7A, // 71: G
    0x7F,0x08,0x08,0x08,0x7F, // 72: H
    0x41,0x7F,0x41,0x00,0x00, // 73: I
    0x30,0x40,0x40,0x3F,0x00, // 74: J
    0x7F,0x08,0x14,0x22,0x41, // 75: K
    0x7F,0x40,0x40,0x40,0x40, // 76: L
    0x7F,0x02,0x04,0x02,0x7F, // 77: M
    0x7F,0x04,0x08,0x10,0x7F, // 78: N
    0x3E,0x41,0x41,0x41,0x3E, // 79: O
    0x7F,0x09,0x09,0x09,0x06, // 80: P
    0x3E,0x41,0x51,0x21,0x5E, // 81: Q
    0x7F,0x09,0x19,0x29,0x46, // 82: R
    0x26,0x49,0x49,0x49,0x32, // 83: S
    0x01,0x01,0x7F,0x01,0x01, // 84: T
    0x3F,0x40,0x40,0x40,0x3F, // 85: U
    0x1F,0x20,0x40,0x20,0x1F, // 86: V
    0x7F,0x20,0x18,0x20,0x7F, // 87: W
    0x63,0x14,0x08,0x14,0x63, // 88: X
    0x03,0x04,0x78,0x04,0x03, // 89: Y
    0x61,0x51,0x49,0x45,0x43, // 90: Z
};

/// Look up the 5-column bitmap for an ASCII character.
/// Lowercase is folded to uppercase.
/// Characters outside ASCII 32-90 render as space.
fn fontChar(c: u8) [5]u8 {
    if (c >= 'a' and c <= 'z') return fontChar(c - 32);
    const idx: usize = if (c >= ' ' and c <= 'Z') @intCast(c - ' ') else 0;
    const base = idx * 5;
    return FONT_5X7[base..][0..5].*;
}

/// Set a single pixel in the display buffer.
/// Coordinates are clipped to display bounds.
/// The buffer uses SSD1306 page format:
///   page = y / 8, bit = y % 8
fn oledSetPixel(x: u8, y: u8, on: bool) void {
    if (x >= OLED_WIDTH or y >= OLED_HEIGHT) return;
    const page = y / 8;
    const bit: u8 = @intCast(y % 8);
    const idx: usize = @as(usize, page) * OLED_WIDTH + @as(usize, x);
    if (on) {
        oled_buf[idx] |= (@as(u8, 1) << @as(u3, @truncate(bit)));
    } else {
        oled_buf[idx] &= ~(@as(u8, 1) << @as(u3, @truncate(bit)));
    }
}

/// Clear the entire display buffer to black.
fn oledClear() void {
    @memset(&oled_buf, 0);
}

/// Draw a single 5x7 character at pixel position (x, y).
/// Characters are 6px wide (5px glyph + 1px space).
fn oledDrawChar(x: u8, y: u8, c: u8) void {
    const glyph = fontChar(c);
    var col: u8 = 0;
    while (col < 5) : (col += 1) {
        var row: u8 = 0;
        while (row < 7) : (row += 1) {
            oledSetPixel(x + col, y + row, (glyph[col] & (@as(u8, 1) << @as(u3, @truncate(row)))) != 0);
        }
    }
}

/// Draw a null-terminated or sliced string at (x, y).
/// Wraps at display edge. No newline handling — single line only.
fn oledDrawStr(x: u8, y: u8, s: []const u8) void {
    var cx = x;
    for (s) |c| {
        if (cx + 5 > OLED_WIDTH) break;
        oledDrawChar(cx, y, c);
        cx += 6; // 5px glyph + 1px spacing
    }
}

/// Format an integer and draw it at (x, y).
/// Uses std.fmt.bufPrint — may fail if the number doesn't fit in the buffer.
/// On failure, draws nothing (silent).
fn oledDrawInt(x: u8, y: u8, n: i32) void {
    var buf: [12]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{n}) catch return;
    oledDrawStr(x, y, s);
}

/// Draw a horizontal progress bar with border.
/// (x, y): top-left corner
/// w, h: width and height in pixels
/// pct: fill percentage (0-100)
/// Minimum size: 3x3 pixels (1px border + 1px fill)
fn oledDrawBar(x: u8, y: u8, w: u8, h: u8, pct: u8) void {
    var row: u8 = 0;
    while (row < h) : (row += 1) {
        if (row == 0 or row == h - 1) {
            // Top and bottom borders — full-width horizontal line
            var col: u8 = 0;
            while (col < w) : (col += 1) {
                oledSetPixel(x + col, y + row, true);
            }
        } else {
            // Side borders
            oledSetPixel(x, y + row, true);
            oledSetPixel(x + w - 1, y + row, true);
            // Fill proportional to pct (inner width = w - 2)
            const fill_w: u8 = @intCast((@as(u16, w) - 2) * pct / 100);
            var col: u8 = 1;
            while (col <= fill_w) : (col += 1) {
                oledSetPixel(x + col, y + row, true);
            }
        }
    }
}

/// Send SSD1306 initialization sequence.
/// Must be called after oled_i2c_init() succeeds, Vext is enabled,
/// and OLED RST is released.
/// The sequence configures clock, mux ratio, charge pump,
/// orientation, contrast, and turns the display on.
fn oledInit() void {
    const init_seq = [_]u8{
        0xAE,           // Display OFF (sleep mode)
        0xD5, 0x80,     // Set display clock divide ratio/oscillator frequency
        0xA8, 0x3F,     // Set multiplex ratio to 63 (64 rows)
        0xD3, 0x00,     // Set display offset = 0
        0x40,           // Set display start line to 0
        0x8D, 0x14,     // Enable charge pump regulator
        0x20, 0x00,     // Set memory addressing mode to horizontal
        0xA1,           // Set segment re-map (column 127 = SEG0)
        0xC8,           // Set COM output scan direction (remapped)
        0xDA, 0x12,     // Set COM pins hardware configuration
        0x81, 0xCF,     // Set contrast control
        0xD9, 0xF1,     // Set pre-charge period
        0xDB, 0x40,     // Set VCOMH deselect level
        0xA4,           // Entire display ON (resume to RAM content)
        0xA6,           // Set normal display (not inverted)
        0xAF,           // Display ON
    };
    _ = oled_i2c_write(0x00, &init_seq, init_seq.len);
}

/// Transmit the display buffer to the SSD1306 over I2C.
/// Sends 8 pages of 128 bytes each. Each page is preceded by
/// three command bytes: set page address (0xB0+page),
/// set low column (0x00), set high column (0x10).
fn oledUpdate() void {
    var page: u8 = 0;
    while (page < 8) : (page += 1) {
        const cmds = [_]u8{ 0xB0 + page, 0x00, 0x10 };
        _ = oled_i2c_write(0x00, &cmds, cmds.len);

        const page_start: usize = @as(usize, page) * @as(usize, OLED_WIDTH);
        _ = oled_i2c_write(0x40, oled_buf[page_start..][0..OLED_WIDTH].ptr, OLED_WIDTH);
    }
}

// ================================================================
// DISPLAY PAGES
// ================================================================
//
// Multiple pages cycled by short-pressing the PRG button.
// Pages are drawn on-demand (not continuously) to save CPU.
// When the I2C driver is connected, pages will render to the physical OLED.

var current_page: u8 = 0;

/// Page 0: Threat summary
/// Shows tracker count, OUI database size, and build info.
/// Future: per-category breakdown (AirTag, Tile, etc.)
fn drawSummary() void {
    // Count ALPR and BLE trackers
    var alpr_count: u32 = 0;
    var ble_count: u32 = 0;
    for (0..tracker_count) |i| {
        switch (trackers[i].kind) {
            .flock_camera, .wifi_device => alpr_count += 1,
            else => ble_count += 1,
        }
    }

    oledClear();
    oledDrawStr(0, 0, "ARGUS TRACKER");
    oledDrawStr(0, 10, "ALPR:");
    oledDrawInt(48, 10, @intCast(alpr_count));
    oledDrawStr(0, 20, "BLE:");
    oledDrawInt(48, 20, @intCast(ble_count));
    oledDrawStr(0, 35, "BTN: page  LED: alert");
    oledDrawStr(0, 50, "OUI:");
    oledDrawInt(48, 50, @intCast(KNOWN_OUIS_COUNT));
    oledUpdate();
}

/// Route to the current page. Called on button press and at boot.
fn drawPage() void {
    switch (current_page) {
        0 => drawSummary(),
        else => drawSummary(), // additional pages added here
    }
}

// ================================================================
// ALERT SYSTEM
// ================================================================
//
// Alert patterns follow the same scheme as Flock-You:
//   NEW DETECTION: two ascending chirps (2000 Hz → 2800 Hz, 55ms each)
//   HIGH CONFIDENCE: three fast beeps (to be added)
//   CERTAIN: five rapid beeps (to be added)
//   THREAT GONE: descending tone (to be added)
//
// The buzzer blocks during tones. For short chirps (<200ms total)
// this is acceptable. For longer patterns, use a non-blocking
// state machine that advances on each loop() iteration.

/// Two ascending chirps — identical to Flock-You's alert signature.
/// Total duration: ~110ms.
fn alertNew() void {
    buzzerTone(2000, 55); // low chirp
    buzzerTone(2800, 55); // high chirp
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
    _ = gpio_pin_init(PIN_BUZZER, GPIO_OUTPUT, GPIO_PULL_NONE);
    _ = gpio_pin_init(PIN_BUTTON, GPIO_INPUT, GPIO_PULL_UP);

    // --- Boot animation ---
    // Two quick LED blinks to confirm the board is alive.
    // This runs before the OLED is initialized (I2C not ready yet),
    // so the LED is the earliest sign of life.

    ledOn();  delayMs(150);
    ledOff(); delayMs(100);
    ledOn();  delayMs(150);
    ledOff();

    // --- Startup chirp ---
    // Single 1500 Hz tone for 80ms — audible confirmation of boot.
    // Distinct from the alert chirps (2000/2800 Hz) so you can tell
    // boot from detection by sound alone.

    buzzerTone(1500, 80);

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
        oledInit();
        oledClear();
        drawPage();
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
            const kind = classifyBle(ble_data[0..ble_data_len]);
            // Check if this MAC is already tracked
            const is_new = blk: {
                for (0..tracker_count) |i| {
                    if (std.mem.eql(u8, &trackers[i].mac, &ble_addr)) break :blk false;
                }
                break :blk true;
            };

            trackBle(ble_addr, kind, ble_rssi);

            if (is_new) {
                had_new = true;
            }

            // Yield every 8 events to avoid watchdog timeout
            if (poll_count % 8 == 0) {
                delayMs(5);
            }
        }

        if (had_new) {
            alertNew();
            drawPage();
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

        poll_count = 0;
        while (wifi_scan_poll(&wifi_addr, &wifi_receiver, &wifi_rssi, &wifi_channel, &wifi_frame_type, &wifi_ssid, &wifi_ssid_len) != 0) {
            poll_count += 1;

            // Skip unknown MACs — only track OUI matches or "Flock" SSIDs.
            // This avoids flooding the tracker table with every passing phone.
            const kind = classifyWiFi(wifi_addr, wifi_ssid[0..wifi_ssid_len]);
            if (kind == .unknown) {
                // Yield periodically even when skipping
                if (poll_count % 16 == 0) {
                    delayMs(5);
                }
                continue;
            }

            const is_new = blk: {
                for (0..tracker_count) |i| {
                    if (std.mem.eql(u8, &trackers[i].mac, &wifi_addr)) break :blk false;
                }
                break :blk true;
            };

            trackBle(wifi_addr, kind, wifi_rssi);

            if (is_new) {
                had_new = true;
            }

            // Yield every 4 events to avoid watchdog timeout
            if (poll_count % 4 == 0) {
                delayMs(5);
            }
        }

        if (had_new) {
            alertNew();
            drawPage();
        }

        // --- Button handling ---
        // Debounce: wait 50ms after first press, re-read.
        // If still pressed, it's a real press (not noise).
        // Block until released to avoid re-triggering.

        if (buttonPressed()) {
            delayMs(50);
            if (buttonPressed()) {
                // Short press: cycle to next page and chirp
                current_page = (current_page + 1) % 1; // % 1 = always 0 (placeholder for multi-page)
                alertNew();

                // Wait for release to avoid re-triggering
                while (buttonPressed()) {
                    delayMs(10);
                }

                drawPage();
            }
        }

        // --- Heartbeat LED ---
        // Brief flash every 3 seconds to show the device is alive.
        // 10ms on, then off. Uses ~0.003% duty cycle, negligible power.

        if (tick_ms % 3000 == 0) {
            ledOn();
            delayMs(10);
            ledOff();
        }

        // --- Yield to FreeRTOS ---
        // 10ms sleep lets other tasks run (idle task, WiFi task if enabled).
        // This is the minimum sleep — vTaskDelay(1) = one tick = 10ms.

        delayMs(10);
    }
}
