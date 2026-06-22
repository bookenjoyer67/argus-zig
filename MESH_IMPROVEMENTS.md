# Mesh Layer Improvements — Implementation Plan

Revisions to the LoRa mesh: heartbeat packets, GPS coordinates, deduplication,
base station camera map, adaptive TX power, relay hop. Build in order — each
adds capability without breaking the previous.

---

## 1. Packet Format v2

Current packet (15 bytes):
```
[0]     class (TrackerType enum)
[1..6]  MAC (6 bytes)
[7]     RSSI (i8)
[8]     score (u8)
[9]     sender_id (u8)
[10..13] reserved
[14]    CRC (XOR of bytes 0..13)
```

New packet (24 bytes, variable payload):
```
[0]     type: u4 | hop_count: u4
[1]     payload (variable)
[...]   ...
[N-1]   CRC (XOR of bytes 0..N-2)
```

Type values:
- `0x01` — heartbeat
- `0x02` — detection
- `0x03` — ack (future)

Hop count: 0 = origin, 1 = one relay, capped at 3.

### Type 0x01 — Heartbeat (12 bytes total)

```
[0]     type:0x01 | hop_count:0
[1]     sender_id (u8)
[2..3]  battery_mv (u16 LE)
[4..7]  lat (i32 LE, microdegrees — same format as scanner.gps_lat)
[8..11] lon (i32 LE)
[12..15] uptime_seconds (u32 LE)
[16]    CRC
```

12 bytes. GPS fields are 0 when no fix. Battery in millivolts. Uptime for diagnostics.

### Type 0x02 — Detection (24 bytes total)

```
[0]     type:0x02 | hop_count
[1]     sender_id (u8)
[2]     class (u8, TrackerType enum)
[3..8]  MAC (6 bytes)
[9]     RSSI at detecting unit (i8)
[10]    score (u8)
[11..14] lat (i32 LE, detection location)
[15..18] lon (i32 LE)
[19..22] detection_time_ms (u32 LE, tick_ms at detecting unit)
[23]    CRC
```

24 bytes. GPS is the detecting unit's position, not the camera's — that's all we have.

### CRC change

Current CRC is XOR of all bytes. Weak against burst errors (two bit flips cancel).
Switch to CRC-8-Dallas/Maxim (1-Wire): polynomial 0x31, reflected. This catches
all single-bit errors, all double-bit errors, all odd-bit errors, all burst
errors up to 8 bits.

Implementation in Zig:

```zig
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
```

### Packet builder (replaces current meshSend)

```zig
const PKT_MAX = 32; // generous for future expansion

fn makeHeartbeat(pkt: *[PKT_MAX]u8, bat_mv: u16, lat: i32, lon: i32) u8 {
    pkt[0] = 0x01; // type: heartbeat, hop 0
    pkt[1] = mesh_node_id();
    std.mem.writeInt(u16, pkt[2..4], bat_mv, .little);
    std.mem.writeInt(i32, pkt[4..8], lat, .little);
    std.mem.writeInt(i32, pkt[8..12], lon, .little);
    std.mem.writeInt(u32, pkt[12..16], main.tick_ms / 1000, .little);
    const len: u8 = 16;
    pkt[len] = crc8(pkt[0..len]);
    return len + 1;
}

fn makeDetection(pkt: *[PKT_MAX]u8, entry: @TypeOf(main.trackers[0])) u8 {
    pkt[0] = 0x02; // type: detection, hop 0
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
```

### Packet receiver (replaces current meshRecv)

```zig
pub fn meshRecv(pkt: []const u8) void {
    if (pkt.len < 2) return;

    // Validate CRC
    const data = pkt[0 .. pkt.len - 1];
    if (crc8(data) != pkt[pkt.len - 1]) return;

    const header = pkt[0];
    const pkt_type: u4 = @truncate(header & 0x0F);
    const hop: u4 = @truncate((header >> 4) & 0x0F);

    switch (pkt_type) {
        0x01 => recvHeartbeat(pkt, hop),
        0x02 => recvDetection(pkt, hop),
        else => {},
    }
}
```

