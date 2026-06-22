// ================================================================
// Argus — OTA updates (base HTTPS + mobile BLE)
// ================================================================
//
// Both paths write the app-only image into the inactive OTA slot, set it
// as the boot partition, and reboot. The bootloader's rollback support
// (CONFIG_BOOTLOADER_APP_ROLLBACK_ENABLE) boots the new image in
// PENDING_VERIFY; ota_mark_valid() (called from app_main after a healthy
// boot) confirms it, otherwise the bootloader rolls back on the next reset.
//
//   Base (WiFi):  ota_https_start(url) — esp_https_ota in its own task.
//   Mobile (BLE): ota_ble_begin/write/end — fed by the OTA GATT service
//                 in ble.c (the phone streams argus-zig.bin over BLE).

#include <stdio.h>
#include <string.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_system.h"
#include "esp_ota_ops.h"
#include "esp_https_ota.h"
#include "esp_http_client.h"
#include "esp_crt_bundle.h"

static volatile int g_active = 0;   // an OTA is in progress
static volatile int g_pct = -1;     // 0-100 while active, -1 idle

void ota_ble_abort(void);           // forward decl (used by ota_ble_write)

// Percent complete for the OLED progress screen (-1 = no OTA running).
int ota_progress_pct(void) { return g_pct; }
int ota_is_active(void) { return g_active; }

// Confirm the running image after a healthy boot so the bootloader won't
// roll back. No-op unless we're in the post-OTA PENDING_VERIFY state.
void ota_mark_valid(void) {
    const esp_partition_t *running = esp_ota_get_running_partition();
    esp_ota_img_states_t state;
    if (esp_ota_get_state_partition(running, &state) == ESP_OK &&
        state == ESP_OTA_IMG_PENDING_VERIFY) {
        if (esp_ota_mark_app_valid_cancel_rollback() == ESP_OK)
            printf("Argus OTA: running image marked valid\n");
    }
}

// ----------------------------------------------------------------
// Base HTTPS OTA
// ----------------------------------------------------------------

static char g_url[256];

static void ota_https_task(void *arg) {
    (void)arg;
    esp_http_client_config_t http = {
        .url = g_url,
        .crt_bundle_attach = esp_crt_bundle_attach,
        .timeout_ms = 30000,
        .keep_alive_enable = true,
    };
    esp_https_ota_config_t cfg = { .http_config = &http };
    printf("Argus OTA: HTTPS from %s\n", g_url);

    esp_https_ota_handle_t h = NULL;
    esp_err_t err = esp_https_ota_begin(&cfg, &h);
    if (err != ESP_OK) {
        printf("Argus OTA: begin failed (%d)\n", err);
        g_active = 0; g_pct = -1; vTaskDelete(NULL); return;
    }

    int total = esp_https_ota_get_image_size(h);
    while ((err = esp_https_ota_perform(h)) == ESP_ERR_HTTPS_OTA_IN_PROGRESS) {
        int got = esp_https_ota_get_image_len_read(h);
        if (total > 0) g_pct = got * 100 / total;
    }

    if (err == ESP_OK && esp_https_ota_is_complete_data_received(h) &&
        esp_https_ota_finish(h) == ESP_OK) {
        printf("Argus OTA: complete — rebooting\n");
        g_pct = 100;
        vTaskDelay(pdMS_TO_TICKS(600));
        esp_restart();
    }

    printf("Argus OTA: HTTPS failed (%d)\n", err);
    esp_https_ota_abort(h);
    g_active = 0; g_pct = -1;
    vTaskDelete(NULL);
}

// Kick off an HTTPS OTA in the background. Returns 0 if started.
int ota_https_start(const char *url) {
    if (g_active) return -1;
    strncpy(g_url, url, sizeof(g_url) - 1);
    g_url[sizeof(g_url) - 1] = '\0';
    g_active = 1; g_pct = 0;
    if (xTaskCreate(ota_https_task, "ota_https", 8192, NULL, 5, NULL) != pdPASS) {
        g_active = 0; g_pct = -1;
        return -2;
    }
    return 0;
}

// ----------------------------------------------------------------
// BLE OTA — driven chunk-by-chunk from the OTA GATT service in ble.c
// ----------------------------------------------------------------

static esp_ota_handle_t g_ble_handle;
static const esp_partition_t *g_ble_part;
static uint32_t g_ble_total, g_ble_written;

// Begin a BLE-streamed OTA of `total` bytes into the inactive slot.
int ota_ble_begin(uint32_t total) {
    if (g_active) return -1;
    g_ble_part = esp_ota_get_next_update_partition(NULL);
    if (!g_ble_part) return -2;
    if (esp_ota_begin(g_ble_part, OTA_WITH_SEQUENTIAL_WRITES, &g_ble_handle) != ESP_OK)
        return -3;
    g_ble_total = total; g_ble_written = 0;
    g_active = 1; g_pct = 0;
    printf("Argus OTA: BLE begin (%u bytes) -> %s\n",
           (unsigned)total, g_ble_part->label);
    return 0;
}

// Write one streamed chunk. Returns 0 ok, negative on error (aborts).
int ota_ble_write(const uint8_t *data, uint32_t len) {
    if (!g_active) return -1;
    if (esp_ota_write(g_ble_handle, data, len) != ESP_OK) {
        ota_ble_abort();
        return -2;
    }
    g_ble_written += len;
    if (g_ble_total > 0) g_pct = (int)(g_ble_written * 100 / g_ble_total);
    return 0;
}

// Finalize and set the boot partition. Returns 0 ok (caller reboots).
int ota_ble_end(void) {
    if (!g_active) return -1;
    esp_err_t err = esp_ota_end(g_ble_handle);
    g_active = 0;
    if (err != ESP_OK) { g_pct = -1; printf("Argus OTA: BLE end failed (%d)\n", err); return -2; }
    if (esp_ota_set_boot_partition(g_ble_part) != ESP_OK) { g_pct = -1; return -3; }
    g_pct = 100;
    printf("Argus OTA: BLE complete — boot set\n");
    return 0;
}

void ota_ble_abort(void) {
    if (g_active && g_ble_handle) esp_ota_abort(g_ble_handle);
    g_active = 0; g_pct = -1;
    printf("Argus OTA: aborted\n");
}
