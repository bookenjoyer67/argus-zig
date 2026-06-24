// ================================================================
// BLE Scanner — NimBLE passive scanning with ring buffer
// ================================================================
//
// Isolated from main.c so NimBLE headers don't pollute simple wrappers.
// NimBLE runs in its own FreeRTOS task. The GAP event callback
// pushes simplified scan results into a lock-free ring buffer.
// Zig's main loop drains the buffer via ble_scan_poll().
//
// Passive scan only — no scan requests, no connections.
// Filter duplicates: each MAC is reported once per scan session.

#include <stdio.h>
#include <string.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_random.h"
#include "esp_system.h"
#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "host/ble_hs.h"
#include "host/ble_gatt.h"
#include "host/ble_att.h"
#include "host/ble_uuid.h"
#include "host/util/util.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"

// NimBLE NVS-backed bond/key store initializer (store/config module).
// Declared here to avoid pulling the deeply-nested store header.
extern void ble_store_config_init(void);

#define BLE_RING_SIZE 64

struct ble_scan_result {
    uint8_t addr[6];
    int8_t rssi;
    uint8_t adv_type;
    uint8_t data_len;
    uint8_t data[31];
};

static struct ble_scan_result ble_ring[BLE_RING_SIZE];
static volatile int ble_ring_write = 0;
static volatile int ble_ring_read = 0;
static volatile int ble_ring_dropped = 0;

// NimBLE GAP event callback — called from host task.
static int ble_gap_event_cb(struct ble_gap_event *event, void *arg) {
    if (event->type == BLE_GAP_EVENT_DISC) {
        int next = (ble_ring_write + 1) % BLE_RING_SIZE;
        if (next == ble_ring_read) { ble_ring_dropped++; return 0; } // ring full — drop

        struct ble_scan_result *r = &ble_ring[ble_ring_write];
        memcpy(r->addr, event->disc.addr.val, 6);
        r->rssi = event->disc.rssi;
        r->adv_type = event->disc.event_type;
        r->data_len = event->disc.length_data;
        if (r->data_len > 31) r->data_len = 31;
        memcpy(r->data, event->disc.data, r->data_len);

        ble_ring_write = next;
    }
    return 0;
}

// ================================================================
// GATT PERIPHERAL — Nordic UART Service (NUS) stream to a phone
// ================================================================
//
// Runs concurrently with the passive observer scan above. A phone
// (Web Bluetooth / BLE app) connects, pairs (passkey shown on the
// OLED), subscribes to the TX characteristic, and receives newline-
// framed JSON pushed by the Zig main loop. Commands arrive via RX.
//
// Advertising uses a neutral name; the client matches by the NUS
// service UUID so the advertisement doesn't reveal a detector.

// NUS 128-bit UUIDs (bytes are little-endian, i.e. reversed form).
// Service 6E400001-B5A3-F393-E0A9-E50E24DCCA9E
static const ble_uuid128_t nus_svc_uuid = BLE_UUID128_INIT(
    0x9e, 0xca, 0xdc, 0x24, 0x0e, 0xe5, 0xa9, 0xe0,
    0x93, 0xf3, 0xa3, 0xb5, 0x01, 0x00, 0x40, 0x6e);
// RX (write, phone->device) 6E400002-...
static const ble_uuid128_t nus_rx_uuid = BLE_UUID128_INIT(
    0x9e, 0xca, 0xdc, 0x24, 0x0e, 0xe5, 0xa9, 0xe0,
    0x93, 0xf3, 0xa3, 0xb5, 0x02, 0x00, 0x40, 0x6e);
// TX (notify, device->phone) 6E400003-...
static const ble_uuid128_t nus_tx_uuid = BLE_UUID128_INIT(
    0x9e, 0xca, 0xdc, 0x24, 0x0e, 0xe5, 0xa9, 0xe0,
    0x93, 0xf3, 0xa3, 0xb5, 0x03, 0x00, 0x40, 0x6e);

static uint16_t g_tx_val_handle;
static uint16_t g_conn_handle = BLE_HS_CONN_HANDLE_NONE;
static volatile int g_subscribed = 0;     // TX CCCD enabled
static volatile int g_secure = 0;          // link encrypted (paired)
static volatile uint32_t g_passkey = 0;    // 6-digit code to show on OLED
static volatile int g_passkey_pending = 0;
static int g_adv_enabled = 1;              // cleared by stealth mode
static char g_rx_cmd[64];
static volatile int g_rx_pending = 0;
static uint8_t g_own_addr_type;

