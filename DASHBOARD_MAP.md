# Dashboard Map Panel

Add an interactive map to the web dashboard showing camera locations
reported over the mesh. Built on Leaflet.js + OpenStreetMap tiles.
Zero additional backend code — reads the `/api/cameras` endpoint specified
in MESH_IMPROVEMENTS.md section 5.

## What it looks like

```
┌──────────────────────────────────────────────────────────┐
│  ARGUS MESH HUB                              uptime 14h  │
│                                                          │
│  ┌──────────────────────────────────────────────────┐    │
│  │                                                  │    │
│  │                    MAP                           │    │
│  │                                                  │    │
│  │         📍                                      │    │
│  │              📍                                  │    │
│  │    📍                                           │    │
│  │                    📍                            │    │
│  │                                                  │    │
│  └──────────────────────────────────────────────────┘    │
│                                                          │
│  12 cameras mapped   3 peers online    Last: 2h ago      │
│                                                          │
│  ── Latest ──────────────────────────────────────────    │
│  FLK 70:C9:4E  CERT  2h ago  (mesh via UNIT-02)       │
│  DRN DJI Mini  HIGH  5h ago  (direct)                  │
│                                                          │
│  [Threats] [Map] [Mesh] [Export CSV] [v1.0.0]           │
└──────────────────────────────────────────────────────────┘
```

## Implementation

### web/dashboard.html — new panel

Add a second view to the dashboard. The existing threat grid + feed is "View 1."
The map is "View 2." Tab bar at the top switches between them.

```html
<!-- Tab bar -->
<div id="tabs">
  <button onclick="showView('threats')" class="active">Threats</button>
  <button onclick="showView('map')">Map</button>
  <button onclick="showView('mesh')">Mesh</button>
</div>

<!-- Views -->
<div id="view-threats">
  <!-- existing threat grid + feed -->
</div>
<div id="view-map" style="display:none">
  <div id="map" style="width:100%; height:60vh"></div>
  <div id="map-stats"></div>
</div>
<div id="view-mesh" style="display:none">
  <!-- existing mesh peer list -->
</div>
```

### Leaflet.js

Load from CDN in `<head>`. No build step, no npm, no local files.

```html
<link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css" />
<script src="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js"></script>
```

The base station is on home WiFi. The browser loading the dashboard is on the
same network. Tiles load from the internet. The Heltec only serves the HTML and
the JSON API — it never touches map tiles.

### Map initialization

```javascript
let map = null;
let markers = {};

function initMap() {
    if (map) return;
    map = L.map('map').setView([38.6270, -90.1994], 13); // default: St. Louis
    L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
        attribution: '&copy; OpenStreetMap contributors',
        maxZoom: 19
    }).addTo(map);
}
```

The initial view is hardcoded to a default location. When GPS data arrives
from the mobile unit (via heartbeat or detection), the map recenters to the
user's actual location.

### Marker colors

```javascript
const CLASS_COLORS = {
    flock_camera: '#ff4444',  // red
    wifi_device:  '#ff8844',  // orange
    drone:        '#4488ff',  // blue
    raven:        '#ff44ff',  // purple
    camera:       '#ff8844',  // orange
};

function markerColor(kind) {
    return CLASS_COLORS[kind] || '#888888';
}
```

Circle markers with colored fill, white border, radius proportional to
sighting count (min 8px, max 24px).

### Popup

Click a marker:

```
┌──────────────────────┐
│ Flock Safety ALPR    │
│ OUI: 70:C9:4E        │
│ Seen: 47 times       │
│ By: 3 peers          │
│ First: 3d ago        │
│ Last: 2h ago         │
│ RSSI: -58 dBm        │
└──────────────────────┘
```

### Polling

Fetch `/api/cameras` every 30 seconds. Update markers without removing
unchanged ones (avoids flicker).

```javascript
async function pollCameras() {
    const cameras = await fetch('/api/cameras').then(r => r.json());
    updateMarkers(cameras);
    updateMapStats(cameras);
}

function updateMarkers(cameras) {
    // Remove markers for cameras no longer in the list
    const seen = new Set(cameras.map(c => c.oui + c.lat + c.lon));
    for (const key in markers) {
        if (!seen.has(key)) {
            map.removeLayer(markers[key]);
            delete markers[key];
        }
    }

    // Add or update markers
    for (const cam of cameras) {
        if (cam.lat === 0 && cam.lon === 0) continue; // no GPS
        const lat = cam.lat / 1000000;
        const lon = cam.lon / 1000000;
        const key = cam.oui + cam.lat + cam.lon;
        const radius = Math.min(24, Math.max(8, cam.count));

        if (markers[key]) {
            markers[key].setLatLng([lat, lon]);
            markers[key].setRadius(radius);
        } else {
            const color = markerColor(cam.kind || 'wifi_device');
            const marker = L.circleMarker([lat, lon], {
                radius: radius,
                fillColor: color,
                color: '#ffffff',
                weight: 1,
                fillOpacity: 0.8
            }).addTo(map);

            const popup = `
                <b>${cam.kind || 'Unknown'}</b><br>
                OUI: ${cam.oui}<br>
                Seen: ${cam.count} times<br>
                By: ${cam.reporters || 1} peers<br>
                Last: ${formatAge(cam.last_seen_seconds)}<br>
                RSSI: ${cam.best_rssi} dBm
            `;
            marker.bindPopup(popup);
            markers[key] = marker;
        }
    }
}
```

