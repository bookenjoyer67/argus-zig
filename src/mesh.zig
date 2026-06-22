const std = @import("std");
const main = @import("main.zig");
const display = @import("display.zig");
const scanner = @import("scanner.zig");

// ================================================================
// LoRa MESH NETWORKING — Packet format v2
// ================================================================
//
// Broadcast mesh — no routing tables, no acks. Each node transmits
// heartbeats + detections and listens for peer broadcasts.
//
// Header byte [0]:  type:u4 (low nibble) | hop_count:u4 (high nibble)
// Trailing byte:    CRC-8 (Dallas/Maxim, poly 0x31 reflected = 0x8C)
//                   over all preceding bytes.
//
// Type 0x01 — Heartbeat (17 bytes):
//   [0]      type | hop
//   [1]      sender_id
//   [2..4]   battery_mv (u16 LE)
//   [4..8]   lat (i32 LE, microdegrees)
//   [8..12]  lon (i32 LE)
//   [12..16] uptime_seconds (u32 LE)
//   [16]     CRC-8
//
// Type 0x02 — Detection (24 bytes):
//   [0]      type | hop
//   [1]      sender_id
//   [2]      class (TrackerType)
//   [3..9]   MAC (6 bytes)
//   [9]      RSSI (i8)
//   [10]     score
//   [11..15] lat (i32 LE, detecting unit's position)
//   [15..19] lon (i32 LE)
//   [19..23] detection_time_ms (u32 LE)
//   [23]     CRC-8

/// LoRa RSSI (dBm) of the most recently received packet. Implemented in lora.c
/// via the SX1262 GetPacketStatus opcode.
pub extern fn lora_last_rssi() i32;

/// This unit's node ID — derived from the eFuse base MAC. Implemented in main.c.
pub extern fn mesh_node_id() u8;

const PKT_MAX = 32;

const TYPE_HEARTBEAT = 0x01;
const TYPE_DETECTION = 0x02;

// ================================================================
// CRC-8 (Dallas/Maxim, reflected poly 0x8C)
// ================================================================
//
// Catches all single-bit, double-bit and odd-bit errors plus bursts up
// to 8 bits — far stronger than the old XOR checksum.
fn crc8(data: []const u8) u8 {
    var crc: u8 = 0;
    for (data) |b| {
        crc ^= b;
        var i: u8 = 0;
        while (i < 8) : (i += 1) {
            if (crc & 1 != 0) {
                crc = (crc >> 1) ^ 0x8C;
            } else {
                crc >>= 1;
            }
        }
    }
    return crc;
}

// ================================================================
// HEARTBEAT STATE
// ================================================================

pub const HEARTBEAT_INTERVAL_MS: u32 = 30000; // 30 seconds
pub var last_heartbeat_ms: u32 = 0;

/// Updated from the main loop before each heartbeat.
pub var mesh_battery_mv: u16 = 0;
pub var mesh_uptime_sec: u32 = 0;

// ================================================================
// PACKET BUILDERS
// ================================================================

fn makeHeartbeat(pkt: *[PKT_MAX]u8, bat_mv: u16, lat: i32, lon: i32, uptime: u32) u8 {
    pkt[0] = TYPE_HEARTBEAT; // hop 0 (high nibble zero)
    pkt[1] = mesh_node_id();
    std.mem.writeInt(u16, pkt[2..4], bat_mv, .little);
    std.mem.writeInt(i32, pkt[4..8], lat, .little);
    std.mem.writeInt(i32, pkt[8..12], lon, .little);
    std.mem.writeInt(u32, pkt[12..16], uptime, .little);
    const len: u8 = 16;
    pkt[len] = crc8(pkt[0..len]);
    return len + 1;
}

fn makeDetection(pkt: *[PKT_MAX]u8, entry: main.TrackerEntry) u8 {
    pkt[0] = TYPE_DETECTION; // hop 0
    pkt[1] = mesh_node_id();
    pkt[2] = @intFromEnum(entry.kind);
    pkt[3] = entry.mac[0];
    pkt[4] = entry.mac[1];
    pkt[5] = entry.mac[2];
    pkt[6] = entry.mac[3];
    pkt[7] = entry.mac[4];
    pkt[8] = entry.mac[5];
    pkt[9] = @bitCast(entry.rssi);
    pkt[10] = entry.score;
    std.mem.writeInt(i32, pkt[11..15], scanner.gps_lat, .little);
    std.mem.writeInt(i32, pkt[15..19], scanner.gps_lon, .little);
    std.mem.writeInt(u32, pkt[19..23], main.tick_ms, .little);
    const len: u8 = 23;
    pkt[len] = crc8(pkt[0..len]);
    return len + 1;
}

