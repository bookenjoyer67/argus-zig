// ================================================================
// T-Deck microSD (FATFS over the shared SPI2 bus)
// ================================================================
//
// SD card CS=GPIO39, sharing SCK/MOSI/MISO (40/41/38) with the TFT and LoRa.
// The bus is brought up once by tdeck_spi_bus_init() (in tft.c); this module
// just adds the SD as a device and mounts FATFS at /sdcard.
//
// Compiled into every build but inert unless BOARD_TDECK is defined.

#ifdef BOARD_TDECK

#include <stdio.h>
#include <stdint.h>
#include "esp_vfs_fat.h"
#include "sdmmc_cmd.h"
#include "driver/sdspi_host.h"
#include "esp_log.h"

extern int tdeck_spi_bus_init(void);

#define SD_HOST_ID  SPI2_HOST
#define SD_CS       39
#define SD_MOUNT    "/sdcard"

static const char *TAG = "sd";
static sdmmc_card_t *s_card = NULL;

// Mount the microSD. Returns 0 on success, negative if no card / mount failed
// (non-fatal — the device runs fine without one).
int sd_init(void) {
    if (tdeck_spi_bus_init() != 0) return -1;

    sdmmc_host_t host = SDSPI_HOST_DEFAULT();
    host.slot = SD_HOST_ID;

    sdspi_device_config_t slot = SDSPI_DEVICE_CONFIG_DEFAULT();
    slot.gpio_cs = SD_CS;
    slot.host_id = SD_HOST_ID;

    esp_vfs_fat_sdmmc_mount_config_t mcfg = {
        .format_if_mount_failed = false,
        .max_files = 4,
        .allocation_unit_size = 16 * 1024,
    };

    esp_err_t ret = esp_vfs_fat_sdspi_mount(SD_MOUNT, &host, &slot, &mcfg, &s_card);
    if (ret != ESP_OK) {
        ESP_LOGW(TAG, "no SD card / mount failed: %s", esp_err_to_name(ret));
        s_card = NULL;
        return -2;
    }
    uint64_t mb = ((uint64_t)s_card->csd.capacity * s_card->csd.sector_size) / (1024 * 1024);
    ESP_LOGI(TAG, "SD mounted at %s (%llu MB)", SD_MOUNT, mb);
    return 0;
}

int sd_ready(void) {
    return s_card != NULL;
}

// Append "<line>\n" to /sdcard/<path>. Returns 0 on success.
int sd_append_line(const char *path, const char *line) {
    if (!s_card) return -1;
    char full[160];
    snprintf(full, sizeof(full), SD_MOUNT "/%s", path);
    FILE *f = fopen(full, "a");
    if (!f) return -2;
    fprintf(f, "%s\n", line);
    fclose(f);
    return 0;
}

// Read up to max bytes from /sdcard/<path> into buf, return bytes read.
// Returns -1 if no card, -2 if file doesn't exist.
int sd_read_file(const char *path, uint8_t *buf, size_t max) {
    if (!s_card) return -1;
    char full[160];
    snprintf(full, sizeof(full), SD_MOUNT "/%s", path);
    FILE *f = fopen(full, "r");
    if (!f) return -2;
    size_t n = fread(buf, 1, max, f);
    fclose(f);
    return (int)n;
}

#endif // BOARD_TDECK
