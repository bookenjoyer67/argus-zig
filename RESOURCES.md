# Learning Resources — Argus Project

Curated resources for working on this codebase. Organized by what you'll hit first.
Skip sections you don't need yet. Come back when you're stuck.

---

## Zig Language

**Start here.** Don't read the whole language reference.

1. **[zig.guide](https://zig.guide)** — "Zig in 30 minutes." Syntax you'll actually use:
   `var`, `const`, `fn`, `struct`, `for`, `while`, `if`, `switch`, slices, enums.
   Skip the advanced chapters.

2. **[ziglings.org](https://ziglings.org)** — Interactive exercises. Do:
   - Exercises 1-40 (basic syntax)
   - 60-70 (slices and arrays)
   - 95-100 (C interop)
   Takes an afternoon. Skip the rest until needed.

3. **Comptime** — Read only when changing the OUI parser in `main.zig`.
   Search "zig comptime" on zig.guide. Key concepts: `comptime`, `blk:`,
   `@embedFile`, `inline for`, `@setEvalBranchQuota`.

4. **When stuck on a Zig error:** Search `zig <error message>`.
   Zig's error messages are excellent — read them before Googling.



## Embedded Zig on ESP32

5. **[kassane/zig-esp-idf-sample](https://github.com/kassane/zig-esp-idf-sample)**
   Reference project our build system is based on. Read README. Glance at `build.zig`.
   Don't try to understand all of it.

6. **[kassane/esp32-baremetal-zig](https://github.com/kassane/esp32-baremetal-zig)**
   Pure Zig ESP32, no ESP-IDF. We don't use this approach, but their docs on
   the Xtensa target and register access are excellent. Read "Toolchain requirement"
   and hardware notes.

7. **[esp-rs book](https://esp-rs.github.io/book/)**
   Rust, not Zig — but the *concepts* are identical. Skip the Rust code, read the
   explanations covering: how ESP32 chips boot, partition tables, sdkconfig,
   FreeRTOS tasks, interrupt handling, memory layout.

---

## ESP-IDF and FreeRTOS

8. **[ESP-IDF Programming Guide](https://docs.espressif.com/projects/esp-idf/en/v5.4/esp32s3/)**
   Official docs. Only three sections are relevant to this project:
   - **API Reference → Peripheral API → GPIO** — gpio_set_direction, gpio_set_level, etc.
   - **API Reference → System API → FreeRTOS** — vTaskDelay, task creation, queues
   - **API Reference → Bluetooth API → NimBLE** — when adding BLE scanning

9. **sdkconfig** — Run `idf.py menuconfig` to browse the graphical config.
   Don't change anything yet. The generated `sdkconfig` is thousands of `#define`
   statements controlling which features are compiled. Understanding this saves
   hours when something "should work but doesn't compile."

---

## BLE Basics

10. **[Novel Bits BLE Primer](https://novelbits.io/bluetooth-low-energy-ble-complete-guide/)**
    Best BLE introduction. Read:
    - Advertisements and scan response
    - GAP (Generic Access Profile)
    You don't need GATT or services yet. Key concept: BLE devices broadcast small
    packets at regular intervals. Your Heltec listens passively. No pairing,
    no connection, no authentication needed.

11. **Apple Find My spec** — Search "Apple Find My Network accessory specification"
    or look at the [OpenHaystack](https://github.com/seemoo-lab/openhaystack) project.
    Key bytes: manufacturer data starts `0x4C 0x00` (Apple company ID),
    then `0x12` (Find My type), then status byte + public key.

---

## Your Project — Argus

12. **Read `src/main.zig` top to bottom.** The file header explains the entire
    architecture. Every function has a doc comment. You don't need every line —
    just the structure.

13. **Modify one thing and rebuild.** Change the LED blink pattern in `zig_main()`
    (find "Boot animation" comment). Rebuild, flash, see your change on hardware.
    This is the fastest way to learn the edit-build-flash cycle.

14. **Search this project's session history** — use `session_search` to find the
    conversation that built this project. If something in the code doesn't make
    sense, it was probably discussed during setup.

---

## Project Files to Read First

| File | Why | Time |
|------|-----|------|
| `AGENTS.md` | Architecture overview, build commands, dos/don'ts | 5 min |
| `BUILD.md` | Toolchain setup, troubleshooting | 5 min |
| `main.zig` lines 1-70 | Pin map, extern fn declarations, OUI db | 5 min |
| `main.zig` lines 280-end | Main loop, display pages, alert system | 5 min |
| `main.c` | C entry point, NVS init | 2 min |

Full codebase read: ~20 minutes.

---

## When You're Stuck

| Problem | Where to look |
|---------|--------------|
| Zig syntax error | [zig.guide](https://zig.guide) matching chapter |
| `error: C import failed` | BUILD.md section on @cImport vs extern fn |
| ESP-IDF build error | `idf.py menuconfig` → check component is enabled |
| Linker "undefined reference" | Check `extern fn` matches ESP-IDF API docs |
| Heltec V3 pin question | `main.zig` lines ~60-90 has the pin map |
| Zig 0.16 version mismatch | `AGENTS.md` "Zig 0.16 quirks" section |
| "Why did you do it this way?" | Comment above the code in question |

---

## What to Skip

- Don't read the Zig language reference cover to cover
- Don't learn Zig's async/await (we use FreeRTOS tasks instead)
- Don't read the entire ESP-IDF docs (5,000+ pages)
- Don't learn about BLE GATT services or connections (we only scan passively)
- Don't try to understand `build.zig` in detail (build-zig.sh is simpler)
- Don't learn about PSRAM (Heltec V3 doesn't have it)
- Don't read the NimBLE source code (we only use the scan API)

---

## Build Commands (Quick Reference)

```bash
# Full build cycle
cd ~/argus-zig
./build-zig.sh                              # Zig → libargus.a
source ~/esp/esp-idf/export.sh              # ESP-IDF environment
idf.py build                                # Full firmware
idf.py -p /dev/ttyUSB0 flash monitor        # Flash + serial

# Incremental (Zig only changed)
./build-zig.sh && idf.py build

# Config change
idf.py menuconfig
idf.py build

# Full clean
rm -rf build zig-out zig-cache
./build-zig.sh
idf.py set-target esp32s3
idf.py build
```
