# LoRa Mesh Diagnostic Plan

Author: Hermes  
Date: 2026-06-22  
Status: not started  

## Symptom

Heltec V3 and T-Deck both print "LoRa SX1262 ready" at boot. Neither device
receives heartbeats or detection packets from the other. Web dashboard and
OLED show zero mesh peers. Total radio silence in both directions.

## Root cause hypothesis

The SX1262 BUSY pin (GPIO 13 on both boards) signals when the chip is
processing an internal operation — HIGH = busy, LOW = ready. The driver
calls `lora_wait_busy()` before every SPI command. If the pin is stuck
LOW, the wait exits instantly and SPI commands fire while the chip is
mid-operation. Commands get ignored or corrupted.

A single failed `lora_set_rx(0)` (the return-to-RX after TX) leaves the
radio in standby. `lora_poll_receive()` then checks IRQ status on a
standby radio — IRQ_RX_TIMEOUT never fires, so RX is never restarted.
The device is permanently deaf until reboot.

The code already notes this at `main/lora.c:367-368`:
> NOTE: BUSY pin stuck low on this hardware — TX succeeds ~50% of calls.

## Phase 1 — GPIO config verification

BUSY is configured once in `lora_init()` and never touched again. Check
that the config is correct for each board.

### 1A. Read the GPIO config block

File: `main/lora.c:250-258`

```c
gpio_config_t io = {
    .pin_bit_mask = (1ULL << PIN_BUSY),   // GPIO 13
    .mode = GPIO_MODE_INPUT,
    .pull_up_en = GPIO_PULLUP_DISABLE,     // <-- SUSPECT
    .pull_down_en = GPIO_PULLDOWN_DISABLE,
    .intr_type = GPIO_INTR_DISABLE,
};
gpio_config(&io);
```

**Check:** Is `GPIO_PULLUP_DISABLE` correct? The SX1262 BUSY pin is an
open-drain output — it pulls LOW when ready and floats HIGH when busy.
If the SX1262 module lacks an external pull-up resistor, the ESP32
must provide one internally (`GPIO_PULLUP_ENABLE`). Without it, the
pin floats and may read LOW regardless of the chip's state.

On the **Heltec V3**, GPIO 13 connects directly to the SX1262 and may
or may not have an on-board pull-up. On the **T-Deck**, GPIO 13 goes
to the SX1262 module — the module may or may not include one.

**Test:** Change `GPIO_PULLUP_DISABLE` to `GPIO_PULLUP_ENABLE` for BUSY
on both boards, rebuild, retest.

### 1B. Verify no GPIO conflict

GPIO 13 is also used as:
- Heltec V3: nothing else (checked board pinout)
- T-Deck: nothing else (checked board pinout)

No known conflict. Verify with `idf.py menuconfig` that no other component
claims GPIO 13.

### 1C. Scope the BUSY pin

If a logic analyzer or scope is available:
- Probe GPIO 13 during `lora_init()` — after the RST pulse, BUSY should
  go HIGH for ~2 seconds during chip boot, then go LOW.
- Probe GPIO 13 during `lora_send()` — BUSY should pulse HIGH briefly
  during calibration, then go LOW. It should go HIGH again during TX
  and LOW when TX_DONE fires.
- If BUSY never goes HIGH at any point, the pin is genuinely stuck LOW
  (hardware, config, or the chip isn't booting properly despite init
  returning success).

## Phase 2 — Busy-agnostic fallback

Even with the pull-up fixed, BUSY timing is fragile across two different
board layouts. A fixed-delay safety net prevents permanent deafness.

### 2A. Add a fallback busy-wait

Current `lora_wait_busy()`:

```c
static void lora_wait_busy(void) {
    uint32_t deadline = xTaskGetTickCount() + pdMS_TO_TICKS(1000);
    while (gpio_get_level(PIN_BUSY)) {
        if (xTaskGetTickCount() > deadline) return;
        vTaskDelay(1);
    }
}
```

If BUSY is stuck LOW, this returns in 0 ticks. Every SPI command fires
instantly — no guard at all.

Fallback approach: after the BUSY pin wait (whether it waited or not),
add a minimum delay as a safety net. SX1262 worst-case busy times per
the datasheet:

| Operation | Max busy time |
|-----------|--------------|
| Calibrate (all blocks) | ~6 ms |
| Set RF frequency | ~100 µs |
| Set modulation params | ~100 µs |
| Set packet params | ~100 µs |
| Write buffer | ~100 µs |
| Set TX | ~100 µs (then TX itself takes airtime) |
| Set RX | ~100 µs |
| Set standby | ~100 µs |
| Get status / IRQ | ~10 µs |

A 1 ms floor after every BUSY check costs negligible main-loop time
(SPI commands are rare — a few per second at most) and prevents racing
the chip.

### 2B. RX recovery watchdog

The biggest risk is a deaf radio after TX. Add a recovery path: if
`lora_poll_receive()` returns 0 for N consecutive main-loop iterations
(meaning no RX_DONE and no RX_TIMEOUT), force a re-init of the RX
state machine: standby → clear IRQs → set RX.

A radio in continuous RX should always produce either RX_DONE (packet
arrived) or RX_TIMEOUT (no packet within the window). If neither fires
for, say, 60 seconds (240 main-loop iterations at ~250ms), the radio
is likely in standby and needs recovery.

## Phase 3 — Verify data path end-to-end

Once BUSY is reliable, verify packets actually reach the other side.

### 3A. Serial debug prints

Add a one-line printf when a packet is sent and when one is received:

```
LoRa TX: heartbeat 17B
LoRa RX: 17B type=heartbeat from=UNIT-03 rssi=-42
LoRa RX: 24B type=detection from=UNIT-03 kind=camera mac=AB:CD:EF:12:34:56
```

This confirms the radio is actually transmitting and receiving, and
packets survive the CRC-8 check.

### 3B. Range test

Start with devices 1 meter apart. Confirm packets flow. Then separate
to test range. SF9 / 125 kHz at +22 dBm should reach 2-5 km line of
sight, or several city blocks with buildings.

### 3C. Check mesh peer display

The OLED peer page (page 6 on Heltec, accessible via keyboard on T-Deck)
and the web dashboard Mesh tab should show the other device as a peer
with RSSI. Heartbeat packets update the peer entry every 30s.

## Files to modify

| File | What | Risk |
|------|------|------|
| `main/lora.c:256` | BUSY pull-up from DISABLE to ENABLE | Low — one-line GPIO config change |
| `main/lora.c:90-96` | Add 1ms floor delay in `lora_wait_busy()` | Low — adds ~1ms per SPI call |
| `main/lora.c:404-426` | RX recovery watchdog (or in main loop) | Medium — new logic, needs testing |
| `src/main.zig:920-923` | Optional: add serial print for RX events | Trivial |

## Test procedure

1. Make Phase 1 changes (pull-up + delay floor)
2. Build for both boards: `BOARD=heltec_v3 ./build-zig.sh` and `BOARD=tdeck`
3. Flash both devices
4. Place devices 1m apart, power on
5. Wait 30+ seconds for heartbeat cycle
6. Check serial output for "LoRa RX:" messages
7. Check OLED page 6 / web dashboard Mesh tab for peer
8. If no packets: scope BUSY pin (Phase 1C)
9. If packets flow: add RX recovery watchdog (Phase 2B)
10. Range test (Phase 3B)
