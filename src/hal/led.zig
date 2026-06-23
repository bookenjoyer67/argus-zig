//! === LED backend (GPIO/PWM white LED) ===
//!
//! `Led(pin)` builds an LED driver bound to a GPIO. Used by boards that have a
//! user LED (Heltec). Boards without one (T-Deck) supply a no-op `led` instead.
//!
//! The PWM path drives the LEDC channel the C side configured on the LED pin;
//! the blocking blink path toggles the GPIO directly.

const main = @import("../main.zig");
const scanner = @import("../scanner.zig");

pub fn Led(comptime pin: u32) type {
    return struct {
        /// Configure the LEDC PWM channel (8-bit, 5 kHz) on the LED pin.
        pub fn pwmInit() void {
            main.led_pwm_init();
        }

        /// Set LED brightness via PWM (0 = off, 255 = full).
        pub fn set(duty: u32) void {
            main.led_pwm_set(duty);
        }

        /// Full brightness.
        pub fn on() void {
            main.led_pwm_set(255);
        }

        /// Off.
        pub fn off() void {
            main.led_pwm_set(0);
        }

        fn gpioOn() void {
            _ = main.gpio_write(pin, 1);
        }
        fn gpioOff() void {
            _ = main.gpio_write(pin, 0);
        }

        /// Blocking LED alert pattern by confidence score.
        /// 0-39: silent.  40-69: single blink.  70-84: three.  85+: five.
        /// Each blink is 40ms on, 40ms off (delayMs yields to FreeRTOS).
        pub fn alertLed(score: u8) void {
            if (score < scanner.SCORE_MED) return;
            const count: u32 = if (score >= scanner.SCORE_CERT) 5 else if (score >= scanner.SCORE_HIGH) 3 else 1;
            var i: u32 = 0;
            while (i < count) : (i += 1) {
                gpioOn();
                main.delayMs(40);
                gpioOff();
                main.delayMs(40);
            }
        }
    };
}
