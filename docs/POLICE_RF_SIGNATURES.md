# Police Vehicle RF Signature Research

> All OUIs verified against the IEEE Registration Authority database (standards-oui.ieee.org) on 2025-06-24.
> "No OUI" means the company does not hold an IEEE MA-L/MA-M/MA-S assignment.
> Their devices use commodity WiFi/BLE modules (Intel, Qualcomm, Broadcom) and are not identifiable by MAC prefix alone.

## Confirmed OUIs (already added to ouis.txt)

### Police Networking (LTE Routers, Vehicle APs)

| OUI | Vendor | Context |
|-----|--------|---------|
| 00:30:44, 00:E0:1C, 0C:1C:20 | Cradlepoint | Vehicle LTE routers, near-ubiquitous in US police cruisers |
| D4:13:F8, 00:11:6E, 10:56:CA, 00:30:1A | Peplink | Mobile networking, municipal vehicles |
| 50:13:9D, 84:DB:2F, 64:CE:6E, AC:3A:7A | Sierra Wireless | AirLink mobile routers, public safety |
| 64:64:4B | Digi International | Digi Transport routers, municipal deployments |
| B4:1C:AF, 20:97:27, 38:8A:21, 7C:D9:F4 | Teltonika | RUT series routers, common in EU police vehicles |

**Detection value:** HIGH. These are the backbone of the in-car network. A Cradlepoint AP at -55 dBm in a parking lot at 2 AM is suspicious regardless of what else is around.

### Police Computing (Rugged Laptops, Mobile Data Terminals)

| OUI | Vendor | Context |
|-----|--------|---------|
| 00:1B:D3, CC:7E:E7, 20:C6:EB, BC:C3:42, 08:00:23, B8:20:8E | Panasonic | Toughbook/Toughpad — the standard-issue police laptop |
| 00:04:7D, 00:1F:92, 4C:CC:34, 00:18:85 | Motorola Solutions | MW810/ML910 mobile workstations, APX radio WiFi bridges |

**Detection value:** HIGH. A static MAC Panasonic Toughbook at -60 dBm in a vehicle is a very strong signal.

### Body Cameras & In-Car Video

| OUI | Vendor | Context |
|-----|--------|---------|
| 00:25:DF | Axon Enterprise | Body 2/3/4 cameras, Fleet 2/3 in-car systems |
| 00:1D:96 | WatchGuard Video | Vista / 4RE in-car video systems |

**Detection value:** MEDIUM. Body cameras are WiFi clients (STA), not APs. They appear in probe requests when scanning for their upload network. A probe request from 00:25:DF is a clear Axon signature. Axon Body 3/4 use LTE + WiFi; they may also appear as BLE peripherals (unverified).

### ALPR (License Plate Readers)

| OUI | Vendor | Context |
|-----|--------|---------|
| 0C:BF:15 | Genetec | AutoVu ALPR — both patrol-car and fixed-site installations |
| (Motorola OUI) | Motorola Vigilant | Shares parent company OUIs with Motorola Solutions |

**Detection value:** HIGH. An ALPR in a patrol car is always active and broadcasting.

### Radar

| OUI | Vendor | Context |
|-----|--------|---------|
| 6C:18:11 | Decatur Electronics | Genesis series radar — has an OUI, likely for data export or configuration WiFi |

**Detection value:** LOW-MEDIUM. Only Decatur has an IEEE OUI. Stalker, Kustom Signals, and MPH Industries do not hold IEEE assignments.

## Unknown / Needs Field Verification

### Radar Gun BLE/WiFi

Stalker Radar, Kustom Signals, and MPH Industries dominate the US police radar market and hold ZERO IEEE OUI assignments. If their radar units have Bluetooth (for data export to the patrol laptop or calibration), they use commodity Bluetooth modules (Nordic, TI, Cypress). Detection would require:

1. Capturing BLE advertisements from a known police radar unit at close range
2. Identifying the manufacturer data pattern, service UUIDs, or device name string
3. Adding the signature to the BLE_SIGNATURES table