// RX write callback — stash the phone's command for the main loop.
static int nus_access_cb(uint16_t conn_handle, uint16_t attr_handle,
                         struct ble_gatt_access_ctxt *ctxt, void *arg) {
    (void)conn_handle; (void)attr_handle; (void)arg;
    if (ctxt->op == BLE_GATT_ACCESS_OP_WRITE_CHR) {
        uint16_t len = OS_MBUF_PKTLEN(ctxt->om);
        if (len >= sizeof(g_rx_cmd)) len = sizeof(g_rx_cmd) - 1;
        ble_hs_mbuf_to_flat(ctxt->om, g_rx_cmd, len, NULL);
        g_rx_cmd[len] = '\0';
        g_rx_pending = 1;
        return 0;
    }
    return BLE_ATT_ERR_UNLIKELY;
}

// ---- OTA-over-BLE: stream argus-zig.bin into the inactive slot ----
// ota.c owns the esp_ota_* state machine; these chars feed it.
extern int ota_ble_begin(uint32_t total);
extern int ota_ble_write(const uint8_t *data, uint32_t len);
extern int ota_ble_end(void);
extern void ota_ble_abort(void);
extern int ota_progress_pct(void);

// OTA service e3a40001-... (control/data require an encrypted+authed link).
static const ble_uuid128_t ota_svc_uuid = BLE_UUID128_INIT(
    0x9e, 0xca, 0xdc, 0x24, 0x0e, 0xe5, 0xa9, 0xe0,
    0x93, 0xf3, 0xa3, 0xb5, 0x01, 0x00, 0xa4, 0xe3);
static const ble_uuid128_t ota_ctrl_uuid = BLE_UUID128_INIT(
    0x9e, 0xca, 0xdc, 0x24, 0x0e, 0xe5, 0xa9, 0xe0,
    0x93, 0xf3, 0xa3, 0xb5, 0x02, 0x00, 0xa4, 0xe3);
static const ble_uuid128_t ota_data_uuid = BLE_UUID128_INIT(
    0x9e, 0xca, 0xdc, 0x24, 0x0e, 0xe5, 0xa9, 0xe0,
    0x93, 0xf3, 0xa3, 0xb5, 0x03, 0x00, 0xa4, 0xe3);
static const ble_uuid128_t ota_status_uuid = BLE_UUID128_INIT(
    0x9e, 0xca, 0xdc, 0x24, 0x0e, 0xe5, 0xa9, 0xe0,
    0x93, 0xf3, 0xa3, 0xb5, 0x04, 0x00, 0xa4, 0xe3);

static uint16_t g_ota_status_handle;
static uint8_t g_ota_last_pct;

static int ota_ctrl_cb(uint16_t conn_handle, uint16_t attr_handle,
                       struct ble_gatt_access_ctxt *ctxt, void *arg);
static int ota_data_cb(uint16_t conn_handle, uint16_t attr_handle,
                       struct ble_gatt_access_ctxt *ctxt, void *arg);

static const struct ble_gatt_svc_def gatt_svcs[] = {
    {
        .type = BLE_GATT_SVC_TYPE_PRIMARY,
        .uuid = &nus_svc_uuid.u,
        .characteristics = (struct ble_gatt_chr_def[]){
            {
                .uuid = &nus_rx_uuid.u,
                .access_cb = nus_access_cb,
                .flags = BLE_GATT_CHR_F_WRITE | BLE_GATT_CHR_F_WRITE_ENC |
                         BLE_GATT_CHR_F_WRITE_AUTHEN,
            },
            {
                .uuid = &nus_tx_uuid.u,
                .access_cb = nus_access_cb,
                .flags = BLE_GATT_CHR_F_NOTIFY,
                .val_handle = &g_tx_val_handle,
            },
            { 0 },
        },
    },
    {
        .type = BLE_GATT_SVC_TYPE_PRIMARY,
        .uuid = &ota_svc_uuid.u,
        .characteristics = (struct ble_gatt_chr_def[]){
            {
                .uuid = &ota_ctrl_uuid.u,
                .access_cb = ota_ctrl_cb,
                .flags = BLE_GATT_CHR_F_WRITE | BLE_GATT_CHR_F_WRITE_ENC |
                         BLE_GATT_CHR_F_WRITE_AUTHEN,
            },
            {
                .uuid = &ota_data_uuid.u,
                .access_cb = ota_data_cb,
                .flags = BLE_GATT_CHR_F_WRITE | BLE_GATT_CHR_F_WRITE_ENC |
                         BLE_GATT_CHR_F_WRITE_AUTHEN,
            },
            {
                .uuid = &ota_status_uuid.u,
                .access_cb = ota_ctrl_cb,
                .flags = BLE_GATT_CHR_F_NOTIFY,
                .val_handle = &g_ota_status_handle,
            },
            { 0 },
        },
    },
    { 0 },
};

