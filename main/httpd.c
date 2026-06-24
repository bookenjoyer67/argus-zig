// ================================================================
// Argus — HTTP server (onboarding captive page + dashboard API)
// ================================================================
//
// Uses ESP-IDF's esp_http_server. Two roles:
//   Setup (Layer 1):  GET /  serves the onboarding form,
//                     POST /api/setup saves config and reboots.
//   Dashboard (Layer 2): GET / serves the dashboard, plus a JSON API.
//
// All detection state lives in Zig (tracker table, counts, mesh peers),
// so the JSON bodies are rendered by exported Zig functions; the handlers
// here just relay the bytes. The HTML pages are embedded via the
// EMBED_TXTFILES directive in CMakeLists.txt (NUL-terminated).

#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include "esp_http_server.h"
#include "esp_system.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

// Embedded web assets (EMBED_TXTFILES — NUL terminated)
extern const char setup_html_start[]     asm("_binary_setup_html_start");
extern const char dashboard_html_start[] asm("_binary_dashboard_html_start");

// JSON renderers implemented in Zig (src/api.zig). Each writes into buf
// and returns the number of bytes written.
extern uint32_t zig_api_status(uint8_t *buf, uint32_t max);
extern uint32_t zig_api_detections(uint8_t *buf, uint32_t max);
extern uint32_t zig_api_mesh(uint8_t *buf, uint32_t max);
extern uint32_t zig_api_cameras(uint8_t *buf, uint32_t max);
extern uint32_t zig_api_config(uint8_t *buf, uint32_t max);
extern uint32_t zig_api_history(uint8_t *buf, uint32_t max);

// Config persistence (main/config.c)
extern int config_set_all(const char *name, const char *role,
                          const char *ssid, const char *pass,
                          const char *lat, const char *lon);
extern int config_set_location(const char *lat, const char *lon);
extern int config_get(const char *key, char *out, int out_len);
extern int config_is_configured(void);

// OTA (main/ota.c) — start a background HTTPS update.
extern int ota_https_start(const char *url);

// App image hosted alongside the web flasher on GitHub Pages.
#define OTA_DEFAULT_URL "https://bookenjoyer67.github.io/argus-zig/web/firmware/argus-zig.bin"

static httpd_handle_t server = NULL;

// Shared scratch buffer for JSON rendering. The esp_http_server runs a
// single worker task by default, so handlers never run concurrently and
// one static buffer is safe. 8 KB covers a full 64-entry detection list.
static uint8_t json_buf[8192];

// ----------------------------------------------------------------
// x-www-form-urlencoded field extraction (avoids a JSON parser in C)
// ----------------------------------------------------------------

static int hexval(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

// Find key in a urlencoded body and url-decode its value into out.
// Returns value length, or -1 if the key is absent.
static int form_field(const char *body, const char *key, char *out, int out_len) {
    size_t klen = strlen(key);
    const char *p = body;
    while (p && *p) {
        const char *eq = strchr(p, '=');
        if (!eq) break;
        if ((size_t)(eq - p) == klen && strncmp(p, key, klen) == 0) {
            const char *v = eq + 1;
            int o = 0;
            while (*v && *v != '&' && o < out_len - 1) {
                if (*v == '%' && hexval(v[1]) >= 0 && hexval(v[2]) >= 0) {
                    out[o++] = (char)((hexval(v[1]) << 4) | hexval(v[2]));
                    v += 3;
                } else if (*v == '+') {
                    out[o++] = ' ';
                    v++;
                } else {
                    out[o++] = *v++;
                }
            }
            out[o] = '\0';
            return o;
        }
        const char *amp = strchr(eq, '&');
        if (!amp) break;
        p = amp + 1;
    }
    out[0] = '\0';
    return -1;
}

// ----------------------------------------------------------------
// Handlers
// ----------------------------------------------------------------

static esp_err_t h_setup_page(httpd_req_t *req) {
    httpd_resp_set_type(req, "text/html");
    return httpd_resp_sendstr(req, setup_html_start);
}

static esp_err_t h_dashboard_page(httpd_req_t *req) {
    httpd_resp_set_type(req, "text/html");
    return httpd_resp_sendstr(req, dashboard_html_start);
}

static esp_err_t read_body(httpd_req_t *req, char *buf, int buf_len) {
    int total = req->content_len;
    if (total >= buf_len) total = buf_len - 1;
    int got = 0;
    while (got < total) {
        int r = httpd_req_recv(req, buf + got, total - got);
        if (r <= 0) return ESP_FAIL;
        got += r;
    }
    buf[got] = '\0';
    return ESP_OK;
}

static esp_err_t h_setup_save(httpd_req_t *req) {
    char body[512];
    if (read_body(req, body, sizeof(body)) != ESP_OK) {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "bad body");
        return ESP_FAIL;
    }

    char name[33] = {0}, role[8] = {0}, ssid[33] = {0}, pass[65] = {0};
    char lat[16] = {0}, lon[16] = {0};
    form_field(body, "name", name, sizeof(name));
    form_field(body, "role", role, sizeof(role));
    form_field(body, "ssid", ssid, sizeof(ssid));
    form_field(body, "pass", pass, sizeof(pass));
    form_field(body, "lat", lat, sizeof(lat));
    form_field(body, "lon", lon, sizeof(lon));
    if (role[0] == '\0') strcpy(role, "mobile");

    config_set_all(name, role, ssid, pass, lat, lon);

    httpd_resp_set_type(req, "application/json");
    httpd_resp_sendstr(req, "{\"ok\":true}");

    // Give the response time to flush, then reboot into normal operation.
    vTaskDelay(pdMS_TO_TICKS(800));
    esp_restart();
    return ESP_OK;
}

