// ================================================================
// SPIFFS Persistence — CSV detection log + session counters
// ================================================================
//
// Mounts a 1MB SPIFFS partition at /spiffs. Detection events are
// appended to /spiffs/detections.csv. Session counters are saved
// to /spiffs/session.dat on request and restored on boot.
//
// Uses standard C file API (fopen/fwrite/fclose) — newlib links
// these against the SPIFFS VFS layer registered by esp_vfs_spiffs.

#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include "esp_spiffs.h"

static bool spiffs_ready = false;

// Mount the SPIFFS partition. Formats on first boot.
// Returns 0 on success, negative on error.
int spiffs_init_storage(void) {
    esp_vfs_spiffs_conf_t conf = {
        .base_path = "/spiffs",
        .partition_label = "storage",
        .max_files = 5,
        .format_if_mount_failed = true,
    };

    esp_err_t ret = esp_vfs_spiffs_register(&conf);
    if (ret != ESP_OK) {
        printf("Argus: SPIFFS mount failed: %d\n", ret);
        return -1;
    }

    // Check usage
    size_t total = 0, used = 0;
    ret = esp_spiffs_info(conf.partition_label, &total, &used);
    if (ret == ESP_OK) {
        printf("Argus: SPIFFS ready — %d/%d KB used\n", (int)(used / 1024), (int)(total / 1024));
    }

    spiffs_ready = true;
    return 0;
}

// Append a string line to a file. Returns 0 on success, negative on error.
int spiffs_append_line(const char *path, const char *line) {
    if (!spiffs_ready) return -1;

    char full[64];
    snprintf(full, sizeof(full), "/spiffs/%s", path);

    FILE *f = fopen(full, "a");
    if (!f) return -1;

    fputs(line, f);
    fclose(f);
    return 0;
}

// Dump the contents of a file to stdout (for USB serial export).
// Returns 0 on success, negative on error.
int spiffs_dump_file(const char *path) {
    if (!spiffs_ready) return -1;

    char full[64];
    snprintf(full, sizeof(full), "/spiffs/%s", path);

    FILE *f = fopen(full, "r");
    if (!f) {
        printf("Argus: file not found: %s\n", full);
        return -1;
    }

    char buf[256];
    while (fgets(buf, sizeof(buf), f)) {
        printf("%s", buf);
    }
    fclose(f);
    return 0;
}

// Read file contents into a buffer. Returns bytes read, or -1 on error.
int spiffs_read_file(const char *path, uint8_t *buf, size_t max_len) {
    if (!spiffs_ready) return -1;

    char full[64];
    snprintf(full, sizeof(full), "/spiffs/%s", path);

    FILE *f = fopen(full, "r");
    if (!f) return -1;

    size_t n = fread(buf, 1, max_len - 1, f);
    buf[n] = '\0';
    fclose(f);
    return (int)n;
}

// Write raw data to a file (overwrites, not appends).
int spiffs_write_file(const char *path, const uint8_t *data, size_t len) {
    if (!spiffs_ready) return -1;

    char full[64];
    snprintf(full, sizeof(full), "/spiffs/%s", path);

    FILE *f = fopen(full, "w");
    if (!f) return -1;

    size_t written = fwrite(data, 1, len, f);
    fclose(f);
    return (written == len) ? 0 : -1;
}

// Dump CSV log with header/footer banners over serial.
// Called from Zig on long button press.
void spiffs_csv_export(void) {
    printf("--- DETECTIONS CSV ---\n");

    char full[64];
    snprintf(full, sizeof(full), "/spiffs/detections.csv");

    FILE *f = fopen(full, "r");
    if (f) {
        char buf[256];
        while (fgets(buf, sizeof(buf), f)) {
            printf("%s", buf);
        }
        fclose(f);
    }

    printf("--- END ---\n");
}

// Rotate CSV log when it exceeds ~512 KB: detections.csv → detections.1.csv → detections.2.csv
// Returns 1 if rotated, 0 if no rotation needed.
int spiffs_csv_rotate(void) {
    if (!spiffs_ready) return 0;

    struct stat st;
    if (stat("/spiffs/detections.csv", &st) != 0) return 0;
    if (st.st_size < (512 * 1024)) return 0;

    remove("/spiffs/detections.2.csv");
    rename("/spiffs/detections.1.csv", "/spiffs/detections.2.csv");
    rename("/spiffs/detections.csv", "/spiffs/detections.1.csv");
    printf("Argus: CSV rotated (was %d KB)\n", (int)(st.st_size / 1024));
    return 1;
}

// Delete the CSV file to start fresh. Returns 0 on success.
int spiffs_clear_csv(void) {
    if (!spiffs_ready) return -1;

    char full[64];
    snprintf(full, sizeof(full), "/spiffs/detections.csv");

    if (remove(full) == 0) {
        printf("Argus: CSV cleared\n");
        return 0;
    }
    printf("Argus: CSV clear failed (no file?)\n");
    return -1;
}
