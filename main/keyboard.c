// ================================================================
// T-Deck I2C keyboard driver
// ================================================================
//
// The T-Deck's keyboard is a separate onboard ESP32-C3 running its own
// firmware, exposed as an I2C slave at 0x55 on SDA=18 / SCL=8. Reading one
// byte returns the ASCII of the most recent keypress (0x00 if none).
//
// Compiled into every build but inert unless BOARD_TDECK is defined.
// The keyboard MCU is behind the BOARD_POWERON (GPIO10) gate, which tft_init()
// drives HIGH before kbd_init() runs.

#ifdef BOARD_TDECK

#include "driver/i2c.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#define KBD_I2C_PORT  I2C_NUM_0
#define KBD_SDA       18
#define KBD_SCL       8
#define KBD_ADDR      0x55
#define KBD_FREQ      100000

static const char *TAG = "kbd";
static int s_ready = 0;

int kbd_init(void) {
    i2c_config_t conf = {
        .mode = I2C_MODE_MASTER,
        .sda_io_num = KBD_SDA,
        .scl_io_num = KBD_SCL,
        .sda_pullup_en = GPIO_PULLUP_ENABLE,
        .scl_pullup_en = GPIO_PULLUP_ENABLE,
        .master.clk_speed = KBD_FREQ,
        .clk_flags = 0,
    };
    if (i2c_param_config(KBD_I2C_PORT, &conf) != ESP_OK) {
        ESP_LOGE(TAG, "i2c_param_config failed");
        return -1;
    }
    if (i2c_driver_install(KBD_I2C_PORT, I2C_MODE_MASTER, 0, 0, 0) != ESP_OK) {
        ESP_LOGE(TAG, "i2c_driver_install failed");
        return -2;
    }
    s_ready = 1;
    ESP_LOGI(TAG, "T-Deck keyboard ready (0x%02X on SDA%d/SCL%d)", KBD_ADDR, KBD_SDA, KBD_SCL);
    return 0;
}

// Returns the pressed key's ASCII (0 if none / not ready / bus error).
int kbd_read(void) {
    if (!s_ready) return 0;
    uint8_t key = 0;
    esp_err_t r = i2c_master_read_from_device(KBD_I2C_PORT, KBD_ADDR, &key, 1,
                                              pdMS_TO_TICKS(20));
    if (r != ESP_OK) return 0;
    return (int)key;
}

#endif // BOARD_TDECK
