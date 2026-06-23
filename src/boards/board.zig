//! === Board abstraction traits ===
//!
//! Common hardware contracts every board satisfies. The detection engine
//! (scanner.zig, mesh.zig, api.zig) is board-agnostic; only the display,
//! input, audio, and storage backends differ between boards.
//!
//! Boards (src/boards/<board>.zig) expose concrete driver modules and may
//! also provide runtime instances of these structs for polymorphic use.
//! On a comptime-known board the firmware calls the driver modules directly
//! (zero indirection); these structs document the contract and enable a
//! runtime vtable if ever needed.

/// A monochrome or color framebuffer the gfx layer draws into.
pub const Display = struct {
    width: u16,
    height: u16,
    clear: *const fn () void,
    update: *const fn () void,
    setPixel: *const fn (x: u16, y: u16, on: bool) void,
};

/// One decoded user-input event. Boards map their physical controls
/// (button, keyboard, trackball) onto this union.
pub const InputEvent = union(enum) {
    none,
    key: u8, // keyboard key (ASCII)
    button_press,
    button_hold: u32, // ms held
    trackball_up,
    trackball_down,
    trackball_left,
    trackball_right,
    trackball_click,
};

/// Audio / alert backend. On boards with no speaker (Heltec) this maps to
/// the LED; on boards with I2S (T-Deck) it plays PCM tones.
pub const Audio = struct {
    playTone: *const fn (freq_hz: u16, dur_ms: u16) void,
    stop: *const fn () void,
};

/// Persistent line-oriented storage for the CSV detection log.
/// Heltec backs this with SPIFFS; T-Deck with FAT on microSD.
pub const Storage = struct {
    append: *const fn (path: [*:0]const u8, line: [*:0]const u8) i32,
    read: *const fn (path: [*:0]const u8, buf: [*]u8, max: u32) i32,
    exportCsv: *const fn () void,
};
