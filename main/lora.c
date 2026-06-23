// ================================================================
// SX1262 LoRa Driver — minimal custom driver for SPI
// ================================================================
//
// Heltec V3 pinout: NSS=8, SCK=9, MOSI=10, MISO=11, RST=12, BUSY=13, DIO1=14
// Uses ESP-IDF SPI master driver on SPI2_HOST (FSPI).
// LoRa: 915 MHz (US), SF9, BW 125 kHz, CR 4/5, explicit header, CRC on.
//
// Key opcodes implemented: SetSleep, SetStandby, SetFs, SetTx, SetRx,
// SetRfFrequency, SetPacketType, SetModulationParams, SetPacketParams,
// SetDioIrqParams, SetTxParams, GetIrqStatus, ClearIrqStatus,
// WriteBuffer, ReadBuffer, GetRxBufferStatus.
//
// Polling mode: lora_poll() checks IRQ flags for RX_DONE/RX_TIMEOUT.
// No DIO1 interrupts — simpler, less code.

#include <stdio.h>
#include <string.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "driver/spi_master.h"
#include "driver/gpio.h"
#include "hal/spi_types.h"

// --- Pin definitions ---
#ifdef BOARD_TDECK
// T-Deck: SX1262 on the shared SPI2 bus (SCK40/MOSI41/MISO38), CS=9.
#define PIN_NSS   9
#define PIN_SCK  40
#define PIN_MOSI 41
#define PIN_MISO 38
#define PIN_RST  17
#define PIN_BUSY 13
#define PIN_DIO1 45
extern int tdeck_spi_bus_init(void); // shared bus init (tft.c)
#else
#define PIN_NSS   8
#define PIN_SCK   9
#define PIN_MOSI 10
#define PIN_MISO 11
#define PIN_RST  12
#define PIN_BUSY 13
#define PIN_DIO1 14
#endif

// --- SX1262 opcodes ---
#define OP_SET_SLEEP              0x84
#define OP_SET_STANDBY            0x80
#define OP_SET_FS                 0xC1
#define OP_SET_TX                 0x83
#define OP_SET_RX                 0x82
#define OP_SET_RF_FREQ            0x86
#define OP_SET_PACKET_TYPE        0x8A
#define OP_SET_MODULATION_PARAMS  0x8B
#define OP_SET_PACKET_PARAMS      0x8C
#define OP_SET_DIO_IRQ_PARAMS     0x08
#define OP_GET_IRQ_STATUS         0x12
#define OP_CLEAR_IRQ_STATUS       0x02
#define OP_WRITE_BUFFER           0x0E
#define OP_READ_BUFFER            0x1E
#define OP_GET_RX_BUFFER_STATUS   0x13
#define OP_SET_TX_PARAMS          0x8E
#define OP_SET_PA_CONFIG          0x95
#define OP_GET_PACKET_STATUS      0x14
#define OP_GET_STATUS             0xC0
#define OP_CALIBRATE              0x89
#define OP_SET_REGULATOR_MODE     0x96
#define OP_SET_DIO3_AS_TCXO_CTRL  0x97
#define OP_SET_DIO2_AS_RF_SWITCH  0x9D

// --- IRQ masks ---
#define IRQ_TX_DONE     (1 << 0)
#define IRQ_RX_DONE     (1 << 1)
#define IRQ_RX_TIMEOUT  (1 << 9)
#define IRQ_CRC_ERR     (1 << 14)

// --- Radio parameters ---
#define LORA_FREQ       915000000  // 915 MHz (US ISM band)
#define LORA_SF         9          // Spreading factor 9
#define LORA_BW         7          // 125 kHz (0=7.8, ..., 7=125)
#define LORA_CR         1          // Coding rate 4/5 (1=4/5)
#define LORA_PREAMBLE   8          // Preamble length (symbols)
#define LORA_TX_POWER   22         // +22 dBm max
#define LORA_MAX_PAYLOAD 255       // Max explicit header payload

