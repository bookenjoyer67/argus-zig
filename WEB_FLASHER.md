# Web Flasher — Browser-Based Firmware Flashing

Single HTML page on GitHub Pages. User plugs in Heltec V3 via USB,
opens the page, clicks Flash. Browser flashes the firmware over WebSerial.
No PlatformIO, no Zig toolchain, no ESP-IDF, no terminal.

---

## How it works

1. User navigates to `https://bookenjoyer67.github.io/argus-zig/flash.html`
2. Page loads esptool-js from CDN
3. User clicks "Connect" → browser shows USB device picker
4. User selects the CP2102 USB-UART (the Heltec's serial chip)
5. Page auto-detects ESP32-S3 chip
6. Click "Flash" → progress bar shows 4 files being written:
   - Bootloader (0x0000)
   - Partition table (0x8000)
   - Factory firmware (0x10000)
   - SPIFFS/LittleFS image (optional, pre-erased)
7. "Done — device rebooting" message

---

## Technical stack

| Component | Source | Size |
|-----------|--------|------|
| esptool-js | CDN (unpkg) | ~200KB gzipped |
| Manifest JSON | Embedded in page or separate file | ~500 bytes |
| Firmware .bin | GitHub Releases (CDN via jsdelivr) | ~1.2MB |
| HTML/JS | Single file, ~3KB | Self-explanatory |

---

## File structure

```
argus-zig/
├── flash/
│   ├── manifest.json     ← what to flash where
│   └── index.html        ← the flasher page
├── .github/
│   └── workflows/
│       └── release.yml   ← builds firmware + uploads to Releases
```

---

## manifest.json

```json
{
  "name": "Argus — Surveillance Tracker Scanner",
  "chip": "esp32s3",
  "baud": 460800,
  "parts": [
    {
      "path": "bootloader.bin",
      "offset": "0x0000"
    },
    {
      "path": "partition-table.bin",
      "offset": "0x8000"
    },
    {
      "path": "argus-zig.bin",
      "offset": "0x10000"
    }
  ]
}
```

The flasher page reads this manifest and queues the flash operations.
Files are fetched from GitHub Releases at the tagged version.

---

## index.html

Single page, dark theme, minimal UI:

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Argus Flasher</title>
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      font-family: system-ui;
      background: #0a0a1a; color: #e0e0e0;
      display: flex; justify-content: center; align-items: center;
      min-height: 100vh;
    }
    .container {
      max-width: 420px; width: 100%; padding: 2rem;
      text-align: center;
    }
    h1 { color: #ff1493; margin-bottom: 0.5rem; }
    .sub { color: #888; font-size: 0.9rem; margin-bottom: 2rem; }
    button {
      width: 100%; padding: 1rem;
      background: #ff1493; color: #fff;
      border: none; border-radius: 6px;
      font-size: 1.1rem; cursor: pointer;
      margin-bottom: 1rem;
    }
    button:disabled {
      background: #444; color: #888; cursor: not-allowed;
    }
    #progress {
      width: 100%; height: 8px;
      background: #1a1a2e; border-radius: 4px;
      margin: 1rem 0; overflow: hidden;
    }
    #progress-bar {
      width: 0%; height: 100%;
      background: #ff1493;
      transition: width 0.3s;
    }
    #log {
      text-align: left; font-size: 0.8rem; color: #888;
      max-height: 200px; overflow-y: auto;
      background: #111; padding: 0.5rem;
      border-radius: 4px;
    }
    .log-line { margin-bottom: 0.25rem; }
    .error { color: #ff4444; }
    .success { color: #00cc66; }
  </style>
</head>
<body>
  <div class="container">
    <h1>Argus Flasher</h1>
    <p class="sub">Flash the Argus firmware to your Heltec WiFi LoRa 32 V3</p>

    <button id="btn-connect" onclick="connect()">Connect Device</button>
    <button id="btn-flash" onclick="flash()" disabled>Flash Firmware</button>

    <div id="progress"><div id="progress-bar"></div></div>
    <div id="log"></div>
  </div>

  <script type="module">
    import { ESPLoader, Transport } from 'https://unpkg.com/esptool-js@0.5.0/lib/index.js';

    let loader = null;
    let device = null;

    const log = (msg, cls = '') => {
      const el = document.getElementById('log');
      el.innerHTML += `<div class="log-line ${cls}">${msg}</div>`;
      el.scrollTop = el.scrollHeight;
    };

    const setProgress = (pct) => {
      document.getElementById('progress-bar').style.width = pct + '%';
    };

    window.connect = async () => {
      try {
        device = await navigator.serial.requestPort();
        const transport = new Transport(device);
        loader = new ESPLoader({
          transport,
          baudrate: 460800,
          romBaudrate: 115200,
        });
        await loader.main();
        const chip = await loader.chipName();
        log(`Connected: ${chip}`, 'success');
        document.getElementById('btn-flash').disabled = false;
        document.getElementById('btn-connect').disabled = true;
      } catch (e) {
        log(`Connect failed: ${e.message}`, 'error');
      }
    };

    window.flash = async () => {
      if (!loader) return;
      const btn = document.getElementById('btn-flash');
      btn.disabled = true;
      setProgress(0);

      try {
        // Fetch manifest from GitHub Releases
        const version = 'v1.0.0'; // pinned to latest release
        const base = `https://github.com/bookenjoyer67/argus-zig/releases/download/${version}`;

        const files = [
          { path: 'bootloader.bin',   offset: 0x0000 },
          { path: 'partition-table.bin', offset: 0x8000 },
          { path: 'argus-zig.bin',    offset: 0x10000 },
        ];

        for (let i = 0; i < files.length; i++) {
          const f = files[i];
          log(`Flashing ${f.path}...`);
          const resp = await fetch(`${base}/${f.path}`);
          if (!resp.ok) throw new Error(`Download failed: ${f.path}`);
          const data = new Uint8Array(await resp.arrayBuffer());
          await loader.flashData(data, (pct) => {
            const total = (i / files.length) * 100 + (pct / files.length);
            setProgress(total);
          }, f.offset);
          log(`  ✓ ${f.path}`, 'success');
        }

        log('Done — device rebooting', 'success');
        setProgress(100);
      } catch (e) {
        log(`Flash failed: ${e.message}`, 'error');
        btn.disabled = false;
      }
    };
  </script>
</body>
</html>
```

---

## GitHub Actions workflow

`.github/workflows/release.yml`:

```yaml
name: Build and Release

on:
  push:
    tags:
      - 'v*'

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          submodules: true

      # Install ESP-IDF and Zig Xtensa toolchains
      # (Self-hosted runner or Docker container with pre-installed toolchains)
      # For GitHub-hosted runners: use a Docker image with ESP-IDF + Zig pre-installed
      # Or: build on a self-hosted runner on your machine

      - name: Build firmware
        run: |
          cd argus-zig
          ./build-zig.sh
          . ~/esp/esp-idf/export.sh
          idf.py build

      - name: Collect artifacts
        run: |
          mkdir -p release
          cp argus-zig/build/bootloader/bootloader.bin release/
          cp argus-zig/build/partition_table/partition-table.bin release/
          cp argus-zig/build/argus-zig.bin release/

      - name: Create Release
        uses: softprops/action-gh-release@v2
        with:
          files: release/*
          generate_release_notes: true
```

The GitHub Actions runner needs ESP-IDF and the Zig Xtensa fork pre-installed.
For hosted runners, this means a custom Docker image. For simplicity, the
first few releases can be built locally and uploaded manually to GitHub Releases.
The CI workflow is a future optimization.

---

## GitHub Pages deployment

Create a `gh-pages` branch or use the `/docs` folder approach:

1. Enable GitHub Pages in repo Settings → Pages
2. Source: `Deploy from a branch` → `main` → `/docs`
3. Move `flash/index.html` to `docs/index.html`
4. Page is live at `https://bookenjoyer67.github.io/argus-zig/`

Or use a separate `gh-pages` branch with just the flasher files — cleaner
separation from the main codebase.

---

## Manual release process (for v1.0)

Until CI is set up:

1. Build on your machine: `./build-zig.sh && idf.py build`
2. Collect artifacts:
   ```bash
   mkdir release-v1.0.0
   cp build/bootloader/bootloader.bin release-v1.0.0/
   cp build/partition_table/partition-table.bin release-v1.0.0/
   cp build/argus-zig.bin release-v1.0.0/
   ```
3. Create a GitHub Release tagged `v1.0.0`, attach the three .bin files
4. Push `flash/index.html` to the repo
5. Enable GitHub Pages

---

## What the user experience looks like

```
Step 1:  Open https://bookenjoyer67.github.io/argus-zig/ in Chrome/Edge
Step 2:  Plug in Heltec V3 via USB-C
Step 3:  Click "Connect Device"
         → Browser shows USB device picker
         → Select "CP2102 USB to UART Bridge Controller"
Step 4:  Click "Flash Firmware"
         → Progress bar fills
         → "Flashing bootloader.bin... ✓"
         → "Flashing partition-table.bin... ✓"
         → "Flashing argus-zig.bin... ✓"
         → "Done — device rebooting"
Step 5:  Heltec reboots. OLED shows "ARGUS" then "Scanning..."
         Done.
```

---

## Effort

| Task | Time |
|------|------|
| Write flash/index.html | 2 hours |
| Test esptool-js with Heltec V3 | 1 hour |
| Set up GitHub Pages | 30 min |
| Manual release + attach .bin files | 30 min |
| CI workflow (optional, future) | 4 hours |
| **Total** | **~4 hours** |

---

## Requirements

- Chrome or Edge (WebSerial API — Firefox and Safari don't support it yet)
- USB-C cable with data lines (charge-only cables won't work)
- Heltec V3 with CP2102 driver installed (automatic on Windows/Mac, works out of the box on Linux if you're in the `dialout` group)

---

## Limitations

- Browser-only — no phone support (mobile browsers don't expose WebSerial)
- Chrome/Edge only — Firefox, Safari don't support WebSerial
- First release requires manual .bin upload until CI is configured
- Bootloader and partition table must be included in the release (they're board-specific)
