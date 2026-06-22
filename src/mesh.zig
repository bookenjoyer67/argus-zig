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
// Packet format (15 bytes):
//   [0]     class (TrackerType)
//   [1..7]  MAC (6 bytes)
//   [7]     RSSI (i8)
//   [8]     score
//   [9]     sender_id (this unit's node ID — low byte of base MAC)
//   [10..14] reserved (zero)
//   [14]    CRC (XOR of bytes 0..13)
//
// The sender_id lets the base station build a peer list (UNIT-NN) with
// last-seen, LoRa RSSI, and a shared-detection counter for /api/mesh.

/// LoRa RSSI (dBm) of the most recently received packet. Implemented in lora.c
/// via the SX1262 GetPacketStatus opcode.
pub extern fn lora_last_rssi() i32;

/// This unit's node ID — derived from the eFuse base MAC. Implemented in main.c.
pub extern fn mesh_node_id() u8;

const PKT_LEN: u8 = 15;

/// Build and send a mesh packet for a tracker entry.
pub fn meshSend(entry: @TypeOf(main.trackers[0])) void {
    var pkt: [PKT_LEN]u8 = [_]u8{0} ** PKT_LEN;
    pkt[0] = @intFromEnum(entry.kind);
    pkt[1] = entry.mac[0];
    pkt[2] = entry.mac[1];
    pkt[3] = entry.mac[2];
    pkt[4] = entry.mac[3];
    pkt[5] = entry.mac[4];
    pkt[6] = entry.mac[5];
    pkt[7] = @bitCast(entry.rssi);
    pkt[8] = entry.score;
    pkt[9] = mesh_node_id();
    // bytes 10..14 reserved (zero)
    var crc: u8 = 0;
    for (0..14) |i| crc ^= pkt[i];
    pkt[14] = crc;

    _ = main.lora_send(&pkt, PKT_LEN);
}

// ================================================================
// PEER TABLE
// ================================================================

pub const MAX_PEERS = 16;

/// A neighbouring Argus unit heard over LoRa.
pub const MeshPeer = struct {
    id: u8 = 0,
    last_seen: u32 = 0,
    rssi: i8 = 0,
    shared: u32 = 0,
    active: bool = false,
};

pub var peers: [MAX_PEERS]MeshPeer = [_]MeshPeer{.{}} ** MAX_PEERS;
pub var peer_count: usize = 0;

/// A peer counts as "online" if heard within this window.
pub const PEER_ONLINE_MS: u32 = 300000; // 5 minutes

/// Record a packet from a peer: upsert by node ID, refresh last-seen/RSSI,
/// and bump its shared-detection counter.
fn peerSeen(id: u8) void {
    const rssi: i8 = @truncate(@as(i32, @max(-128, @min(127, lora_last_rssi()))));
    for (0..peer_count) |i| {
        if (peers[i].id == id) {
            peers[i].last_seen = main.tick_ms;
            peers[i].rssi = rssi;
            peers[i].shared += 1;
            peers[i].active = true;
            return;
        }
    }
    if (peer_count < MAX_PEERS) {
        peers[peer_count] = .{
            .id = id,
            .last_seen = main.tick_ms,
            .rssi = rssi,
            .shared = 1,
            .active = true,
        };
        peer_count += 1;
    }
}

/// Number of peers heard within PEER_ONLINE_MS.
pub fn onlinePeerCount() u32 {
    var n: u32 = 0;
    for (0..peer_count) |i| {
        if ((main.tick_ms -% peers[i].last_seen) <= PEER_ONLINE_MS) n += 1;
    }
    return n;
}

/// Process a received mesh packet into the peer + tracker tables.
pub fn meshRecv(pkt: []const u8) void {
    if (pkt.len < PKT_LEN) return;

    var crc: u8 = 0;
    for (0..14) |i| crc ^= pkt[i];
    if (crc != pkt[14]) return;

    const kind: display.TrackerType = @enumFromInt(pkt[0]);
    const mac: [6]u8 = pkt[1..7].*;
    const rssi: i8 = @bitCast(pkt[7]);
    const score: u8 = pkt[8];
    const sender_id: u8 = pkt[9];

    peerSeen(sender_id);

    if (kind == .unknown) return;

    const result = scanner.ClassResult{ .kind = kind, .methods = 0 };
    const is_new = scanner.trackDevice(mac, result, rssi);

    // Tag the entry as mesh-sourced and adopt the peer's score if higher.
    for (0..main.tracker_count) |i| {
        if (std.mem.eql(u8, &main.trackers[i].mac, &mac)) {
            main.trackers[i].source = 1;
            if (is_new and score > main.trackers[i].score) main.trackers[i].score = score;
            break;
        }
    }
}
