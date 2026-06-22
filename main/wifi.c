// ================================================================
// WiFi Sniffer — Promiscuous mode 802.11 frame capture
// ================================================================
//
// Initializes WiFi in station-only promiscuous mode. A callback
// receives raw 802.11 frames. We extract addr1/addr2, RSSI,
// channel, and probe request SSIDs. Results are pushed to a
// lock-free ring buffer. Zig's main loop drains it via wifi_scan_poll().
//
// Filter: management frames (probe requests) + data frames.
// No connections — pure passive sniffer.

#include <stdio.h>
#include <string.h>
#include "esp_wifi.h"
#include "esp_netif.h"
#include "esp_event.h"

#define WIFI_RING_SIZE 64

struct wifi_scan_result {
    uint8_t addr[6];       // transmitter MAC (addr2)
    uint8_t receiver[6];   // receiver MAC (addr1)
    int8_t rssi;
    uint8_t channel;
    uint8_t frame_type;    // 0=mgmt, 2=data
    uint8_t ssid_len;
    uint8_t ssid[32];
};

static struct wifi_scan_result wifi_ring[WIFI_RING_SIZE];
static volatile int wifi_ring_write = 0;
static volatile int wifi_ring_read = 0;
static volatile uint32_t wifi_total_frames = 0;
static volatile uint32_t wifi_filtered_frames = 0;

// Push a result into the ring buffer. Called from WiFi callback
// (runs in WiFi task context). Drops if full.
static void wifi_ring_push(const struct wifi_scan_result *r) {
    int next = (wifi_ring_write + 1) % WIFI_RING_SIZE;
    if (next == wifi_ring_read) return;

    memcpy(&wifi_ring[wifi_ring_write], r, sizeof(*r));
    wifi_ring_write = next;
}

// WiFi promiscuous callback — receives raw 802.11 frames.
static void wifi_sniffer_cb(void *buf, wifi_promiscuous_pkt_type_t type) {
    wifi_promiscuous_pkt_t *pkt = (wifi_promiscuous_pkt_t *)buf;
    const uint8_t *frame = pkt->payload;
    uint16_t sig_len = pkt->rx_ctrl.sig_len;

    // Need at least 24 bytes for a basic 802.11 header
    if (sig_len < 24) return;

    // 802.11 Frame Control field (first 2 bytes)
    uint16_t frame_ctrl = frame[0] | (frame[1] << 8);
    uint8_t fc_type = (frame_ctrl >> 2) & 0x03;   // bits 2-3
    uint8_t fc_subtype = (frame_ctrl >> 4) & 0x0F; // bits 4-7

    struct wifi_scan_result r;
    memset(&r, 0, sizeof(r));

    // Address fields: addr1 at offset 4, addr2 at offset 10
    memcpy(r.receiver, frame + 4, 6);
    memcpy(r.addr, frame + 10, 6);
    r.rssi = pkt->rx_ctrl.rssi;
    r.channel = pkt->rx_ctrl.channel;
    r.frame_type = fc_type;
    r.ssid_len = 0;

    // Filter out multicast/broadcast transmitters (addr2 byte 0, bit 0 = group)
    // Filter out randomized MACs (addr2 byte 0, bit 1 = locally administered)
    if (r.addr[0] & 0x03) return; // multicast or randomized

    wifi_total_frames++;
    wifi_filtered_frames++;

    // Parse management frames for probe requests (type=0, subtype=4)
    if (fc_type == 0 && fc_subtype == 4 && sig_len > 25) {
        // Probe request body starts after 24-byte header
        const uint8_t *body = frame + 24;
        uint16_t body_len = sig_len - 24;
        uint16_t pos = 0;

        while (pos + 2 <= body_len) {
            uint8_t ie_tag = body[pos];
            uint8_t ie_len = body[pos + 1];
            pos += 2;
            if (pos + ie_len > body_len) break;

            if (ie_tag == 0x00 && ie_len > 0 && ie_len <= 32) {
                // SSID IE
                r.ssid_len = ie_len;
                memcpy(r.ssid, body + pos, ie_len);
                break;
            }
            pos += ie_len;
        }
    }

    wifi_ring_push(&r);
}

// Initialize WiFi in station-only promiscuous mode.
// Returns 0 on success, negative on error.
int wifi_scan_init(void) {
    // Init network interface + event loop
    esp_netif_init();
    esp_event_loop_create_default();
    esp_netif_create_default_wifi_sta();

    wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
    esp_err_t ret = esp_wifi_init(&cfg);
    if (ret != ESP_OK) {
        printf("Argus: WiFi init failed: %d\n", ret);
        return -1;
    }

    ret = esp_wifi_set_mode(WIFI_MODE_STA);
    if (ret != ESP_OK) {
        printf("Argus: WiFi set mode failed: %d\n", ret);
        return -2;
    }

    ret = esp_wifi_start();
    if (ret != ESP_OK) {
        printf("Argus: WiFi start failed: %d\n", ret);
        return -3;
    }

    // Configure promiscuous mode
    esp_wifi_set_promiscuous_rx_cb(wifi_sniffer_cb);

    wifi_promiscuous_filter_t filter = {
        .filter_mask = WIFI_PROMIS_FILTER_MASK_MGMT | WIFI_PROMIS_FILTER_MASK_DATA,
    };
    esp_wifi_set_promiscuous_filter(&filter);

    esp_wifi_set_promiscuous(true);
    printf("Argus: WiFi promiscuous sniffer started\n");
    return 0;
}

// Poll for the next WiFi scan result (called from Zig main loop).
// Returns 1 and fills *out if a result is available, 0 if empty.
int wifi_scan_poll(uint8_t *addr_out, uint8_t *receiver_out,
                   int8_t *rssi_out, uint8_t *channel_out,
                   uint8_t *frame_type_out,
                   uint8_t *ssid_out, uint8_t *ssid_len_out) {
    if (wifi_ring_read == wifi_ring_write) return 0;

    struct wifi_scan_result *r = &wifi_ring[wifi_ring_read];
    memcpy(addr_out, r->addr, 6);
    memcpy(receiver_out, r->receiver, 6);
    *rssi_out = r->rssi;
    *channel_out = r->channel;
    *frame_type_out = r->frame_type;
    *ssid_len_out = r->ssid_len;
    if (r->ssid_len > 0) {
        memcpy(ssid_out, r->ssid, r->ssid_len);
    }

    wifi_ring_read = (wifi_ring_read + 1) % WIFI_RING_SIZE;
    return 1;
}

// Return total WiFi frames captured (for diagnostics).
uint32_t wifi_get_frame_count(void) {
    return wifi_total_frames;
}
