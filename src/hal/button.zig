//! === GPIO button input ===
//!
//! `Button(pin)` builds an active-LOW button driver (internal pullup). The
//! gesture FSM (short / double / hold) lives in the main loop; this owns the
//! raw pin. Boards without a button (T-Deck) supply a stub instead.

const main = @import("../main.zig");

pub fn Button(comptime pin: u32) type {
    return struct {
        /// Configure the button pin as input with internal pullup.
        pub fn initPullup() void {
            _ = main.gpio_pin_init(pin, main.GPIO_INPUT, main.GPIO_PULL_UP);
        }

        /// True while the button is held (active LOW → reads 0).
        pub fn pressed() bool {
            return main.gpio_read(pin) == 0;
        }
    };
}
