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
#include "driver/i2c.h"

// Defined in Zig (src/main.zig), compiled into libargus.a
extern void zig_main(void);

// Defined in ble.c
extern int ble_scan_init(void);

// Defined in wifi.c
extern int wifi_scan_init(void);

// Defined in spiffs.c
extern int spiffs_init_storage(void);

// Defined in lora.c
extern int lora_init(void);

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
#define OLED_I2C_FREQ    100000  // 100 kHz — reliable with internal pull-ups (~45kΩ)

// Initialize I2C master on GPIO 17 (SDA) and 18 (SCL).
// Internal pull-ups are required — this board revision has no
// external I2C pull-up resistors.
// The OLED is powered through Vext (GPIO 36), enabled from Zig.
// Returns 0 on success, negative on error.
int oled_i2c_init(void) {
    i2c_config_t conf = {
        .mode = I2C_MODE_MASTER,
        .sda_io_num = 17,
        .scl_io_num = 18,
        .sda_pullup_en = true,    // board needs internal pull-ups (no external resistors detected)
        .scl_pullup_en = true,
        .master.clk_speed = OLED_I2C_FREQ,
        .clk_flags = 0,
    };
    esp_err_t ret = i2c_param_config(OLED_I2C_PORT, &conf);
    if (ret != ESP_OK) {
        printf("Argus: I2C param_config failed: %d\n", ret);
        return -1;
    }

    ret = i2c_driver_install(OLED_I2C_PORT, I2C_MODE_MASTER, 0, 0, 0);
    if (ret != ESP_OK) {
        printf("Argus: I2C driver_install failed: %d\n", ret);
        return -2;
    }

    // Quick probe at expected address. ESP-IDF task watchdog fires
    // if we block >5s without yielding. Skipping full bus scan.
    uint8_t probe_byte = 0x00;
    ret = i2c_master_write_to_device(OLED_I2C_PORT, OLED_I2C_ADDR, &probe_byte, 1, pdMS_TO_TICKS(200));
    if (ret == ESP_OK) {
        printf("Argus: OLED found at 0x%02X\n", OLED_I2C_ADDR);
    } else {
        printf("Argus: OLED probe at 0x%02X FAILED: %d\n", OLED_I2C_ADDR, ret);
        return -3;
    }

    return 0;
}

// Write bytes to SSD1306 with a prepended control byte.
// Uses i2c_cmd_link API — no heap allocation, no stack buffer.
// control_byte: 0x00 = command, 0x40 = data
int oled_i2c_write(uint8_t control_byte, const uint8_t *data, size_t len) {
    i2c_cmd_handle_t cmd = i2c_cmd_link_create();
    if (!cmd) return -1;

    i2c_master_start(cmd);
    i2c_master_write_byte(cmd, (OLED_I2C_ADDR << 1) | I2C_MASTER_WRITE, true);
    i2c_master_write_byte(cmd, control_byte, true);
    if (len > 0) {
        i2c_master_write(cmd, data, len, true);
    }
    i2c_master_stop(cmd);

    esp_err_t ret = i2c_master_cmd_begin(OLED_I2C_PORT, cmd, pdMS_TO_TICKS(100));
    i2c_cmd_link_delete(cmd);

    if (ret != ESP_OK) {
        printf("Argus: I2C write ctrl=0x%02X len=%d FAILED: %d\n", control_byte, (int)len, ret);
    }
    return (ret == ESP_OK) ? 0 : -1;
}

// ================================================================
// GPIO pin init — single C wrapper replaces 4 extern fns
// ================================================================
//
// ESP-IDF v5.4 inlines gpio_set_pull_mode/gpio_set_direction in
// headers, leaving dangling symbols that GNU ld resolves to unrelated
// internal functions (see gpio_set_pull_mode(273) error at boot).
//
// gpio_config() is a real, non-inlined ABI symbol. One call configures
// direction, pull resistors, and interrupts in a single shot.
//
// mode: 0=INPUT, 1=OUTPUT
// pull: 0=NONE, 1=UP, 2=DOWN

#include "driver/gpio.h"

int gpio_pin_init(int pin, int mode, int pull) {
    gpio_config_t cfg = {
        .pin_bit_mask = (1ULL << pin),
        .mode = (mode == 1) ? GPIO_MODE_OUTPUT : GPIO_MODE_INPUT,
        .pull_up_en = (pull == 1) ? GPIO_PULLUP_ENABLE : GPIO_PULLUP_DISABLE,
        .pull_down_en = (pull == 2) ? GPIO_PULLDOWN_ENABLE : GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };
    return gpio_config(&cfg);
}

// Set GPIO output level. level: 0=LOW, 1=HIGH.
int gpio_write(int pin, int level) {
    return gpio_set_level(pin, level);
}

int gpio_read(int pin) {
    return gpio_get_level(pin);
}

// ================================================================
// Battery ADC — GPIO 1, 390k/100k voltage divider
// ================================================================
//
// The Heltec V3 has a VBAT voltage divider: 390kΩ upper, 100kΩ lower.
// ADC reads at 12-bit resolution (0-4095) with 11dB attenuation
// (full-scale ~3.3V). Returns battery voltage in millivolts.

#include "driver/adc.h"

int battery_read_mv(void) {
    adc1_config_width(ADC_WIDTH_BIT_12);
    adc1_config_channel_atten(ADC1_CHANNEL_1, ADC_ATTEN_DB_11);
    int raw = adc1_get_raw(ADC1_CHANNEL_1);
    // Divider ratio: (390k + 100k) / 100k = 4.9
    // mV = raw * 3300 / 4095 * 490 / 100
    return raw * 3300 / 4095 * 490 / 100;
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

    // --- Start BLE and WiFi scanning ---
    // NimBLE and WiFi promiscuous mode start in their own tasks.
    // Results are pushed to ring buffers, polled from zig_main().
    ble_scan_init();
    wifi_scan_init();

    // --- Mount SPIFFS for detection logging ---
    // CSV log at /spiffs/detections.csv, session counter at /spiffs/session.dat
    spiffs_init_storage();

    // --- Initialize LoRa radio for mesh networking ---
    lora_init();

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
