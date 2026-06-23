// ================================================================
// T-Deck I2S speaker (MAX98357A) — synthesized alert tones
// ================================================================
//
// MAX98357A on I2S0: WS/LRCLK=GPIO5, BCLK=GPIO7, DOUT=GPIO6 (utilities.h).
// Behind the BOARD_POWERON (GPIO10) gate, raised by tft_init().
//
// We don't ship PCM assets — tones are square waves synthesized on the fly,
// which is plenty for a startup chime and threat beeps. Compiled into every
// build but inert unless BOARD_TDECK is defined.

#ifdef BOARD_TDECK

#include <stdint.h>
#include "driver/i2s_std.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_log.h"

#define SPK_WS    5
#define SPK_BCK   7
#define SPK_DOUT  6
#define SPK_RATE  16000

static const char *TAG = "spk";
static i2s_chan_handle_t s_tx = NULL;

int spk_init(void) {
    i2s_chan_config_t chan_cfg = I2S_CHANNEL_DEFAULT_CONFIG(I2S_NUM_0, I2S_ROLE_MASTER);
    if (i2s_new_channel(&chan_cfg, &s_tx, NULL) != ESP_OK) {
        ESP_LOGE(TAG, "i2s_new_channel failed");
        return -1;
    }
    i2s_std_config_t std_cfg = {
        .clk_cfg = I2S_STD_CLK_DEFAULT_CONFIG(SPK_RATE),
        .slot_cfg = I2S_STD_PHILIPS_SLOT_DEFAULT_CONFIG(I2S_DATA_BIT_WIDTH_16BIT, I2S_SLOT_MODE_MONO),
        .gpio_cfg = {
            .mclk = I2S_GPIO_UNUSED,
            .bclk = SPK_BCK,
            .ws = SPK_WS,
            .dout = SPK_DOUT,
            .din = I2S_GPIO_UNUSED,
            .invert_flags = { .mclk_inv = false, .bclk_inv = false, .ws_inv = false },
        },
    };
    if (i2s_channel_init_std_mode(s_tx, &std_cfg) != ESP_OK) {
        ESP_LOGE(TAG, "i2s_channel_init_std_mode failed");
        return -2;
    }
    // Channel is left DISABLED; spk_tone() enables it only while playing so an
    // idle/underrun channel doesn't loop the last DMA buffer ("won't shut up").
    ESP_LOGI(TAG, "T-Deck speaker ready (I2S0 WS%d/BCK%d/DOUT%d)", SPK_WS, SPK_BCK, SPK_DOUT);
    return 0;
}

// Play a square-wave tone: freq_hz, duration ms, vol 0-100. Blocking.
void spk_tone(int freq_hz, int ms, int vol) {
    if (!s_tx || freq_hz <= 0 || ms <= 0) return;
    if (vol < 0) vol = 0;
    if (vol > 100) vol = 100;
    i2s_channel_enable(s_tx);
    const int16_t amp = (int16_t)((vol * 9000) / 100);
    const int half = SPK_RATE / (freq_hz * 2); // samples per half-period
    const int total = (SPK_RATE * ms) / 1000;
    int16_t buf[256];
    int written = 0, phase = 0;
    int16_t level = amp;
    while (written < total) {
        int n = 0;
        while (n < 256 && written < total) {
            buf[n++] = level;
            if (++phase >= (half > 0 ? half : 1)) {
                phase = 0;
                level = (int16_t)(-level);
            }
            written++;
        }
        size_t bw = 0;
        i2s_channel_write(s_tx, buf, n * sizeof(int16_t), &bw, portMAX_DELAY);
    }
    // brief silence to settle the amp
    int16_t z[64] = {0};
    size_t bw = 0;
    i2s_channel_write(s_tx, z, sizeof(z), &bw, portMAX_DELAY);
    i2s_channel_disable(s_tx);
}

#endif // BOARD_TDECK