**How to capture:** Drive near a known speed trap with Argus running. Look for BLE devices with static MACs, manufacturer data, no device name, and continuous TX that appear at the same RSSI as the radar car. The clustering engine will already group these with the cruiser's other devices.

### Getac Rugged Laptops

Getac (B360, S410, X600) does not hold an IEEE OUI. Their WiFi cards are Intel or Qualcomm modules with generic OUIs. They cannot be identified by MAC prefix alone. However:

- A Getac in a patrol car will be connected to the Cradlepoint/Sierra AP
- It may broadcast a device name like "GETAC-B360" in NetBIOS/mDNS
- It runs Windows — Windows WiFi probe requests include vendor-specific information elements

### Police Cruiser SSID Patterns

No centralized database exists. Common patterns observed in wardriving data:
- Default manufacturer SSIDs: "Cradlepoint-XXXX", "Sierra-XXXX", "Pepwave-XXXX"
- Department-specific: "[CITY]PD-MOBILE", "PD-CAR-[NUMBER]"
- Generic: "mobile-router", "vehicle-ap", "cruiser-wifi"
- Axon body cameras search for networks named "Axon-XXXX" or department-configured SSIDs

**Detection approach:** Don't match SSIDs. Match the OUI of the AP (Cradlepoint/Sierra/Pepwave) — that's the reliable signal. The SSID is just corroboration.

### Police Radio WiFi Bridges

Modern police radios (Motorola APX series, Harris XL series) have WiFi for programming and data. The Motorola APX uses a WiFi bridge that appears as a Motorola Solutions OUI (00:04:7D, etc.). Harris XL-200P uses L3Harris OUIs. These are short-range (~30m) but always on in the cruiser.

## BLE Signature Research Needs

### To capture in the field:

| Device | What to look for | Priority |
|--------|-----------------|----------|
| Stalker DSR/Patrol radar | BLE manufacturer data, service UUIDs, device name | HIGH — would be a smoking gun |
| Kustom Golden Eagle radar | Same as above | HIGH |
| MPH Bee III radar | Same as above | HIGH |
| Axon Body 3/4 camera | BLE advertisements when docked in cruiser | MEDIUM |
| Motorola APX radio | BLE or WiFi Direct when active | MEDIUM |
| Panasonic Toughbook | Windows WiFi probe IEs, NetBIOS name broadcasts | MEDIUM |
| WatchGuard in-car video | WiFi probe requests, BLE when syncing | LOW |

### Method:

1. Find a known police cruiser (station parking lot, speed trap, public event)
2. Run Argus within 30m for 5-10 minutes
3. Dump CSV: long-press button, capture serial output
4. Filter for unknown BLE devices with static MACs (byte 0, bit 1 clear)
5. Cross-reference with the clustering engine — devices that cluster with known cruiser equipment (Cradlepoint AP, Panasonic laptop) are candidates
6. For each candidate, note the manufacturer data header (first 2 bytes = company ID), any service UUIDs, and the advertisement type

## What Argus Already Detects in a Police Cruiser

With the current OUI database, a fully-equipped police cruiser would appear as:

| Device | OUI Match | Classification | Score |
|--------|-----------|---------------|-------|
| Cradlepoint LTE router | ✓ | wifi_device | 25 (OUI-only cap) |
| Panasonic Toughbook | ✓ | wifi_device | 25 |
| Axon body camera (WiFi client) | ✓ | wifi_device | 25 |
| Flock camera (if equipped) | ✓ (SSID) | flock_camera | 85+ |
| Drone (if airborne) | ✓ | drone | 60+ |
| Officer's phone | — | unknown/randomized | 0 |

**Without clustering:** Each device individually scores ≤25 (below alert threshold). Nothing triggers.

**With clustering:** 5+ devices at the same RSSI, co-moving, all OUI-matched to police equipment. Cluster score: 30(Toughbook) + 25(drone) + 25(camera) + 10(wifi_device×3) = 110, ×1.5 (surv diversity) = 165, ×2.0 (night) = capped at 255. **DEPLOYMENT ALERT.**

The clustering engine was the missing piece.
