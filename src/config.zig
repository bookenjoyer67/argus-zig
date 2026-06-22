//! === ARGUS — Configuration accessors (Zig side) ===
//!
//! The source of truth for device configuration lives in C (main/config.c),
//! so that app_main() can read WiFi credentials and role before the Zig
//! runtime starts. This module exposes thin Zig wrappers used by the OLED
//! setup screen and the /api/config JSON renderer.

const std = @import("std");

// Implemented in main/config.c
pub extern fn config_get(key: [*:0]const u8, out: [*]u8, out_len: i32) i32;
pub extern fn config_is_configured() i32;
pub extern fn config_role_is_base() i32;
pub extern fn config_set_all(name: [*:0]const u8, role: [*:0]const u8, ssid: [*:0]const u8, pass: [*:0]const u8) i32;

/// Read a config value into `buf`, returning the populated slice.
/// Returns an empty slice if the key is absent.
pub fn get(key: [*:0]const u8, buf: []u8) []const u8 {
    const n = config_get(key, buf.ptr, @intCast(buf.len));
    if (n <= 0) return buf[0..0];
    return buf[0..@intCast(n)];
}

pub fn isConfigured() bool {
    return config_is_configured() != 0;
}

pub fn roleIsBase() bool {
    return config_role_is_base() != 0;
}