---

## 2. Heartbeat Packets

### Purpose

Base station knows which peers are alive, their battery status, and approximate
location without waiting for a detection event. Mobile units can also see each
other — useful for knowing if a friend is in range.

### Data structures

Add to `src/mesh.zig`:

```zig
pub const HEARTBEAT_INTERVAL_MS: u32 = 30000; // 30 seconds
var last_heartbeat_ms: u32 = 0;

pub var mesh_battery_mv: u16 = 0;          // updated from main loop
pub var mesh_uptime_sec: u32 = 0;
```

### Peer table update

Current peerSeen() is called from detection receive only. Add a separate
heartbeat handler:

```zig
fn recvHeartbeat(pkt: []const u8, hop: u4) void {
    if (pkt.len < 17) return;
    _ = hop;
    const sender_id: u8 = pkt[1];
    const bat_mv: u16 = std.mem.readInt(u16, pkt[2..4], .little);
    const lat: i32 = std.mem.readInt(i32, pkt[4..8], .little);
    const lon: i32 = std.mem.readInt(i32, pkt[8..12], .little);
    const uptime: u32 = std.mem.readInt(u32, pkt[12..16], .little);

    peerSeen(sender_id);

    // Store additional data in peer entry
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
```

### Heartbeat transmission

Call from main loop every HEARTBEAT_INTERVAL_MS:

```zig
// In zig_main() main loop, alongside other periodic tasks:
if ((tick_ms -% mesh.last_heartbeat_ms) >= mesh.HEARTBEAT_INTERVAL_MS) {
    mesh.last_heartbeat_ms = tick_ms;
    mesh.sendHeartbeat();
}
```

```zig
pub fn sendHeartbeat() void {
    var pkt: [PKT_MAX]u8 = undefined;
    const len = makeHeartbeat(&pkt, mesh_battery_mv, scanner.gps_lat, scanner.gps_lon);
    _ = main.lora_send(&pkt, len);
}
```

### Peer table field additions

```zig
pub const MeshPeer = struct {
    id: u8 = 0,
    last_seen: u32 = 0,
    rssi: i8 = 0,
    shared: u32 = 0,
    active: bool = false,
    // Heartbeat data:
    battery_mv: u16 = 0,
    lat: i32 = 0,
    lon: i32 = 0,
    uptime: u32 = 0,
};
```

### OLED display

Add peer count and the closest peer's RSSI to the system page (page 6).
Dashboard `/api/mesh` already reads `onlinePeerCount()` and the peer table —
heartbeat data flows through automatically.

---

## 3. GPS Coordinates in Detection Packets

### Changes

The detection packet already includes lat/lon (from heartbeat format reuse).
`meshRecv` extracts GPS from the packet and stores in the tracker entry.

```zig
fn recvDetection(pkt: []const u8, hop: u4) void {
    if (pkt.len < 24) return;
    const sender_id: u8 = pkt[1];
    const kind: display.TrackerType = @enumFromInt(pkt[2]);
    const mac: [6]u8 = pkt[3..9].*;
    const rssi: i8 = @bitCast(pkt[9]);
    const score: u8 = pkt[10];
    const lat: i32 = std.mem.readInt(i32, pkt[11..15], .little);
    const lon: i32 = std.mem.readInt(i32, pkt[15..19], .little);
    const det_time: u32 = std.mem.readInt(u32, pkt[19..23], .little);

    peerSeen(sender_id);

    if (kind == .unknown) return;

    const result = scanner.ClassResult{ .kind = kind, .methods = 0 };
    _ = scanner.trackDevice(mac, result, rssi);

    for (0..main.tracker_count) |i| {
        if (std.mem.eql(u8, &main.trackers[i].mac, &mac)) {
            main.trackers[i].source = 1;
            if (score > main.trackers[i].score) main.trackers[i].score = score;
            // Store the mesh-reported GPS on the tracker entry (new fields)
            main.trackers[i].mesh_lat = lat;
            main.trackers[i].mesh_lon = lon;
            break;
        }
    }
}
```