static int ble_periph_gap_event(struct ble_gap_event *event, void *arg);

// Notify the phone of OTA status: code 0=progress, 1=done, 2=error; pct 0-100.
static void ota_notify(uint8_t code, uint8_t pct) {
    if (g_conn_handle == BLE_HS_CONN_HANDLE_NONE) return;
    uint8_t buf[2] = { code, pct };
    struct os_mbuf *om = ble_hs_mbuf_from_flat(buf, sizeof(buf));
    if (om) ble_gatts_notify_custom(g_conn_handle, g_ota_status_handle, om);
}

static void ota_reboot_task(void *arg) {
    (void)arg;
    vTaskDelay(pdMS_TO_TICKS(800)); // let the notify flush
    esp_restart();
}

// OTA control: [0x01][size LE32] = START, [0x02] = END, [0x03] = ABORT.
static int ota_ctrl_cb(uint16_t conn_handle, uint16_t attr_handle,
                       struct ble_gatt_access_ctxt *ctxt, void *arg) {
    (void)conn_handle; (void)attr_handle; (void)arg;
    if (ctxt->op != BLE_GATT_ACCESS_OP_WRITE_CHR) return 0;
    uint8_t b[8] = {0};
    uint16_t len = OS_MBUF_PKTLEN(ctxt->om);
    if (len > sizeof(b)) len = sizeof(b);
    ble_hs_mbuf_to_flat(ctxt->om, b, len, NULL);
    if (len < 1) return 0;

    if (b[0] == 0x01 && len >= 5) {
        uint32_t total = (uint32_t)b[1] | ((uint32_t)b[2] << 8) |
                         ((uint32_t)b[3] << 16) | ((uint32_t)b[4] << 24);
        g_ota_last_pct = 0;
        ota_notify(ota_ble_begin(total) == 0 ? 0 : 2, 0);
    } else if (b[0] == 0x02) {
        int rc = ota_ble_end();
        ota_notify(rc == 0 ? 1 : 2, rc == 0 ? 100 : 0);
        if (rc == 0) xTaskCreate(ota_reboot_task, "ota_rb", 2048, NULL, 5, NULL);
    } else if (b[0] == 0x03) {
        ota_ble_abort();
        ota_notify(2, 0);
    }
    return 0;
}

// OTA data: each write is one chunk streamed into the inactive slot.
static int ota_data_cb(uint16_t conn_handle, uint16_t attr_handle,
                       struct ble_gatt_access_ctxt *ctxt, void *arg) {
    (void)conn_handle; (void)attr_handle; (void)arg;
    if (ctxt->op != BLE_GATT_ACCESS_OP_WRITE_CHR) return 0;
    static uint8_t chunk[512];
    uint16_t len = OS_MBUF_PKTLEN(ctxt->om);
    if (len > sizeof(chunk)) len = sizeof(chunk);
    ble_hs_mbuf_to_flat(ctxt->om, chunk, len, NULL);
    if (ota_ble_write(chunk, len) != 0) { ota_notify(2, 0); return 0; }
    int p = ota_progress_pct();
    if (p >= 0 && (uint8_t)p >= g_ota_last_pct + 5) {
        g_ota_last_pct = (uint8_t)p;
        ota_notify(0, (uint8_t)p);
    }
    return 0;
}


// (Re)start connectable advertising with the NUS UUID + neutral name.
static void ble_advertise(void) {
    if (!g_adv_enabled) return;

    struct ble_hs_adv_fields fields;
    memset(&fields, 0, sizeof(fields));
    fields.flags = BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP;
    fields.uuids128 = (ble_uuid128_t[]){ nus_svc_uuid };
    fields.num_uuids128 = 1;
    fields.uuids128_is_complete = 1;
    ble_gap_adv_set_fields(&fields);

    // Neutral name in the scan response — no "Argus" branding.
    struct ble_hs_adv_fields rsp;
    memset(&rsp, 0, sizeof(rsp));
    const char *name = ble_svc_gap_device_name();
    rsp.name = (uint8_t *)name;
    rsp.name_len = strlen(name);
    rsp.name_is_complete = 1;
    ble_gap_adv_rsp_set_fields(&rsp);

    struct ble_gap_adv_params advp;
    memset(&advp, 0, sizeof(advp));
    advp.conn_mode = BLE_GAP_CONN_MODE_UND;
    advp.disc_mode = BLE_GAP_DISC_MODE_GEN;
    int rc = ble_gap_adv_start(g_own_addr_type, NULL, BLE_HS_FOREVER,
                               &advp, ble_periph_gap_event, NULL);
    if (rc != 0 && rc != BLE_HS_EALREADY) {
        printf("Argus: BLE adv start failed: %d\n", rc);
    }
}

