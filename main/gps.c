// ================================================================
// GPS NEO-6M UART driver
// ================================================================
//
// UART1 on GPIO 4 (RX from GPS TX) / GPIO 5 (TX to GPS RX).
// 9600 baud, 8N1, 256-byte RX ring buffer.
// GPS powered through Vext (always on — shared with OLED).

#include <stdio.h>
#include <stdint.h>
#include <stdbool.h>
#include "driver/uart.h"
#include "esp_timer.h"

#ifdef BOARD_TDECK
// T-Deck Plus: built-in GPS (u-blox M10Q @ 38400 or Quectel L76K @ 9600) on
// UART1, ESP TX=GPIO43 / RX=GPIO44. Powered via the BOARD_POWERON (GPIO10) gate
// that tft_init() raises; gps_read() is polled after board.init(), so it's live.
#define GPS_UART    UART_NUM_1
#define GPS_RX_PIN  44   // ESP RX  <- GPS TX
#define GPS_TX_PIN  43   // ESP TX  -> GPS RX
// Lilygo shipped two GPS modules; probe both at runtime (primary first).
static const int GPS_BAUDS[] = { 38400, 9600 };
#else
// Heltec V3: NEO-6M on UART1, GPIO4 (RX) / GPIO5 (TX), powered via Vext.
#define GPS_UART    UART_NUM_1
#define GPS_RX_PIN  4
#define GPS_TX_PIN  5
static const int GPS_BAUDS[] = { 9600 };
#endif
#define GPS_NBAUDS  ((int)(sizeof(GPS_BAUDS) / sizeof(GPS_BAUDS[0])))
#define GPS_BUF_SZ  256
#define GPS_PROBE_MS 2500  // dwell per candidate baud before trying the next

// Runtime baud auto-detection state. The GPS is powered after gps_init()
// (T-Deck GPIO10 gate), so detection happens lazily in gps_read(): if no NMEA
// arrives at the current baud within GPS_PROBE_MS, rotate to the next candidate
// and retry. Locks on the first '$G' (any GNSS talker) seen.
static int s_baud_idx = 0;
static bool s_baud_locked = false;
static int64_t s_probe_start_ms = 0;

int gps_init(void) {
    uart_config_t cfg = {
        .baud_rate = GPS_BAUDS[0],
        .data_bits = UART_DATA_8_BITS,
        .parity = UART_PARITY_DISABLE,
        .stop_bits = UART_STOP_BITS_1,
        .flow_ctrl = UART_HW_FLOWCTRL_DISABLE,
        .source_clk = UART_SCLK_DEFAULT,
    };

    esp_err_t ret = uart_param_config(GPS_UART, &cfg);
    if (ret != ESP_OK) {
        printf("Argus: GPS UART config failed: %d\n", ret);
        return -1;
    }

    ret = uart_set_pin(GPS_UART, GPS_TX_PIN, GPS_RX_PIN,
                       UART_PIN_NO_CHANGE, UART_PIN_NO_CHANGE);
    if (ret != ESP_OK) {
        printf("Argus: GPS UART pin set failed: %d\n", ret);
        return -2;
    }

    ret = uart_driver_install(GPS_UART, GPS_BUF_SZ, 0, 0, NULL, 0);
    if (ret != ESP_OK) {
        printf("Argus: GPS UART driver install failed: %d\n", ret);
        return -3;
    }

    // Single-candidate boards (Heltec NEO-6M) never need probing.
    s_baud_idx = 0;
    s_baud_locked = (GPS_NBAUDS == 1);
    s_probe_start_ms = 0;

    printf("Argus: GPS UART ready — %d baud on GPIO %d/%d\n",
           GPS_BAUDS[0], GPS_RX_PIN, GPS_TX_PIN);
    return 0;
}

// Read available bytes from GPS UART. Non-blocking.
// Returns number of bytes read (0 if none available).
int gps_read(uint8_t *buf, int max_len) {
    int len = uart_read_bytes(GPS_UART, buf, max_len, pdMS_TO_TICKS(10));
    if (len < 0) len = 0;

    // Auto-detect the GPS baud: lock on the first NMEA start ('$G'), otherwise
    // rotate candidates every GPS_PROBE_MS until something readable arrives.
    if (!s_baud_locked) {
        int64_t now = esp_timer_get_time() / 1000;
        if (s_probe_start_ms == 0) s_probe_start_ms = now;

        for (int i = 0; i + 1 < len; i++) {
            if (buf[i] == '$' && buf[i + 1] == 'G') {
                s_baud_locked = true;
                printf("Argus: GPS locked at %d baud\n", GPS_BAUDS[s_baud_idx]);
                break;
            }
        }

        if (!s_baud_locked && (now - s_probe_start_ms) > GPS_PROBE_MS) {
            s_baud_idx = (s_baud_idx + 1) % GPS_NBAUDS;
            uart_set_baudrate(GPS_UART, GPS_BAUDS[s_baud_idx]);
            uart_flush_input(GPS_UART);
            s_probe_start_ms = now;
            printf("Argus: GPS no NMEA — trying %d baud\n", GPS_BAUDS[s_baud_idx]);
        }
    }

    return (len > 0) ? len : 0;
}
