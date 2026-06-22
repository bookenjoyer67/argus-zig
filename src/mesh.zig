const std = @import("std");
const main = @import("main.zig");
const display = @import("display.zig");
const scanner = @import("scanner.zig");

// ================================================================
// LoRa MESH NETWORKING
// ================================================================
//
// Simple broadcast mesh — no routing, no acks. Each node transmits
// detections and listens for peer broadcasts.
//
// Packet format (14 bytes):
//   [class:1B][oui:3B][addr:6B][rssi:1B][score:1B][crc:1B]
//
// Node ID derived from WiFi frame counter mod 255 (unique enough).
// Display: mesh detections appear with "M:" prefix on threats page.

/// Build and send a mesh packet for a tracker entry.
pub fn meshSend(entry: @TypeOf(main.trackers[0])) void {
    var pkt: [14]u8 = undefined;
    pkt[0] = @intFromEnum(entry.kind);          // class
    pkt[1] = entry.mac[0];                       // OUI byte 0
    pkt[2] = entry.mac[1];                       // OUI byte 1
    pkt[3] = entry.mac[2];                       // OUI byte 2
    pkt[4] = entry.mac[0];                       // MAC byte 0
    pkt[5] = entry.mac[1];                       // MAC byte 1
    pkt[6] = entry.mac[2];                       // MAC byte 2
    pkt[7] = entry.mac[3];                       // MAC byte 3
    pkt[8] = entry.mac[4];                       // MAC byte 4
    pkt[9] = entry.mac[5];                       // MAC byte 5
    pkt[10] = @bitCast(entry.rssi);              // RSSI (i8 → u8)
    pkt[11] = entry.score;                       // confidence score
    // Simple XOR checksum over first 12 bytes
    var crc: u8 = 0;
    for (0..12) |i| crc ^= pkt[i];
    pkt[12] = crc;
    pkt[13] = 0; // reserved

    _ = main.lora_send(&pkt, 14);
}

/// Process a received mesh packet into the tracker table.
pub fn meshRecv(pkt: []const u8) void {
    if (pkt.len < 13) return;

    // Verify CRC
    var crc: u8 = 0;
    for (0..12) |i| crc ^= pkt[i];
    if (crc != pkt[12]) return;

    const kind: display.TrackerType = @enumFromInt(pkt[0]);
    const mac: [6]u8 = pkt[4..10].*;
    const rssi: i8 = @bitCast(pkt[10]);
    const score: u8 = pkt[11];

    // Only track if it's a meaningful detection
    if (kind == .unknown) return;

    const result = scanner.ClassResult{ .kind = kind, .methods = 0 };
    const is_new = scanner.trackDevice(mac, result, rssi);

    if (is_new) {
        // Update entry with mesh-provided score
        for (0..main.tracker_count) |i| {
            if (std.mem.eql(u8, &main.trackers[i].mac, &mac)) {
                if (score > main.trackers[i].score) main.trackers[i].score = score;
                break;
            }
        }
    }
}