// GAP events for the peripheral/connection (separate from the disc scan cb).
static int ble_periph_gap_event(struct ble_gap_event *event, void *arg) {
    (void)arg;
    switch (event->type) {
    case BLE_GAP_EVENT_CONNECT:
        if (event->connect.status == 0) {
            g_conn_handle = event->connect.conn_handle;
            // Force pairing immediately (passkey flow follows).
            ble_gap_security_initiate(g_conn_handle);
            // Relax the connection interval so the passive scan keeps
            // radio time while a phone is connected (200-400ms, latency 4).
            struct ble_gap_upd_params up = {
                .itvl_min = 160, .itvl_max = 320,
                .latency = 4, .supervision_timeout = 400,
            };
            ble_gap_update_params(g_conn_handle, &up);
        } else {
            ble_advertise();
        }
        return 0;
    case BLE_GAP_EVENT_DISCONNECT:
        g_conn_handle = BLE_HS_CONN_HANDLE_NONE;
        g_subscribed = 0;
        g_secure = 0;
        g_passkey_pending = 0;
        ble_advertise();
        return 0;
    case BLE_GAP_EVENT_ENC_CHANGE:
        g_secure = (event->enc_change.status == 0) ? 1 : 0;
        g_passkey_pending = 0;
        return 0;
    case BLE_GAP_EVENT_SUBSCRIBE:
        if (event->subscribe.attr_handle == g_tx_val_handle) {
            g_subscribed = event->subscribe.cur_notify;
        }
        return 0;
    case BLE_GAP_EVENT_PASSKEY_ACTION:
        if (event->passkey.params.action == BLE_SM_IOACT_DISP) {
            struct ble_sm_io io = {0};
            io.action = BLE_SM_IOACT_DISP;
            io.passkey = esp_random() % 1000000;
            g_passkey = io.passkey;
            g_passkey_pending = 1;
            ble_sm_inject_io(event->passkey.conn_handle, &io);
        }
        return 0;
    default:
        return 0;
    }
}

// ---- Exports consumed by the Zig main loop ----

int ble_gatt_is_connected(void) {
    return g_conn_handle != BLE_HS_CONN_HANDLE_NONE;
}

// True only when a phone is subscribed AND the link is encrypted (paired).
int ble_gatt_is_subscribed(void) {
    return g_subscribed && g_secure;
}

// If a passkey is waiting to be shown, write it to *out and return 1.
int ble_gatt_take_passkey(uint32_t *out) {
    if (g_passkey_pending) { *out = g_passkey; return 1; }
    return 0;
}

// Pull a pending command written by the phone. Returns length, 0 if none.
int ble_gatt_get_request(char *out, int max) {
    if (!g_rx_pending) return 0;
    int n = (int)strlen(g_rx_cmd);
    if (n >= max) n = max - 1;
    memcpy(out, g_rx_cmd, n);
    out[n] = '\0';
    g_rx_pending = 0;
    return n;
}

// Send a buffer to the phone, chunked into MTU-sized notifications.
// Paced so the NimBLE mbuf pool can drain. Returns 0 ok, -1 if not ready.
int ble_gatt_send(const uint8_t *buf, uint32_t len) {
    if (g_conn_handle == BLE_HS_CONN_HANDLE_NONE || !g_subscribed || !g_secure)
        return -1;

    uint16_t mtu = ble_att_mtu(g_conn_handle);
    uint16_t chunk = (mtu > 3) ? (uint16_t)(mtu - 3) : 20;
    if (chunk > 180) chunk = 180;

    uint32_t off = 0;
    while (off < len) {
        uint16_t n = (len - off > chunk) ? chunk : (uint16_t)(len - off);
        struct os_mbuf *om = ble_hs_mbuf_from_flat(buf + off, n);
        if (!om) { vTaskDelay(pdMS_TO_TICKS(20)); continue; } // pool empty — back off
        // notify_custom consumes om on both success and failure.
        ble_gatts_notify_custom(g_conn_handle, g_tx_val_handle, om);
        off += n;
        vTaskDelay(pdMS_TO_TICKS(8)); // pace to let buffers drain
    }
    return 0;
}