### Map stats bar

Below the map, a summary line:

```javascript
function updateMapStats(cameras) {
    const total = cameras.length;
    const last = cameras.reduce((max, c) => Math.max(max, c.last_seen_seconds), 0);
    document.getElementById('map-stats').innerHTML =
        `${total} cameras mapped  |  Last seen: ${formatAge(last)}`;
}
```

### GPS-driven recenter

When the mobile unit reports GPS via heartbeat, the base station knows the
user's location. Recenter the map on first GPS fix:

```javascript
let mapCentered = false;

async function pollStatus() {
    const s = await fetch('/api/status').then(r => r.json());
    // ... existing status updates ...

    // Recenter map on first GPS-enabled peer
    if (!mapCentered && s.mesh_peers > 0) {
        const peers = await fetch('/api/mesh').then(r => r.json());
        for (const p of peers) {
            if (p.lat && p.lon && p.lat !== 0) {
                map.setView([p.lat / 1000000, p.lon / 1000000], 14);
                mapCentered = true;
                break;
            }
        }
    }
}
```

### CSS

```css
#map {
    border-radius: 4px;
    border: 1px solid var(--accent);
}

#map-stats {
    padding: 0.5rem 1rem;
    font-size: 0.85rem;
    color: #888;
}

#tabs {
    display: flex;
    gap: 0;
    margin-bottom: 1rem;
}

#tabs button {
    padding: 0.5rem 1rem;
    background: var(--surface);
    color: var(--text);
    border: 1px solid var(--accent);
    cursor: pointer;
    font-size: 0.9rem;
}

#tabs button.active {
    background: var(--accent);
    color: #fff;
}

#tabs button:first-child {
    border-radius: 4px 0 0 4px;
}

#tabs button:last-child {
    border-radius: 0 4px 4px 0;
}
```

### Tab switching

```javascript
function showView(name) {
    document.querySelectorAll('[id^="view-"]').forEach(el => el.style.display = 'none');
    document.getElementById('view-' + name).style.display = 'block';
    document.querySelectorAll('#tabs button').forEach(b => b.classList.remove('active'));
    event.target.classList.add('active');

    if (name === 'map') {
        initMap();
        pollCameras();
    }
}
```

### Polling intervals

```
/api/status:    3 seconds   (existing)
/api/detections: 10 seconds  (existing)
/api/mesh:      30 seconds   (existing)
/api/cameras:   30 seconds   (new)
```

Camera map polling is infrequent because the data changes slowly — new
cameras are discovered on the timescale of hours, not seconds.

## File changes

```
web/dashboard.html   ← add Leaflet CDN links, map div, tab bar, JS
main/httpd.c         ← register /api/cameras route (already specified in MESH_IMPROVEMENTS.md §5)
src/api.zig          ← zig_api_cameras() (already specified in MESH_IMPROVEMENTS.md §5)
src/mesh.zig         ← camera_map data structure + updateCameraMap() (§5)
```

The Zig and C work for the camera map endpoint is already specified in
MESH_IMPROVEMENTS.md section 5. This document covers only the frontend.

## Effort

| Task | Time |
|------|------|
| Add Leaflet to dashboard HTML | 10 min |
| Tab bar + view switching | 20 min |
| pollCameras + updateMarkers | 30 min |
| Popup formatting | 15 min |
| GPS recenter logic | 15 min |
| CSS | 15 min |
| Testing with real data | 20 min |
| **Total** | **~2 hours** |

## What it depends on

- `/api/cameras` endpoint (MESH_IMPROVEMENTS.md §5 — base station camera map)
- Heartbeat GPS fields (MESH_IMPROVEMENTS.md §3 — GPS in detection packets)
- At least one mobile unit driving around with GPS for a few days to populate
  the map with real data

Without GPS on the mobile unit, the map shows no pins. Adding GPS to the
mesh detection packet and heartbeat packet is prerequisite.
