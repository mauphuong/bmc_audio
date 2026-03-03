cmake_minimum_required(VERSION 3.10)
project(bmc_usb_audio C)

add_library(bmc_usb_audio SHARED usb_audio_iso.c)

target_link_libraries(bmc_usb_audio
    android
    log
)
