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
#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "host/ble_hs.h"
#include "host/util/util.h"
#include "services/gap/ble_svc_gap.h"

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

// NimBLE GAP event callback — called from host task.
static int ble_gap_event_cb(struct ble_gap_event *event, void *arg) {
    if (event->type == BLE_GAP_EVENT_DISC) {
        int next = (ble_ring_write + 1) % BLE_RING_SIZE;
        if (next == ble_ring_read) return 0; // ring full — drop

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
    ble_scan_start();
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
