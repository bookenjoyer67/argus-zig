# ================================================================
# ESP-IDF project for Argus (Zig + ESP-IDF on ESP32-S3)
# ================================================================
#
# This CMakeLists.txt is minimal — it only includes the ESP-IDF
# project boilerplate and links the pre-built Zig static library.
#
# The Zig library (zig-out/libargus.a) must be built before
# running idf.py build. Run ./build-zig.sh first.
#
# ESP-IDF components (FreeRTOS, NimBLE, WiFi, SPIFFS, etc.)
# are resolved automatically by ESP-IDF's component system
# based on the REQUIRES line in main/CMakeLists.txt.

cmake_minimum_required(VERSION 3.16)
include($ENV{IDF_PATH}/tools/cmake/project.cmake)

# Board selection for the C side. Pass with: idf.py -DBOARD=tdeck build
# Defines BOARD_TDECK so board-specific C (e.g. main/tft.c) compiles in.
# (The Zig side selects the board separately via BOARD=... ./build-zig.sh.)
if(DEFINED BOARD AND BOARD STREQUAL "tdeck")
    add_compile_definitions(BOARD_TDECK)
    message(STATUS "Argus: building for T-Deck (BOARD_TDECK)")
endif()

project(argus-zig)

# Link the Zig static library into the final ELF.
# PRIVATE means only the final executable sees these symbols.
target_link_libraries(${CMAKE_PROJECT_NAME}.elf PRIVATE
    ${CMAKE_SOURCE_DIR}/zig-out/libargus.a
)
