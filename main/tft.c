// ================================================================
// T-Deck ST7789 TFT driver (320x240, SPI, via esp_lcd)
// ================================================================
//
// Compiled into every build but inert unless BOARD_TDECK is defined
// (the Heltec build never references these symbols).
//
// Pins (official Lilygo T-Deck utilities.h):
//   BOARD_POWERON = 10  (must be HIGH to power the SPI peripherals)
//   Shared SPI bus: SCK=40, MOSI=41, MISO=38
//   TFT: CS=12, DC=11, backlight=42  (no dedicated reset → soft reset)
//
// The 320x240x16-bit framebuffer lives in PSRAM. Zig (src/hal/st7789.zig)
// writes RGB565 pixels into tft_fb(); tft_flush() pushes it over SPI/DMA.

#ifdef BOARD_TDECK

#include <string.h>
#include "driver/gpio.h"
#include "driver/spi_master.h"
#include "esp_heap_caps.h"
#include "esp_lcd_panel_io.h"
#include "esp_lcd_panel_vendor.h"
#include "esp_lcd_panel_ops.h"
#include "esp_log.h"

#define TFT_HOST        SPI2_HOST
#define PIN_POWERON     10
#define PIN_SCK         40
#define PIN_MOSI        41
#define PIN_MISO        38
#define PIN_TFT_CS      12
#define PIN_TFT_DC      11
#define PIN_TFT_BL      42
#define TFT_W           320
#define TFT_H           240
#define TFT_STRIP       40   // rows per SPI flush chunk (320*40*2 = 25600 bytes)
#define TFT_PCLK_HZ     (40 * 1000 * 1000)

static const char *TAG = "tft";
static esp_lcd_panel_handle_t s_panel = NULL;
static uint16_t *s_fb = NULL;
static bool s_bus_ready = false;

// Initialize the shared SPI2 bus once (TFT + microSD + LoRa all ride it).
// Idempotent and order-independent: whichever peripheral inits first wins.
int tdeck_spi_bus_init(void) {
    if (s_bus_ready) return 0;
    spi_bus_config_t buscfg = {
        .sclk_io_num = PIN_SCK,
        .mosi_io_num = PIN_MOSI,
        .miso_io_num = PIN_MISO,
        .quadwp_io_num = -1,
        .quadhd_io_num = -1,
        .max_transfer_sz = TFT_W * TFT_STRIP * 2 + 8,
    };
    if (spi_bus_initialize(TFT_HOST, &buscfg, SPI_DMA_CH_AUTO) != ESP_OK) {
        ESP_LOGE(TAG, "spi_bus_initialize failed");
        return -1;
    }
    s_bus_ready = true;
    return 0;
}

int tft_init(void) {
    // Peripheral power gate — without this the SPI devices stay dark.
    gpio_config_t pw = {
        .pin_bit_mask = (1ULL << PIN_POWERON) | (1ULL << PIN_TFT_BL),
        .mode = GPIO_MODE_OUTPUT,
    };
    gpio_config(&pw);
    gpio_set_level(PIN_POWERON, 1);
    gpio_set_level(PIN_TFT_BL, 1);

    if (tdeck_spi_bus_init() != 0) {
        return -1;
    }

    esp_lcd_panel_io_handle_t io = NULL;
    esp_lcd_panel_io_spi_config_t io_config = {
        .dc_gpio_num = PIN_TFT_DC,
        .cs_gpio_num = PIN_TFT_CS,
        .pclk_hz = TFT_PCLK_HZ,
        .lcd_cmd_bits = 8,
        .lcd_param_bits = 8,
        .spi_mode = 0,
        .trans_queue_depth = 10,
    };
    if (esp_lcd_new_panel_io_spi((esp_lcd_spi_bus_handle_t)TFT_HOST, &io_config, &io) != ESP_OK) {
        ESP_LOGE(TAG, "new_panel_io_spi failed");
        return -2;
    }

    esp_lcd_panel_dev_config_t panel_config = {
        .reset_gpio_num = -1, // no dedicated reset pin; use soft reset
        .rgb_ele_order = LCD_RGB_ELEMENT_ORDER_RGB,
        .bits_per_pixel = 16,
    };
    if (esp_lcd_new_panel_st7789(io, &panel_config, &s_panel) != ESP_OK) {
        ESP_LOGE(TAG, "new_panel_st7789 failed");
        return -3;
    }

    esp_lcd_panel_reset(s_panel);
    esp_lcd_panel_init(s_panel);
    // ST7789 on the T-Deck needs color inversion; orientation = landscape.
    esp_lcd_panel_invert_color(s_panel, true);
    esp_lcd_panel_swap_xy(s_panel, true);
    esp_lcd_panel_mirror(s_panel, true, false);
    esp_lcd_panel_disp_on_off(s_panel, true);

    s_fb = heap_caps_malloc(TFT_W * TFT_H * 2, MALLOC_CAP_SPIRAM);
    if (!s_fb) {
        ESP_LOGE(TAG, "framebuffer PSRAM alloc failed (is SPIRAM enabled?)");
        return -4;
    }
    memset(s_fb, 0, TFT_W * TFT_H * 2);
    return 0;
}

// Pointer to the PSRAM RGB565 framebuffer (Zig writes pixels here).
uint16_t *tft_fb(void) {
    return s_fb;
}

// Push the whole framebuffer to the panel, in horizontal strips. Sending the
// full 320x240 (153 KB) in one esp_lcd_panel_draw_bitmap overflows the SPI
// transfer/queue ("spi transmit (queue) color failed"); strips stay small.
void tft_flush(void) {
    if (!s_panel || !s_fb) return;
    for (int y = 0; y < TFT_H; y += TFT_STRIP) {
        int h = (y + TFT_STRIP <= TFT_H) ? TFT_STRIP : (TFT_H - y);
        esp_lcd_panel_draw_bitmap(s_panel, 0, y, TFT_W, y + h,
                                  s_fb + (size_t)y * TFT_W);
    }
}

// Backlight on/off (used by stealth mode).
void tft_backlight(int on) {
    gpio_set_level(PIN_TFT_BL, on ? 1 : 0);
}

#endif // BOARD_TDECK