static spi_device_handle_t spi = NULL;

// --- Low-level helpers ---

static void lora_wait_busy(void) {
    uint32_t deadline = xTaskGetTickCount() + pdMS_TO_TICKS(1000);
    while (gpio_get_level(PIN_BUSY)) {
        if (xTaskGetTickCount() > deadline) return;
        vTaskDelay(1);
    }
}

// Single SPI transaction: send tx_data, optionally receive rx_data.
// Returns 0 on success.
// Full-duplex SPI transaction. tx_len bytes sent, rx_len bytes received.
// Total clock cycles = max(tx_len, rx_len). MOSI pads with 0x00 if needed.
static int lora_spi_xfer(const uint8_t *tx_data, size_t tx_len,
                          uint8_t *rx_data, size_t rx_len) {
    lora_wait_busy();

    spi_transaction_t t = {0};
    t.length = ((tx_len > rx_len) ? tx_len : rx_len) * 8;
    t.rxlength = rx_len * 8;
    t.tx_buffer = tx_data;
    t.rx_buffer = rx_data;

    esp_err_t ret = spi_device_transmit(spi, &t);
    return (ret == ESP_OK) ? 0 : -1;
}

// Write command with N parameter bytes (no read).
static void lora_cmd(uint8_t opcode, const uint8_t *params, size_t plen) {
    uint8_t buf[1 + 32];
    buf[0] = opcode;
    if (plen > 0) memcpy(buf + 1, params, plen);
    lora_spi_xfer(buf, 1 + plen, NULL, 0);
}

// Write command and read response bytes.
// Full-duplex: [opcode, NOP, params...] → MISO returns [status_prev, status, data0...]
// rx buffer receives rx_data_len + 2 bytes. Data starts at rx[2].
static void lora_cmd_read(uint8_t opcode, const uint8_t *params, size_t plen,
                           uint8_t *rx, size_t rx_data_len) {
    uint8_t tx[3 + 32]; // opcode + NOP + params
    tx[0] = opcode;
    tx[1] = 0x00;       // RADIO_NOP — gives chip a cycle to latch read address
    if (plen > 0) memcpy(tx + 2, params, plen);
    lora_spi_xfer(tx, 2 + plen, rx, rx_data_len + 2);
}

// --- SX1262 commands ---

static void lora_set_standby(uint8_t mode) {
    uint8_t p = mode; // 0=RC, 1=XOSC
    lora_cmd(OP_SET_STANDBY, &p, 1);
}

static void lora_set_sleep(uint8_t config) {
    lora_cmd(OP_SET_SLEEP, &config, 1);
}

static void lora_set_fs(void) {
    lora_cmd(OP_SET_FS, NULL, 0);
}

static void lora_set_tx(uint32_t timeout_ms) {
    // timeout encoded as 3 bytes, each step = 15.625 us
    // timeout_ms * 64 = timeout in 15.625us units
    uint32_t t = timeout_ms * 64;
    uint8_t p[3] = { t >> 16, t >> 8, t };
    lora_cmd(OP_SET_TX, p, 3);
}

static void lora_set_rx(uint32_t timeout_ms) {
    uint32_t t = timeout_ms * 64;
    uint8_t p[3] = { t >> 16, t >> 8, t };
    lora_cmd(OP_SET_RX, p, 3);
}

// Frequency: 32MHz XTAL, PLL step = 32e6 / 2^25 = ~0.95367 Hz
static void lora_set_freq(uint32_t freq_hz) {
    uint64_t step = (uint64_t)freq_hz * 33554432ULL / 32000000ULL;
    uint8_t p[4] = { step >> 24, step >> 16, step >> 8, step };
    lora_cmd(OP_SET_RF_FREQ, p, 4);
}

static void lora_set_packet_type(uint8_t type) {
    lora_cmd(OP_SET_PACKET_TYPE, &type, 1); // 0x01 = LoRa
}