/// Build and send a detection packet for a tracker entry.
pub fn meshSend(entry: @TypeOf(main.trackers[0])) void {
    var pkt: [PKT_MAX]u8 = undefined;
    const len = makeDetection(&pkt, entry);
    _ = main.lora_send(&pkt, len);
}

/// Build and broadcast a heartbeat. Called periodically from the main loop.
pub fn sendHeartbeat() void {
    var pkt: [PKT_MAX]u8 = undefined;
    const len = makeHeartbeat(&pkt, mesh_battery_mv, scanner.gps_lat, scanner.gps_lon, mesh_uptime_sec);
    _ = main.lora_send(&pkt, len);
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
    // Heartbeat-reported state:
    battery_mv: u16 = 0,
    lat: i32 = 0,
    lon: i32 = 0,
    uptime: u32 = 0,
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

// ================================================================
// DEDUPLICATION
// ================================================================
//
// Multiple units near the same camera all broadcast the same detection.
// Drop a repeat (sender, MAC) seen within the window so the base station
// table isn't spammed and LoRa airtime isn't wasted.

const DEDUP_CACHE_SIZE = 16;
const DEDUP_WINDOW_MS: u32 = 300000; // 5 minutes

const DedupEntry = struct {
    sender_id: u8 = 0,
    mac_hash: u32 = 0,
    time_ms: u32 = 0,
};

var dedup_cache: [DEDUP_CACHE_SIZE]DedupEntry = [_]DedupEntry{.{}} ** DEDUP_CACHE_SIZE;
var dedup_idx: usize = 0;

fn isDuplicate(sender_id: u8, mac: [6]u8, now_ms: u32) bool {
    const hash = std.mem.readInt(u32, mac[0..4], .little);
    for (dedup_cache) |entry| {
        if (entry.sender_id == sender_id and entry.mac_hash == hash) {
            if ((now_ms -% entry.time_ms) < DEDUP_WINDOW_MS) return true;
        }
    }
    return false;
}

fn recordDedup(sender_id: u8, mac: [6]u8, now_ms: u32) void {
    const hash = std.mem.readInt(u32, mac[0..4], .little);
    dedup_cache[dedup_idx] = .{ .sender_id = sender_id, .mac_hash = hash, .time_ms = now_ms };
    dedup_idx = (dedup_idx + 1) % DEDUP_CACHE_SIZE;
}

// ================================================================
// BASE-STATION CAMERA MAP
// ================================================================
//
// Aggregates every mesh camera detection into a deduplicated map,
// exposed via /api/cameras. After units drive around for a week the
// dashboard shows every camera seen.

const CAMERA_MAP_SIZE = 128;

pub const CameraEntry = struct {
    oui: [3]u8 = .{ 0, 0, 0 },
    mac_hash: u32 = 0,
    first_seen: u32 = 0,
    last_seen: u32 = 0,
    count: u32 = 0,
    reporters: [8]u8 = [_]u8{0} ** 8, // bitmask of reporting node IDs (0..63)
    reporter_count: u8 = 0,
    best_rssi: i8 = -128,
    lat: i32 = 0,
    lon: i32 = 0,
};

pub var camera_map: [CAMERA_MAP_SIZE]CameraEntry = [_]CameraEntry{.{}} ** CAMERA_MAP_SIZE;
pub var camera_map_count: usize = 0;

fn updateCameraMap(mac: [6]u8, sender_id: u8, rssi: i8, lat: i32, lon: i32) void {
    const hash = std.mem.readInt(u32, mac[0..4], .little);
    const now = main.tick_ms;
    // Reporter bitmask covers IDs 0..63; fold larger node IDs in.
    const sid: u8 = sender_id & 0x3F;
    const bit: u8 = @as(u8, 1) << @as(u3, @truncate(sid % 8));

    for (0..camera_map_count) |i| {
        if (camera_map[i].mac_hash == hash) {
            camera_map[i].last_seen = now;
            camera_map[i].count += 1;
            if (rssi > camera_map[i].best_rssi) camera_map[i].best_rssi = rssi;
            if (camera_map[i].reporters[sid / 8] & bit == 0) {
                camera_map[i].reporters[sid / 8] |= bit;
                camera_map[i].reporter_count += 1;
            }
            camera_map[i].lat = @divTrunc(camera_map[i].lat + lat, 2);
            camera_map[i].lon = @divTrunc(camera_map[i].lon + lon, 2);
            return;
        }
    }

    if (camera_map_count < CAMERA_MAP_SIZE) {
        var e = CameraEntry{
            .oui = mac[0..3].*,
            .mac_hash = hash,
            .first_seen = now,
            .last_seen = now,
            .count = 1,
            .reporter_count = 1,
            .best_rssi = rssi,
            .lat = lat,
            .lon = lon,
        };
        e.reporters[sid / 8] |= bit;
        camera_map[camera_map_count] = e;
        camera_map_count += 1;
    }
}

// ================================================================
// RECEIVE
// ================================================================

pub fn meshRecv(pkt: []const u8) void {
    if (pkt.len < 2) return;

    // Validate CRC-8 over all but the trailing checksum byte.
    const data = pkt[0 .. pkt.len - 1];
    if (crc8(data) != pkt[pkt.len - 1]) return;

    const header = pkt[0];
    const pkt_type: u4 = @truncate(header & 0x0F);
    const hop: u4 = @truncate((header >> 4) & 0x0F);

    switch (pkt_type) {
        TYPE_HEARTBEAT => recvHeartbeat(pkt, hop),
        TYPE_DETECTION => recvDetection(pkt, hop),
        else => {},
    }
}

fn recvHeartbeat(pkt: []const u8, hop: u4) void {
    _ = hop;
    if (pkt.len < 17) return;
    const sender_id: u8 = pkt[1];
    const bat_mv: u16 = std.mem.readInt(u16, pkt[2..][0..2], .little);
    const lat: i32 = std.mem.readInt(i32, pkt[4..][0..4], .little);
    const lon: i32 = std.mem.readInt(i32, pkt[8..][0..4], .little);
    const uptime: u32 = std.mem.readInt(u32, pkt[12..][0..4], .little);

    peerSeen(sender_id);

    for (0..peer_count) |i| {
        if (peers[i].id == sender_id) {
            peers[i].battery_mv = bat_mv;
            peers[i].lat = lat;
            peers[i].lon = lon;
            peers[i].uptime = uptime;
            break;
        }
    }
}

fn recvDetection(pkt: []const u8, hop: u4) void {
    _ = hop;
    if (pkt.len < 24) return;

    const sender_id: u8 = pkt[1];
    const kind: display.TrackerType = @enumFromInt(pkt[2]);
    const mac: [6]u8 = pkt[3..9].*;
    const rssi: i8 = @bitCast(pkt[9]);
    const score: u8 = pkt[10];
    const lat: i32 = std.mem.readInt(i32, pkt[11..][0..4], .little);
    const lon: i32 = std.mem.readInt(i32, pkt[15..][0..4], .little);

    peerSeen(sender_id);

    if (kind == .unknown) return;
    if (isDuplicate(sender_id, mac, main.tick_ms)) return;
    recordDedup(sender_id, mac, main.tick_ms);

    const result = scanner.ClassResult{ .kind = kind, .methods = 0 };
    _ = scanner.trackDevice(mac, result, rssi);

    // Tag the entry as mesh-sourced, adopt a higher score, and store the
    // reporting unit's GPS position.
    for (0..main.tracker_count) |i| {
        if (std.mem.eql(u8, &main.trackers[i].mac, &mac)) {
            main.trackers[i].source = 1;
            if (score > main.trackers[i].score) main.trackers[i].score = score;
            main.trackers[i].mesh_lat = lat;
            main.trackers[i].mesh_lon = lon;
            break;
        }
    }

    updateCameraMap(mac, sender_id, rssi, lat, lon);
}