// Toggle advertising (stealth mode stops advertising; keeps any existing
// encrypted connection alive so the phone can still receive silently).
int ble_gatt_set_enabled(int on) {
    g_adv_enabled = on;
    if (on) {
        ble_advertise();
    } else {
        ble_gap_adv_stop();
        // Keep the connection — encrypted and already paired, it doesn't
        // leak presence. The phone continues receiving the stream silently.
    }
    return 0;
}

// Start continuous passive BLE scanning.
static void ble_scan_start(void) {
    uint8_t own_addr_type;
    int rc = ble_hs_id_infer_auto(0, &own_addr_type);
    if (rc != 0) return;

    struct ble_gap_disc_params disc_params = {
        .itvl = 0,
        .window = 0,
        .filter_policy = 0,
        .limited = 0,
        .passive = 1,
        .filter_duplicates = 1,
    };

    rc = ble_gap_disc(own_addr_type, BLE_HS_FOREVER, &disc_params,
                      ble_gap_event_cb, NULL);
    if (rc == 0) {
        printf("Argus: BLE passive scan started\n");
    } else {
        printf("Argus: BLE scan start failed: %d\n", rc);
    }
}

// Called when NimBLE host synchronizes with controller.
static void ble_on_sync(void) {
    ble_hs_util_ensure_addr(0);
    ble_hs_id_infer_auto(0, &g_own_addr_type);
    ble_scan_start();   // passive observer
    ble_advertise();    // NUS peripheral
}

// Called on NimBLE host reset.
static void ble_on_reset(int reason) {
    printf("Argus: BLE host reset (reason=%d)\n", reason);
}

// NimBLE host task — runs nimble_port_run() forever.
static void ble_host_task(void *param) {
    printf("Argus: BLE host task started\n");
    nimble_port_run();
    nimble_port_freertos_deinit();
}

// Initialize NimBLE and start BLE scanning.
// Returns 0 on success, negative on error.
int ble_scan_init(void) {
    esp_err_t ret = nimble_port_init();
    if (ret != ESP_OK) {
        printf("Argus: NimBLE port init failed: %d\n", ret);
        return -1;
    }

    ble_hs_cfg.reset_cb = ble_on_reset;
    ble_hs_cfg.sync_cb = ble_on_sync;
    ble_hs_cfg.store_status_cb = ble_store_util_status_rr;

    // Pairing: Secure Connections + MITM, device displays a passkey on the
    // OLED (IO capability DISPLAY_ONLY), bonds persisted to NVS.
    ble_hs_cfg.sm_io_cap = BLE_HS_IO_DISPLAY_ONLY;
    ble_hs_cfg.sm_bonding = 1;
    ble_hs_cfg.sm_mitm = 1;
    ble_hs_cfg.sm_sc = 1;
    ble_hs_cfg.sm_our_key_dist = BLE_SM_PAIR_KEY_DIST_ENC | BLE_SM_PAIR_KEY_DIST_ID;
    ble_hs_cfg.sm_their_key_dist = BLE_SM_PAIR_KEY_DIST_ENC | BLE_SM_PAIR_KEY_DIST_ID;

    // Register the GAP/GATT base services + the NUS stream service.
    ble_svc_gap_init();
    ble_svc_gatt_init();
    int rc = ble_gatts_count_cfg(gatt_svcs);
    if (rc == 0) rc = ble_gatts_add_svcs(gatt_svcs);
    if (rc != 0) printf("Argus: GATT register failed: %d\n", rc);

    // Neutral, non-identifying advertised name. The client matches by UUID.
    ble_svc_gap_device_name_set("sensor-7a3");

    // NVS-backed key store so paired phones reconnect after reboot.
    ble_store_config_init();

    nimble_port_freertos_init(ble_host_task);
    return 0;
}

// Poll for the next BLE scan result (called from Zig main loop).
// Returns 1 and fills *out if a result is available, 0 if empty.
int ble_scan_poll(uint8_t *addr_out, int8_t *rssi_out,
                  uint8_t *adv_type_out, uint8_t *data_out,
                  uint8_t *data_len_out) {
    if (ble_ring_read == ble_ring_write) return 0;

    struct ble_scan_result *r = &ble_ring[ble_ring_read];
    memcpy(addr_out, r->addr, 6);
    *rssi_out = r->rssi;
    *adv_type_out = r->adv_type;
    *data_len_out = r->data_len;
    memcpy(data_out, r->data, r->data_len);

    ble_ring_read = (ble_ring_read + 1) % BLE_RING_SIZE;
    return 1;
}

int ble_scan_dropped(void) {
    return ble_ring_dropped;
}