static void lora_set_modulation_params(uint8_t sf, uint8_t bw,
                                        uint8_t cr, uint8_t ldro) {
    uint8_t p[4] = { sf, bw, cr, ldro };
    lora_cmd(OP_SET_MODULATION_PARAMS, p, 4);
}

static void lora_set_packet_params(uint16_t preamble, uint8_t header_type,
                                    uint8_t payload_len, uint8_t crc_on,
                                    uint8_t invert_iq) {
    uint8_t p[6] = { preamble >> 8, preamble, header_type,
                     payload_len, crc_on, invert_iq };
    lora_cmd(OP_SET_PACKET_PARAMS, p, 6);
}

static void lora_set_dio_irq_params(uint16_t irq_mask, uint16_t dio1_mask,
                                     uint16_t dio2_mask, uint16_t dio3_mask) {
    uint8_t p[8] = { irq_mask >> 8, irq_mask,
                     dio1_mask >> 8, dio1_mask,
                     dio2_mask >> 8, dio2_mask,
                     dio3_mask >> 8, dio3_mask };
    lora_cmd(OP_SET_DIO_IRQ_PARAMS, p, 8);
}

static void lora_set_tx_params(uint8_t power, uint8_t ramp_time) {
    uint8_t p[2] = { power, ramp_time };
    lora_cmd(OP_SET_TX_PARAMS, p, 2);
}

static uint16_t lora_get_irq_status(void) {
    uint8_t rx[4]; // [status_prev, status, irq_hi, irq_lo]
    lora_cmd_read(OP_GET_IRQ_STATUS, NULL, 0, rx, 2);
    return ((uint16_t)rx[2] << 8) | rx[3];
}

static void lora_clear_irq_status(uint16_t mask) {
    uint8_t p[2] = { mask >> 8, mask };
    lora_cmd(OP_CLEAR_IRQ_STATUS, p, 2);
}

static uint8_t lora_get_status(void) {
    uint8_t rx[3]; // [status_prev, status, chip_status]
    lora_cmd_read(OP_GET_STATUS, NULL, 0, rx, 1);
    return rx[2]; // bits 7-5: mode (1=STDBY_RC, 2=STDBY_XOSC, 3=FS, 4=RX, 5=TX)
}

static uint8_t lora_get_rx_buffer_status(uint8_t *payload_len, uint8_t *rx_ptr) {
    uint8_t rx[5]; // [status_prev, status, raw, plen, ptr]
    lora_cmd_read(OP_GET_RX_BUFFER_STATUS, NULL, 0, rx, 3);
    *payload_len = rx[3];
    *rx_ptr = rx[4];
    return rx[2]; // raw status
}

static void lora_read_buffer(uint8_t offset, uint8_t *data, uint8_t len) {
    uint8_t p = offset;
    uint8_t rx[2 + 255]; // [status_prev, status, data...]
    lora_cmd_read(OP_READ_BUFFER, &p, 1, rx, len);
    memcpy(data, rx + 2, len);
}

static void lora_write_buffer(uint8_t offset, const uint8_t *data, uint8_t len) {
    uint8_t buf[2 + 255];
    buf[0] = OP_WRITE_BUFFER;
    buf[1] = offset;
    memcpy(buf + 2, data, len);
    lora_spi_xfer(buf, len + 2, NULL, 0);
}

// --- Public API ---

// Forward declaration
static void lora_calibrate(void);

