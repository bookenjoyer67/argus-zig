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
#include <string.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "nvs_flash.h"
#include "esp_system.h"
#include "driver/i2c.h"

// Defined in Zig (src/main.zig), compiled into libargus.a
extern void zig_main(void);

// ================================================================
// OLED I2C helpers — called from Zig via extern fn
// ================================================================
//
// The SSD1306 OLED on the Heltec V3 is connected to I2C port 0
// on GPIO 17 (SDA) and 18 (SCL) with address 0x3C.
//
// SSD1306 I2C protocol:
//   Write control byte 0x00 → following bytes are commands
//   Write control byte 0x40 → following bytes are display data
//
// These are simple wrappers so Zig doesn't need to marshal
// complex ESP-IDF structs across the FFI boundary.

#define OLED_I2C_PORT    I2C_NUM_0
#define OLED_I2C_ADDR    0x3C
#define OLED_I2C_FREQ    400000

// Initialize I2C master on GPIO 17/18 at 400 kHz.
// Enables internal pull-ups. Returns 0 on success, negative on error.
int oled_i2c_init(void) {
    i2c_config_t conf = {
        .mode = I2C_MODE_MASTER,
        .sda_io_num = 17,
        .scl_io_num = 18,
        .sda_pullup_en = true,
        .scl_pullup_en = true,
        .master.clk_speed = OLED_I2C_FREQ,
        .clk_flags = 0,
    };
    esp_err_t ret = i2c_param_config(OLED_I2C_PORT, &conf);
    if (ret != ESP_OK) return -1;

    ret = i2c_driver_install(OLED_I2C_PORT, I2C_MODE_MASTER, 0, 0, 0);
    if (ret != ESP_OK) return -2;

    return 0;
}

// Write bytes to SSD1306 with a prepended control byte.
// control_byte: 0x00 = command, 0x40 = data
// data, len: payload bytes
// Returns 0 on success, negative on error.
// Stack-allocates a temp buffer (max 129 bytes) — no heap usage.
int oled_i2c_write(uint8_t control_byte, const uint8_t *data, size_t len) {
    uint8_t buf[129];
    if (len > 128) return -1;
    buf[0] = control_byte;
    memcpy(buf + 1, data, len);

    esp_err_t ret = i2c_master_write_to_device(
        OLED_I2C_PORT, OLED_I2C_ADDR,
        buf, len + 1,
        pdMS_TO_TICKS(100)
    );
    return (ret == ESP_OK) ? 0 : -1;
}

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