### TrackerEntry additions (in `src/main.zig`)

```zig
pub const TrackerEntry = struct {
    // ... existing fields ...
    source: u8,              // already exists
    mesh_lat: i32 = 0,       // GPS from mesh detection
    mesh_lon: i32 = 0,       // GPS from mesh detection
};
```

### Display + CSV

Mesh detections with GPS show coordinates on surveillance page. CSV logs GPS
for mesh entries (currently lat/lon are 0 for mesh). `/api/detections` already
reads `gps_lat`/`gps_lon` — update to read `mesh_lat`/`mesh_lon` when source==1.

---

## 4. Deduplication

### Problem

Three units near the same Flock camera. Camera transmits. All three detect it.
All three broadcast to mesh within 200ms. Three duplicate detection packets.
Base station tracker table gets spammed, LoRa airtime wasted.

### Solution

Per-sender recent-detection cache. Track last 16 detections by (sender_id, MAC hash).
If the same (sender, MAC) arrives within DEDUP_WINDOW_MS (5 minutes), drop it.

```zig
const DEDUP_CACHE_SIZE = 16;
const DEDUP_WINDOW_MS: u32 = 300000; // 5 minutes

const DedupEntry = struct {
    sender_id: u8,
    mac_hash: u32,   // first 4 bytes of MAC
    time_ms: u32,
};

var dedup_cache: [DEDUP_CACHE_SIZE]DedupEntry = [_]DedupEntry{.{ .sender_id = 0, .mac_hash = 0, .time_ms = 0 }} ** DEDUP_CACHE_SIZE;
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
```

Wire into `recvDetection()`:

```zig
fn recvDetection(pkt: []const u8, hop: u4) void {
    // ... parse ...
    if (isDuplicate(sender_id, mac, main.tick_ms)) return;
    recordDedup(sender_id, mac, main.tick_ms);
    // ... process ...
}
```

---

## 5. Base Station Camera Map

### Purpose

Base station aggregates all mesh camera detections into a deduplicated map.
Exposed as `/api/cameras` endpoint. After a week of mobile units driving around,
the dashboard shows every camera in the city.

### Data structure

```zig
const CAMERA_MAP_SIZE = 128;

const CameraEntry = struct {
    oui: [3]u8,              // first 3 bytes of MAC
    mac_hash: u32,           // full MAC hash for dedup
    first_seen: u32,         // tick_ms of first detection
    last_seen: u32,          // tick_ms of most recent detection
    count: u32,              // total sightings
    reporters: [8]u8,        // which peer IDs reported this camera (bitmask)
    reporter_count: u8,      // how many unique peers
    best_rssi: i8,           // strongest RSSI seen
    lat: i32,                // avg location (running mean for simplicity)
    lon: i32,
};

var camera_map: [CAMERA_MAP_SIZE]CameraEntry = [_]CameraEntry{...} ** CAMERA_MAP_SIZE;
var camera_map_count: usize = 0;
```

### Update logic

In `recvDetection()`, after processing the tracker entry:

```zig
fn updateCameraMap(mac: [6]u8, sender_id: u8, rssi: i8, lat: i32, lon: i32) void {
    const hash = std.mem.readInt(u32, mac[0..4], .little);
    const now = main.tick_ms;

    // Update existing entry
    for (0..camera_map_count) |i| {
        if (camera_map[i].mac_hash == hash) {
            camera_map[i].last_seen = now;
            camera_map[i].count += 1;
            if (rssi > camera_map[i].best_rssi) camera_map[i].best_rssi = rssi;
            // Mark this reporter
            const bit: u8 = @as(u8, 1) << @as(u3, @truncate(sender_id % 8));
            if (camera_map[i].reporters[sender_id / 8] & bit == 0) {
                camera_map[i].reporters[sender_id / 8] |= bit;
                camera_map[i].reporter_count += 1;
            }
            // Running mean of location
            camera_map[i].lat = (camera_map[i].lat + lat) / 2;
            camera_map[i].lon = (camera_map[i].lon + lon) / 2;
            return;
        }
    }

    // New camera
    if (camera_map_count < CAMERA_MAP_SIZE) {
        const bit: u8 = @as(u8, 1) << @as(u3, @truncate(sender_id % 8));
        camera_map[camera_map_count] = .{
            .oui = mac[0..3].*,
            .mac_hash = hash,
            .first_seen = now,
            .last_seen = now,
            .count = 1,
            .reporters = [_]u8{0} ** 8,
            .reporter_count = 1,
            .best_rssi = rssi,
            .lat = lat,
            .lon = lon,
        };
        camera_map[camera_map_count].reporters[sender_id / 8] |= bit;
        camera_map_count += 1;
    }
}
```

### API endpoint

Add `GET /api/cameras`:

```zig
pub export fn zig_api_cameras(out: [*]u8, max: u32) callconv(.c) u32 {
    var b = Buf{ .data = out[0..max] };
    b.add("[", .{});
    var emitted: u32 = 0;
    for (0..mesh.camera_map_count) |i| {
        const c = mesh.camera_map[i];
        if (emitted > 0) b.add(",", .{});
        b.add("{{", .{});
        b.add("\"oui\":\"{X:0>2}:{X:0>2}:{X:0>2}\",", .{ c.oui[0], c.oui[1], c.oui[2] });
        b.add("\"count\":{d},", .{c.count});
        b.add("\"reporters\":{d},", .{c.reporter_count});
        b.add("\"best_rssi\":{d},", .{c.best_rssi});
        b.add("\"lat\":{d},", .{c.lat});
        b.add("\"lon\":{d},", .{c.lon});
        b.add("\"last_seen_seconds\":{d}", .{(main.tick_ms -% c.last_seen) / 1000});
        b.add("}}", .{});
        emitted += 1;
    }
    b.add("]", .{});
    return @intCast(b.len);
}
```

Register in httpd.c: `register_uri("/api/cameras", HTTP_GET, h_cameras);`

---

## 6. Adaptive TX Power

### Purpose

Mobile unit close to base station wastes battery at +22 dBm. Reduce power
proportional to peer RSSI. The SX1262 supports this through `SetTxParams`.

### Logic

Track the RSSI of the strongest peer (typically the base station). Map RSSI
to TX power:

```
Peer RSSI > -50:  +8 dBm   (very close)
Peer RSSI -50..-70: +14 dBm (close)
Peer RSSI -70..-90: +20 dBm (medium range)
Peer RSSI < -90:  +22 dBm   (far, max power)
```

### Implementation

Add to lora.c:

```c
int lora_set_tx_power(int8_t power_dbm) {
    if (power_dbm < -9) power_dbm = -9;
    if (power_dbm > 22) power_dbm = 22;
    uint8_t p[2] = { (uint8_t)power_dbm, 0x04 }; // ramp 200us
    lora_cmd(OP_SET_TX_PARAMS, p, 2);
    return 0;
}
```

Extern in Zig:

```zig
pub extern fn lora_set_tx_power(power_dbm: i32) i32;
```

In the main loop or heartbeat handler, periodically adjust:

```zig
fn adjustTxPower() void {
    var best_rssi: i8 = -128;
    for (0..peer_count) |i| {
        if (peers[i].active and peers[i].rssi > best_rssi) {
            best_rssi = peers[i].rssi;
        }
    }
    const power: i32 = if (best_rssi > -50) 8
        else if (best_rssi > -70) 14
        else if (best_rssi > -90) 20
        else 22;
    _ = lora_set_tx_power(power);
}
```