int lora_init(void) {
    // Configure BUSY as input
    gpio_config_t io = {
        .pin_bit_mask = (1ULL << PIN_BUSY),
        .mode = GPIO_MODE_INPUT,
        .pull_up_en = GPIO_PULLUP_DISABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };
    gpio_config(&io);

    // Hardware reset: RST low 1ms, then release and wait for BUSY to go low
    gpio_set_direction(PIN_RST, GPIO_MODE_OUTPUT);
    gpio_set_level(PIN_RST, 0);
    vTaskDelay(pdMS_TO_TICKS(1));
    gpio_set_level(PIN_RST, 1);
    // Wait up to 2s for chip to boot (BUSY stays high during boot)
    {
        uint32_t dl = xTaskGetTickCount() + pdMS_TO_TICKS(2000);
        while (gpio_get_level(PIN_BUSY)) {
            if (xTaskGetTickCount() > dl) break;
            vTaskDelay(1);
        }
    }
    vTaskDelay(pdMS_TO_TICKS(10)); // settle

    // Initialize SPI bus — manually configure NSS as output HIGH first
    gpio_set_direction(PIN_NSS, GPIO_MODE_OUTPUT);
    gpio_set_level(PIN_NSS, 1);

    esp_err_t ret;
#ifdef BOARD_TDECK
    // Shared SPI2 bus (TFT/SD/LoRa) — already brought up by tft_init().
    if (tdeck_spi_bus_init() != 0) {
        printf("Argus: LoRa shared SPI bus init failed\n");
        return -1;
    }
#else
    spi_bus_config_t bus_cfg = {
        .mosi_io_num = PIN_MOSI,
        .miso_io_num = PIN_MISO,
        .sclk_io_num = PIN_SCK,
        .quadwp_io_num = -1,
        .quadhd_io_num = -1,
        .max_transfer_sz = 256,
    };
    ret = spi_bus_initialize(SPI2_HOST, &bus_cfg, SPI_DMA_CH_AUTO);
    if (ret != ESP_OK) {
        printf("Argus: LoRa SPI bus init failed: %d\n", ret);
        return -1;
    }
#endif

    spi_device_interface_config_t dev_cfg = {
        .mode = 0,                          // SPI mode 0
        .clock_speed_hz = 1000000,          // 1 MHz
        .spics_io_num = PIN_NSS,
        .queue_size = 1,
    };
    ret = spi_bus_add_device(SPI2_HOST, &dev_cfg, &spi);
    if (ret != ESP_OK) {
        printf("Argus: LoRa SPI device add failed: %d\n", ret);
        return -2;
    }

    // Configure SX1262 — chip is in STDBY_RC after reset
#ifdef BOARD_TDECK
    // The T-Deck's SX1262 module uses a TCXO (powered via DIO3) and routes the
    // antenna through DIO2 (RF switch) — unlike the Heltec's XTAL + HW switch.
    // Enable the TCXO and recalibrate before switching to the XOSC, otherwise
    // the radio has no stable clock and can't actually transmit/receive.
    {
        uint8_t tcxo[4] = { 0x02, 0x00, 0x01, 0x40 }; // DIO3 = 1.8V, ~5ms startup
        lora_cmd(OP_SET_DIO3_AS_TCXO_CTRL, tcxo, 4);
        uint8_t rfsw = 0x01;
        lora_cmd(OP_SET_DIO2_AS_RF_SWITCH, &rfsw, 1);
        lora_calibrate(); // recalibrate all blocks after enabling the TCXO
        vTaskDelay(pdMS_TO_TICKS(20));
    }
#endif
    lora_set_standby(0x01);  // standby with XOSC
    vTaskDelay(pdMS_TO_TICKS(10));
    lora_set_packet_type(0x01);      // LoRa mode
    lora_set_freq(LORA_FREQ);
    lora_set_modulation_params(LORA_SF, LORA_BW, LORA_CR, 0); // ldro off for SF9
    lora_set_packet_params(LORA_PREAMBLE,
                           0x00,     // explicit header
                           LORA_MAX_PAYLOAD,
                           0x01,     // CRC on
                           0x00);    // standard IQ

    // DIO1: route TX_DONE and RX_DONE to DIO1
    lora_set_dio_irq_params(IRQ_TX_DONE | IRQ_RX_DONE,
                             IRQ_TX_DONE | IRQ_RX_DONE, 0, 0);

    // DCDC regulator mode (better efficiency)
    uint8_t reg = 0x01;
    lora_cmd(OP_SET_REGULATOR_MODE, &reg, 1);

    // High-power PA config: must precede SetTxParams
    uint8_t pa_cfg[4] = { 0x04, 0x07, 0x00, 0x01 };
    lora_cmd(OP_SET_PA_CONFIG, pa_cfg, 4);

    // TX power 22 dBm, ramp 200us
    lora_set_tx_params(LORA_TX_POWER, 0x04);

    // Calibrate
    lora_calibrate();

    // Start listening
    lora_set_rx(0);  // 0 = continuous RX

    printf("Argus: LoRa SX1262 ready — %d MHz SF%d\n", LORA_FREQ / 1000000, LORA_SF);
    return 0;
}

