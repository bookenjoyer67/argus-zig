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

#define WIFI_RING_SIZE 128

struct wifi_scan_result {
    uint8_t addr[6];       // transmitter MAC (addr2)
    uint8_t receiver[6];   // receiver MAC (addr1)
    int8_t rssi;
    uint8_t channel;
    uint8_t frame_type;    // hi nibble=type (0=mgmt,2=data), lo nibble=subtype (4=probe_req)
    uint8_t ssid_len;
    uint8_t ssid[32];
    uint8_t rid_len;       // Remote ID payload length (tag 221 ASTM)
    uint8_t rid[128];      // Remote ID payload
};

static struct wifi_scan_result wifi_ring[WIFI_RING_SIZE];
static volatile int wifi_ring_write = 0;
static volatile int wifi_ring_read = 0;
static volatile uint32_t wifi_total_frames = 0;
static volatile uint32_t wifi_filtered_frames = 0;
static volatile uint32_t wifi_ring_dropped = 0;

// Push a result into the ring buffer. Called from WiFi callback
// (runs in WiFi task context). Drops if full.
static void wifi_ring_push(const struct wifi_scan_result *r) {
    int next = (wifi_ring_write + 1) % WIFI_RING_SIZE;
    if (next == wifi_ring_read) {
        wifi_ring_dropped++;
        return;
    }

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
    uint8_t fc_type = (frame_ctrl >> 2) & 0x03;      // bits 2-3
    uint8_t fc_subtype = (frame_ctrl >> 4) & 0x0F; // bits 4-7

    struct wifi_scan_result r;
    memset(&r, 0, sizeof(r));

    // Address fields: addr1 at offset 4, addr2 at offset 10
    memcpy(r.receiver, frame + 4, 6);
    memcpy(r.addr, frame + 10, 6);
    r.rssi = pkt->rx_ctrl.rssi;
    if (r.rssi < -95) return;   // drop noise frames below RSSI floor
    r.channel = pkt->rx_ctrl.channel;
    r.frame_type = (fc_type << 4) | fc_subtype;
    r.ssid_len = 0;

    // Filter out multicast/broadcast transmitters (addr2 byte 0, bit 0 = group)
    // Filter out randomized MACs (addr2 byte 0, bit 1 = locally administered)
    if (r.addr[0] & 0x03) return; // multicast or randomized

    wifi_total_frames++;
    wifi_filtered_frames++;

    // Parse management frames (probe requests, beacons, etc.)
    // for SSID and Remote ID information elements
    if (fc_type == 0 && sig_len > 25) {
        const uint8_t *body = frame + 24;
        uint16_t body_len = sig_len - 24;
        uint16_t pos = 0;

        while (pos + 2 <= body_len) {
            uint8_t ie_tag = body[pos];
            uint8_t ie_len = body[pos + 1];
            pos += 2;
            if (pos + ie_len > body_len) break;

            if (ie_tag == 0x00 && ie_len <= 32) {
                r.ssid_len = ie_len;
                memcpy(r.ssid, body + pos, ie_len);
            }

            // Tag 221: Vendor Specific IE — ASTM Remote ID
            if (ie_tag == 221 && ie_len >= 3) {
                // Check OUI: ASTM Remote ID uses 3C:EB:FE or 3C:EB:FF
                if (body[pos] == 0x3C && body[pos+1] == 0xEB &&
                    (body[pos+2] == 0xFE || body[pos+2] == 0xFF)) {
                    uint8_t rid_payload_len = ie_len - 3;
                    if (rid_payload_len > 128) rid_payload_len = 128;
                    r.rid_len = rid_payload_len;
                    memcpy(r.rid, body + pos + 3, rid_payload_len);
                }
            }
            pos += ie_len;
        }

        // FCS trailer retry: some ESP32 driver versions include the 4-byte FCS
        // trailer in sig_len, shifting IEs by 4 bytes. Retry with body_len-4.
        if (r.ssid_len == 0 && body_len > 4) {
            uint16_t pos2 = 0;
            uint16_t retry_len = body_len - 4;
            while (pos2 + 2 <= retry_len) {
                uint8_t ie_tag = body[pos2];
                uint8_t ie_len = body[pos2 + 1];
                pos2 += 2;
                if (pos2 + ie_len > retry_len) break;
                if (ie_tag == 0x00 && ie_len <= 32) {
                    r.ssid_len = ie_len;
                    memcpy(r.ssid, body + pos2, ie_len);
                    break;
                }
                pos2 += ie_len;
            }
        }
    }

    wifi_ring_push(&r);
}

// ----------------------------------------------------------------
// Shared init + AP / STA modes (added for onboarding + dashboard)
// ----------------------------------------------------------------
//
// esp_netif_init / event loop / esp_wifi_init must run exactly once.
// The setup flow uses AP mode (Layer 1); normal operation uses STA
// promiscuous, with the base-station role additionally connecting to
// home WiFi (Layer 2). Promiscuous capture coexists with a connected
// STA on the connected channel.

static bool wifi_base_inited = false;
static esp_netif_t *wifi_netif_sta = NULL;
static esp_netif_t *wifi_netif_ap = NULL;

