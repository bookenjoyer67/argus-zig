// ================================================================
// Argus — Thin C entry point
// ================================================================
//
// This file is as small as possible by design.
// All application logic lives in src/main.zig (Zig).
//
// Responsibilities:
//   1. Initialize NVS flash (required by NimBLE and WiFi stacks)
//   2. Handle NVS flash errors (full or corrupt partition)
//   3. Call zig_main() — control never returns
//
// Why C here:
//   ESP-IDF's startup sequence (app_main) is a C function called
//   by the FreeRTOS scheduler after hardware init. Zig cannot
//   directly provide this entry point because ESP-IDF's linker
//   scripts expect the C ABI for the main task.
//
//   zig_main() is declared extern and resolved by the linker
//   against libargus.a. It uses callconv(.c) for compatibility.

#include <stdio.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "nvs_flash.h"
#include "esp_system.h"

// Defined in Zig (src/main.zig), compiled into libargus.a
extern void zig_main(void);

// ================================================================
// app_main — FreeRTOS main task entry
// ================================================================
//
// Called by ESP-IDF's startup code after:
//   - Bootloader handoff (second stage bootloader → app)
//   - CPU frequency set (240 MHz default)
//   - PSRAM init (not present on Heltec V3)
//   - SPI flash init and partition mapping
//   - FreeRTOS scheduler start
//
// The default task stack is 4KB (configurable in sdkconfig).
// zig_main() uses ~2KB of stack, leaving ~2KB for FreeRTOS overhead.
//
// This function runs at priority 1 (main task). The idle task
// runs at priority 0. NimBLE and WiFi create their own tasks
// at higher priorities when initialized.

void app_main(void) {
    // --- NVS Flash Initialization ---
    //
    // NVS (Non-Volatile Storage) stores:
    //   - WiFi credentials (if used)
    //   - NimBLE bond data and configuration
    //   - Calibration data (PHY, RF)
    //
    // Without NVS, NimBLE initialization will fail with
    // ESP_ERR_NVS_NOT_INITIALIZED.
    //
    // Error handling:
    //   ESP_ERR_NVS_NO_FREE_PAGES — partition is full.
    //     Erase and retry. This loses any stored WiFi passwords
    //     and BLE bonds, but the device recovers.
    //   ESP_ERR_NVS_NEW_VERSION_FOUND — firmware updated with
    //     incompatible NVS format. Erase and retry.

    esp_err_t ret = nvs_flash_init();
    if (ret == ESP_ERR_NVS_NO_FREE_PAGES || ret == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        printf("Argus: NVS full or version mismatch — erasing\n");
        nvs_flash_erase();
        ret = nvs_flash_init();
    }
    if (ret != ESP_OK) {
        printf("Argus: NVS init fatal error: %d\n", ret);
        return; // Device will watchdog-reset after idle task yields
    }

    printf("Argus Zig — booting\n");

    // --- Hand off to Zig ---
    //
    // zig_main() initializes GPIO, the display, buzzer, and
    // enters an infinite loop. This call never returns.
    //
    // If it does return (panic or logic error), the device
    // will sit idle until watchdog reset.

    zig_main();

    // unreachable
    printf("Argus Zig — zig_main returned (should not happen)\n");
}
