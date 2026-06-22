// ================================================================
// Argus — Device Configuration (flat key=value on SPIFFS)
// ================================================================
//
// Settings persist to /spiffs/config.txt as one "key=value" per line.
// A flat format avoids pulling a JSON parser into the C side, and is
// trivial to read from app_main() before the Zig runtime starts.
//
// Keys:
//   configured=0|1   — set to 1 once onboarding completes
//   name=<string>    — device display name
//   role=mobile|base — operating role
//   ssid=<string>    — home WiFi SSID (base role)
//   pass=<string>    — home WiFi password (base role)
//
// Values must not contain newlines. Everything after the first '=' on
// a line is the value (so passwords containing '=' are preserved).

#include <stdio.h>
#include <string.h>
#include <stdint.h>

// Implemented in spiffs.c
extern int spiffs_read_file(const char *path, uint8_t *buf, size_t max_len);
extern int spiffs_write_file(const char *path, const uint8_t *data, size_t len);

#define CONFIG_PATH "config.txt"
#define CONFIG_MAX  512

// Read the value for `key` into `out` (NUL-terminated). Returns value
// length on success, -1 if the key (or file) is absent.
int config_get(const char *key, char *out, int out_len) {
    if (out_len <= 0) return -1;
    out[0] = '\0';

    uint8_t buf[CONFIG_MAX];
    int n = spiffs_read_file(CONFIG_PATH, buf, sizeof(buf));
    if (n <= 0) return -1;
    buf[n] = '\0';

    size_t klen = strlen(key);
    char *line = (char *)buf;
    while (line && *line) {
        char *nl = strchr(line, '\n');
        size_t line_len = nl ? (size_t)(nl - line) : strlen(line);

        if (line_len > klen && strncmp(line, key, klen) == 0 && line[klen] == '=') {
            const char *val = line + klen + 1;
            size_t vlen = line_len - klen - 1;
            if (vlen >= (size_t)out_len) vlen = out_len - 1;
            memcpy(out, val, vlen);
            out[vlen] = '\0';
            return (int)vlen;
        }

        if (!nl) break;
        line = nl + 1;
    }
    return -1;
}

// Returns 1 when onboarding has completed, 0 otherwise.
int config_is_configured(void) {
    char v[8];
    if (config_get("configured", v, sizeof(v)) < 0) return 0;
    return (v[0] == '1') ? 1 : 0;
}

// Returns 1 if role==base, 0 otherwise (default mobile).
int config_role_is_base(void) {
    char v[8];
    if (config_get("role", v, sizeof(v)) < 0) return 0;
    return (strncmp(v, "base", 4) == 0) ? 1 : 0;
}

// Persist a complete configuration and mark the device configured.
// Returns 0 on success, negative on error.
int config_set_all(const char *name, const char *role,
                   const char *ssid, const char *pass) {
    char buf[CONFIG_MAX];
    int len = snprintf(buf, sizeof(buf),
                       "configured=1\nname=%s\nrole=%s\nssid=%s\npass=%s\n",
                       name ? name : "",
                       role ? role : "mobile",
                       ssid ? ssid : "",
                       pass ? pass : "");
    if (len <= 0 || len >= (int)sizeof(buf)) return -1;
    return spiffs_write_file(CONFIG_PATH, (const uint8_t *)buf, (size_t)len);
}