Call `adjustTxPower()` every 60 seconds. Only on mobile units (base station
stays at +22 dBm — it's plugged in).

---

## 7. Relay Hop

### Purpose

Extend mesh range by allowing one intermediate hop. Mobile unit A detects a
camera but is out of range of base. Mobile unit B is in range of both. B
receives A's detection, increments hop count, and re-transmits.

### Relay logic

```zig
fn recvDetection(pkt: []const u8, hop: u4) void {
    // ... validate, dedup, process ...

    // Relay: if we're not the origin and hop < max, re-transmit
    if (hop < MAX_HOP and sender_id != mesh_node_id()) {
        relayPacket(pkt);
    }
}

fn relayPacket(pkt: []const u8) void {
    // Clone the packet, increment hop count
    var relay: [PKT_MAX]u8 = undefined;
    @memcpy(relay[0..pkt.len], pkt);
    const old_hop: u4 = @truncate((relay[0] >> 4) & 0x0F);
    relay[0] = (relay[0] & 0x0F) | (@as(u8, old_hop + 1) << 4);
    // Recompute CRC over modified header
    relay[relay.len - 1] = crc8(relay[0 .. relay.len - 1]);

    // Small random delay to avoid collision with other relays (0-200ms)
    main.delayMs(@as(u32, @intCast(mesh_node_id())) % 200);
    _ = main.lora_send(&relay, @intCast(pkt.len));
}
```

The `mesh_node_id() % 200` gives a deterministic but unique delay per node —
nodes with different IDs won't collide. The base station receives the same
packet twice (once from origin, once from relay) but deduplication drops the
duplicate.

---

## 8. Implementation Order

```
Step 1: CRC-8-Dallas    (replace XOR with proper CRC, backward compatible if
                          you bump the version byte)
Step 2: Packet v2 types  (header byte with type+hop, heartbeat+detection builders)
Step 3: Heartbeats       (send/receive, peer table fields, main loop timer)
Step 4: GPS in detection (tracker entry fields, CSV + dashboard updates)
Step 5: Deduplication    (cache, isDuplicate/recordDedup, wire into recv)
Step 6: Camera map       (data structure, update logic, /api/cameras endpoint)
Step 7: Adaptive TX      (lora_set_tx_power, adjustTxPower, periodic call)
Step 8: Relay hop        (relayPacket, MAX_HOP, random delay)
```

Steps 1-5 are a focused weekend. Steps 1-6 give you a distributed camera
mapping network. Steps 7-8 are optimization and range extension.

## 9. Backward Compatibility

The old 15-byte XOR format and the new variable-length CRC-8 format share
the same LoRa frequency. Old packets will fail CRC-8 validation and be dropped.
New packets will fail XOR validation on old firmware.

Mitigation: the new firmware tries CRC-8 first. If that fails, falls back to
XOR for one release cycle. After that, XOR support is removed. Add a
`mesh_recv_legacy()` function that checks both checksums.

```zig
pub fn meshRecv(pkt: []const u8) void {
    if (pkt.len < 2) return;
    const data = pkt[0 .. pkt.len - 1];
    const checksum = pkt[pkt.len - 1];
    if (crc8(data) == checksum) {
        meshRecvV2(pkt);
    } else {
        meshRecvV1(pkt); // legacy XOR, remove after v1.1
    }
}
```

## 10. Verification

**Heartbeats:** Flash two units. Observe peer count on system page increment.
Base station dashboard `/api/mesh` shows peer with battery and uptime.

**GPS:** Walk with GPS-enabled mobile unit. Detection appears on base station
dashboard with GPS coordinates in the response.

**Dedup:** Place three units near same Flock camera. CSV on base station shows
one detection, not three.

**Camera map:** After a week of driving, `/api/cameras` returns a list of known
camera locations with sighting counts and reporter counts.

**Adaptive TX:** Monitor SX1262 current draw (or RSSI at base station). Should
drop when mobile unit is close.

**Relay:** Place unit A at 3km from base (out of range). Place unit B at 1.5km
from both. Detection from A appears at base via B. Hop count shows 1.
