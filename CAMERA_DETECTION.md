# Non-Flock Camera Detection

Consumer/commercial surveillance cameras (Hikvision, Dahua, Reolink, Axis, etc.)
rarely broadcast identifying SSIDs. They connect to the owner's WiFi with generic
names or are hidden. The OUI tells you the chip manufacturer but the SSID rarely
corroborates. The current OUI-only cap at score 25 silences these entirely.

Two approaches to surface them. Pick one or combine both.

---

## Approach A: "All Devices" OLED Page

Add a page 7: "Devices" — shows every OUI-matched device regardless of score.
No alerts, no SURV counter, just visibility. You see what's nearby without the
device screaming about it.

### OLED layout

```
┌──────────────────────────────┐
│ DEVICES               7/7   │
│                              │
│ Flock Safety  -62 dBm  ?    │
│ Hikvision     -71 dBm  ?    │
│ Lorex         -81 dBm  ?    │
│ Dahua         -90 dBm  ?    │
│                              │
│ [4 devices in OUI range]    │
│ PRG:next page               │
└──────────────────────────────┘
```

The "?" means "OUI-only, no SSID corroboration — could be anything with this
chip, could be a camera." The OLED shows the vendor name instead of the MAC
prefix because "Hikvision" means something to a human; "C4:2F:90" doesn't.

### Implementation

Add a comptime vendor lookup table alongside the OUI database:

```zig
// In src/main.zig or src/scanner.zig:
pub const OUI_MAX = 96;

pub const OuiVendor = struct {
    oui: [3]u8,
    name: []const u8,
};

// Built at compile time alongside KNOWN_OUIS.
// Same @embedFile("ouis.txt") source, but also extracts the comment text
// after each OUI as the vendor name.
//
// Format change for ouis.txt:
//   C4:2F:90  # Hikvision
//   3C:EF:8C  # Dahua
//   F4:6A:DD  # Liteon (Flock)

pub const VENDOR_COUNT: usize = blk: { ... };
pub const VENDORS: [OUI_MAX]OuiVendor = blk: { ... };

/// Look up vendor name from OUI. Returns null if not in database.
pub fn vendorName(mac: [6]u8) ?[]const u8 {
    for (VENDORS[0..VENDOR_COUNT]) |v| {
        if (std.mem.eql(u8, &v.oui, mac[0..3])) return v.name;
    }
    return null;
}
```

Draw the page by iterating tracker entries, filtering to `.wifi_device` kind
(OUI-only hits), showing vendor name and RSSI.

### Changes needed

- `src/ouis.txt` — add `# Vendor Name` comments after each OUI (backward compatible — lines without `#` still parse fine)
- `src/main.zig` — comptime vendor table built from the same @embedFile
- `src/display.zig` — new `drawAllDevices()` function, register as page 7
- `NUM_PAGES` — bump from 7 to 8

### Effort: ~2 hours

---

## Approach B: Permissive Cap for Camera OUIs

A Liteon module is in everything — laptops, routers, cameras. A Hikvision module
is only in Hikvision products. Treat them differently.

Current cap: ALL OUI-only hits → 25 (below MEDIUM, no alert, no surveillance page).

New cap: Flock/Liteon/Generic OUIs → 25. Camera-manufacturer OUIs → 50.
50 is MEDIUM — shows on surveillance page, triggers slow LED pulse, but doesn't
trigger buzzer or LoRa broadcast.

### Implementation

Tag OUIs by category in a comptime table:

```zig
const OuiCategory = enum { flock, camera, drone, generic };

const OUI_CATEGORIES: [OUI_MAX]OuiCategory = blk: {
    // Built at compile time. Categories determined by which section
    // of ouis.txt the OUI appears in (marked by # comments).
    ...
};
```

In `computeScore()`, after the general OUI cap:

```zig
// Cap OUI-only WiFi hits. Camera-manufacturer chips are unlikely
// to appear outside surveillance products — give them MEDIUM.
// General-purpose chips (Liteon) stay at 25.
if ((methods & METHOD_OUI != 0) and
    (methods & METHOD_SSID_PREFIX == 0) and
    (methods & METHOD_SSID_FLOCK == 0) and
    (methods & METHOD_CAM_SSID == 0) and
    (methods & METHOD_WIFI_DRONE == 0))
{
    const cat = ouiCategory(mac);
    const cap: u8 = switch (cat) {
        .camera, .drone => 50,   // specific to surveillance — alert
        .flock, .generic => 25,  // general-purpose chip — stay quiet
    };
    if (score > cap) score = cap;
}
```

### Behavior change

| Scenario | Before | After |
|----------|--------|-------|
| Hikvision OUI, no SSID | Score 25, hidden | Score 50, SURV counter, LED pulse, on surveillance page |
| Flock/Liteon OUI, no SSID | Score 25, hidden | Score 25, hidden (unchanged) |
| Hikvision OUI + "camera" SSID | Score 70, HIGH | Score 70, HIGH (unchanged) |

### Effort: ~1 hour

---

## Recommendation

Implement Approach A first — it gives you visibility without changing alerting
behavior. After a week of walking around, you'll know whether Approach B is
necessary (are those Hikvision OUIs actually cameras, or are they something else?)
The device page gives you data. The scoring change risks false alerts.

Both can coexist — Approach A for information, Approach B for selective alerting
once you're confident the camera OUIs are real cameras.
