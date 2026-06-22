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
    SRCS "main.c" "ble.c" "wifi.c" "spiffs.c" "lora.c"
    INCLUDE_DIRS "."
        "${IDF_PATH}/components/bt/host/nimble/nimble/porting/nimble/include"
        "${IDF_PATH}/components/bt/host/nimble/nimble/nimble/include"
        "${IDF_PATH}/components/bt/host/nimble/nimble/nimble/host/include"
        "${IDF_PATH}/components/bt/host/nimble/nimble/nimble/host/services/gap/include"
        "${IDF_PATH}/components/bt/host/nimble/nimble/nimble/host/util/include"
        "${IDF_PATH}/components/bt/porting/npl/freertos/include"
        "${IDF_PATH}/components/bt/host/nimble/port/include"
        "${IDF_PATH}/components/bt/host/nimble/nimble/porting/npl/freertos/include"
        "${IDF_PATH}/components/bt/host/nimble/nimble/nimble/transport/include"
        "${IDF_PATH}/components/esp_wifi/include"
        "${IDF_PATH}/components/esp_wifi/include/local"
        "${IDF_PATH}/components/esp_netif/include"
        "${IDF_PATH}/components/esp_event/include"
        "${IDF_PATH}/components/esp_adc/include"
        "${IDF_PATH}/components/hal/include"
        "${IDF_PATH}/components/spiffs/include"
    REQUIRES nvs_flash bt freertos esp_wifi driver spiffs vfs
)