static esp_err_t send_json_from_zig(httpd_req_t *req,
                                    uint32_t (*render)(uint8_t *, uint32_t)) {
    uint32_t n = render(json_buf, sizeof(json_buf));
    httpd_resp_set_type(req, "application/json");
    return httpd_resp_send(req, (const char *)json_buf, n);
}

static esp_err_t h_status(httpd_req_t *req)     { return send_json_from_zig(req, zig_api_status); }
static esp_err_t h_detections(httpd_req_t *req) { return send_json_from_zig(req, zig_api_detections); }
static esp_err_t h_mesh(httpd_req_t *req)       { return send_json_from_zig(req, zig_api_mesh); }
static esp_err_t h_cameras(httpd_req_t *req)    { return send_json_from_zig(req, zig_api_cameras); }
static esp_err_t h_history(httpd_req_t *req)    { return send_json_from_zig(req, zig_api_history); }
static esp_err_t h_config_get(httpd_req_t *req) { return send_json_from_zig(req, zig_api_config); }

static esp_err_t h_config_set(httpd_req_t *req) {
    char body[512];
    if (read_body(req, body, sizeof(body)) != ESP_OK) {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "bad body");
        return ESP_FAIL;
    }
    char name[33] = {0}, role[8] = {0}, ssid[33] = {0}, pass[65] = {0};
    char lat[16] = {0}, lon[16] = {0};
    form_field(body, "name", name, sizeof(name));
    form_field(body, "role", role, sizeof(role));
    form_field(body, "ssid", ssid, sizeof(ssid));
    form_field(body, "pass", pass, sizeof(pass));
    if (role[0] == '\0') strcpy(role, "mobile");
    // Preserve the stored map location unless the request overrides it.
    if (form_field(body, "lat", lat, sizeof(lat)) < 0)
        config_get("lat", lat, sizeof(lat));
    if (form_field(body, "lon", lon, sizeof(lon)) < 0)
        config_get("lon", lon, sizeof(lon));
    config_set_all(name, role, ssid, pass, lat, lon);
    httpd_resp_set_type(req, "application/json");
    return httpd_resp_sendstr(req, "{\"ok\":true}");
}

static esp_err_t h_location_set(httpd_req_t *req) {
    char body[128];
    if (read_body(req, body, sizeof(body)) != ESP_OK) {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "bad body");
        return ESP_FAIL;
    }
    char lat[16] = {0}, lon[16] = {0};
    form_field(body, "lat", lat, sizeof(lat));
    form_field(body, "lon", lon, sizeof(lon));
    config_set_location(lat, lon);
    httpd_resp_set_type(req, "application/json");
    return httpd_resp_sendstr(req, "{\"ok\":true}");
}

static esp_err_t h_ota(httpd_req_t *req) {
    int rc = ota_https_start(OTA_DEFAULT_URL);
    httpd_resp_set_type(req, "application/json");
    return httpd_resp_sendstr(req, rc == 0 ? "{\"ok\":true}" : "{\"ok\":false}");
}

static esp_err_t h_export_csv(httpd_req_t *req) {
    httpd_resp_set_type(req, "text/csv");
    httpd_resp_set_hdr(req, "Content-Disposition",
                       "attachment; filename=\"argus-detections.csv\"");
    FILE *f = fopen("/spiffs/detections.csv", "r");
    if (!f) return httpd_resp_send(req, "", 0);
    char chunk[256];
    size_t n;
    while ((n = fread(chunk, 1, sizeof(chunk), f)) > 0) {
        if (httpd_resp_send_chunk(req, chunk, n) != ESP_OK) {
            fclose(f);
            return ESP_FAIL;
        }
    }
    fclose(f);
    return httpd_resp_send_chunk(req, NULL, 0);
}

// ----------------------------------------------------------------
// Server lifecycle
// ----------------------------------------------------------------

static void register_uri(const char *uri, httpd_method_t method,
                         esp_err_t (*handler)(httpd_req_t *)) {
    httpd_uri_t u = { .uri = uri, .method = method, .handler = handler, .user_ctx = NULL };
    httpd_register_uri_handler(server, &u);
}

// setup_mode != 0 → onboarding (only / and /api/setup).
// setup_mode == 0 → dashboard (/, API, CSV, config).
int httpd_start_server(int setup_mode) {
    if (server) return 0;
    httpd_config_t cfg = HTTPD_DEFAULT_CONFIG();
    cfg.max_uri_handlers = 16;
    cfg.lru_purge_enable = true;
    if (httpd_start(&server, &cfg) != ESP_OK) {
        printf("Argus: httpd start failed\n");
        return -1;
    }

    if (setup_mode) {
        register_uri("/", HTTP_GET, h_setup_page);
        register_uri("/api/setup", HTTP_POST, h_setup_save);
    } else {
        register_uri("/", HTTP_GET, h_dashboard_page);
        register_uri("/api/status", HTTP_GET, h_status);
        register_uri("/api/detections", HTTP_GET, h_detections);
        register_uri("/api/mesh", HTTP_GET, h_mesh);
        register_uri("/api/cameras", HTTP_GET, h_cameras);
        register_uri("/api/history", HTTP_GET, h_history);
        register_uri("/api/export/csv", HTTP_GET, h_export_csv);
        register_uri("/api/config", HTTP_GET, h_config_get);
        register_uri("/api/config", HTTP_POST, h_config_set);
        register_uri("/api/location", HTTP_POST, h_location_set);
        register_uri("/api/ota", HTTP_POST, h_ota);
    }
    printf("Argus: httpd started (%s)\n", setup_mode ? "setup" : "dashboard");
    return 0;
}

int httpd_stop_server(void) {
    if (server) {
        httpd_stop(server);
        server = NULL;
    }
    return 0;
}