static esp_err_t wifi_common_init(void) {
    if (wifi_base_inited) return ESP_OK;
    esp_netif_init();
    esp_event_loop_create_default();
    wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
    esp_err_t ret = esp_wifi_init(&cfg);
    if (ret != ESP_OK) {
        printf("Argus: WiFi init failed: %d\n", ret);
        return ret;
    }
    wifi_base_inited = true;
    return ESP_OK;
}

// Start an open access point (no password) for the setup captive page.
// DHCP server runs on 192.168.4.x; the setup UI lives at 192.168.4.1.
int wifi_ap_start(const char *ssid) {
    if (wifi_common_init() != ESP_OK) return -1;
    if (!wifi_netif_ap) wifi_netif_ap = esp_netif_create_default_wifi_ap();

    if (esp_wifi_set_mode(WIFI_MODE_AP) != ESP_OK) return -2;

    wifi_config_t ap = {0};
    size_t n = strlen(ssid);
    if (n > sizeof(ap.ap.ssid)) n = sizeof(ap.ap.ssid);
    memcpy(ap.ap.ssid, ssid, n);
    ap.ap.ssid_len = n;
    ap.ap.channel = 1;
    ap.ap.max_connection = 4;
    ap.ap.authmode = WIFI_AUTH_OPEN;

    if (esp_wifi_set_config(WIFI_IF_AP, &ap) != ESP_OK) return -3;
    if (esp_wifi_start() != ESP_OK) return -4;
    printf("Argus: WiFi AP '%s' started (192.168.4.1)\n", ssid);
    return 0;
}

int wifi_ap_stop(void) {
    esp_wifi_stop();
    return 0;
}

// STA event handler — retries association and logs the assigned IP.
static void wifi_sta_event(void *arg, esp_event_base_t base,
                           int32_t id, void *data) {
    (void)arg;
    if (base == WIFI_EVENT && id == WIFI_EVENT_STA_START) {
        esp_wifi_connect();
    } else if (base == WIFI_EVENT && id == WIFI_EVENT_STA_DISCONNECTED) {
        esp_wifi_connect();
    } else if (base == IP_EVENT && id == IP_EVENT_STA_GOT_IP) {
        ip_event_got_ip_t *e = (ip_event_got_ip_t *)data;
        printf("Argus: dashboard at http://" IPSTR "\n", IP2STR(&e->ip_info.ip));
    }
}

// Connect to home WiFi for base-station dashboard mode. The promiscuous
// sniffer (started by wifi_scan_init) keeps running on the connected channel.
int wifi_connect_sta(const char *ssid, const char *password) {
    if (!wifi_netif_sta) wifi_netif_sta = esp_netif_create_default_wifi_sta();

    esp_event_handler_instance_register(WIFI_EVENT, ESP_EVENT_ANY_ID,
                                         &wifi_sta_event, NULL, NULL);
    esp_event_handler_instance_register(IP_EVENT, IP_EVENT_STA_GOT_IP,
                                         &wifi_sta_event, NULL, NULL);

    wifi_config_t sta = {0};
    strncpy((char *)sta.sta.ssid, ssid, sizeof(sta.sta.ssid) - 1);
    strncpy((char *)sta.sta.password, password, sizeof(sta.sta.password) - 1);

    if (esp_wifi_set_config(WIFI_IF_STA, &sta) != ESP_OK) return -1;
    if (esp_wifi_connect() != ESP_OK) return -2;
    printf("Argus: connecting to home WiFi '%s'\n", ssid);
    return 0;
}

// Initialize WiFi in station-only promiscuous mode.
// Returns 0 on success, negative on error.
int wifi_scan_init(void) {
    if (wifi_common_init() != ESP_OK) return -1;
    if (!wifi_netif_sta) wifi_netif_sta = esp_netif_create_default_wifi_sta();

    esp_err_t ret = esp_wifi_set_mode(WIFI_MODE_STA);
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
                   uint8_t *ssid_out, uint8_t *ssid_len_out,
                   uint8_t *rid_out, uint8_t *rid_len_out) {
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
    *rid_len_out = r->rid_len;
    if (r->rid_len > 0) {
        memcpy(rid_out, r->rid, r->rid_len);
    }

    wifi_ring_read = (wifi_ring_read + 1) % WIFI_RING_SIZE;
    return 1;
}

// Return total WiFi frames captured (for diagnostics).
uint32_t wifi_get_frame_count(void) {
    return wifi_total_frames;
}

// Return count of frames dropped due to ring buffer overflow.
uint32_t wifi_get_dropped_count(void) {
    return wifi_ring_dropped;
}

// Retune the promiscuous sniffer to a specific 802.11 channel.
// Called from the Zig main loop's channel-hop scheduler (mobile role only).
// Base-station role leaves the radio on the STA-connected channel and
// never calls this. Returns the esp_err_t (0 = ESP_OK).
int wifi_set_channel(uint8_t ch) {
    return esp_wifi_set_channel(ch, WIFI_SECOND_CHAN_NONE);
}