// Send a packet. Blocks until TX complete (or timeout).
// max 255 bytes payload. Returns 0 on success.
// NOTE: BUSY pin stuck low on this hardware — TX succeeds ~50% of calls.
// Timeout kept short (2s) to minimize main loop blocking.
int lora_send(const uint8_t *data, uint8_t len) {
    if (len > 255) return -1;
    if (!spi) return -2;

    lora_set_standby(0x01);
    vTaskDelay(pdMS_TO_TICKS(10));

    lora_clear_irq_status(0xFFFF);
    vTaskDelay(pdMS_TO_TICKS(10));

    lora_write_buffer(0x00, data, len);
    vTaskDelay(pdMS_TO_TICKS(10));
    lora_set_packet_params(LORA_PREAMBLE, 0x00, len, 0x01, 0x00);
    vTaskDelay(pdMS_TO_TICKS(10));

    lora_set_tx(2000); // 2s timeout
    vTaskDelay(pdMS_TO_TICKS(5));

    uint32_t deadline = xTaskGetTickCount() + pdMS_TO_TICKS(2000);
    while (xTaskGetTickCount() < deadline) {
        uint16_t irq = lora_get_irq_status();
        if (irq & IRQ_TX_DONE) {
            lora_clear_irq_status(IRQ_TX_DONE);
            lora_set_rx(0);
            return 0;
        }
        vTaskDelay(pdMS_TO_TICKS(50));
    }

    lora_set_rx(0);
    return -3;
}

// Check for received packet. Returns length (1-255) if data available, 0 if none.
// buf must be at least 255 bytes.
int lora_poll_receive(uint8_t *buf) {
    if (!spi) return 0;

    uint16_t irq = lora_get_irq_status();

    if (irq & IRQ_RX_DONE) {
        lora_clear_irq_status(IRQ_RX_DONE | IRQ_RX_TIMEOUT);
        uint8_t len, ptr;
        lora_get_rx_buffer_status(&len, &ptr);
        if (len > 0) {
            lora_read_buffer(ptr, buf, len);
        }
        lora_set_rx(0);  // restart RX
        return len;
    }

    if (irq & IRQ_RX_TIMEOUT) {
        lora_clear_irq_status(IRQ_RX_TIMEOUT);
        lora_set_rx(0);
    }

    return 0;
}

// RSSI (dBm) of the most recently received packet, via GetPacketStatus.
// LoRa response: [RssiPkt, SnrPkt, SignalRssiPkt]; dBm = -RssiPkt/2.
int lora_last_rssi(void) {
    if (!spi) return 0;
    uint8_t rx[5]; // [status_prev, status, RssiPkt, SnrPkt, SignalRssiPkt]
    lora_cmd_read(OP_GET_PACKET_STATUS, NULL, 0, rx, 3);
    return -((int)rx[2]) / 2;
}

static void lora_calibrate(void) {
    uint8_t p = 0x7F; // calibrate all blocks
    lora_cmd(OP_CALIBRATE, &p, 1);
    lora_wait_busy(); // calibration takes time
}
