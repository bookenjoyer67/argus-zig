// ================================================================
// GPS NEO-6M UART driver
// ================================================================
//
// UART1 on GPIO 4 (RX from GPS TX) / GPIO 5 (TX to GPS RX).
// 9600 baud, 8N1, 256-byte RX ring buffer.
// GPS powered through Vext (always on — shared with OLED).

#include <stdio.h>
#include "driver/uart.h"

#define GPS_UART    UART_NUM_1
#define GPS_RX_PIN  4
#define GPS_TX_PIN  5
#define GPS_BAUD    9600
#define GPS_BUF_SZ  256

int gps_init(void) {
    uart_config_t cfg = {
        .baud_rate = GPS_BAUD,
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

    printf("Argus: GPS UART ready — %d baud on GPIO %d/%d\n",
           GPS_BAUD, GPS_RX_PIN, GPS_TX_PIN);
    return 0;
}

// Read available bytes from GPS UART. Non-blocking.
// Returns number of bytes read (0 if none available).
int gps_read(uint8_t *buf, int max_len) {
    int len = uart_read_bytes(GPS_UART, buf, max_len, pdMS_TO_TICKS(10));
    return (len > 0) ? len : 0;
}
