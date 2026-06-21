# ================================================================
# ESP-IDF main component
# ================================================================
#
# This is the only C file in the project.
# It initializes NVS flash and calls zig_main().
#
# REQUIRES lists the ESP-IDF components this component depends on.
# These are resolved automatically by ESP-IDF's component system:
#
#   nvs_flash   — Non-Volatile Storage (required by NimBLE and WiFi)
#   bt          — Bluetooth stack (includes NimBLE)
#   freertos    — FreeRTOS scheduler
#   esp_wifi    — WiFi stack (for promiscuous mode, not yet used)
#   driver      — GPIO, I2C, SPI peripheral drivers
#
# The Zig static library (zig-out/libargus.a) is linked at the
# project level in CMakeLists.txt, not here.

idf_component_register(
    SRCS "main.c"
    INCLUDE_DIRS "."
    REQUIRES nvs_flash bt freertos esp_wifi driver
)
