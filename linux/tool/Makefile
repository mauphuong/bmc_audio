# Build the standalone BMC S-USB capture/decrypt CLI.
#   make          # build ./bmc_audio_cli
#   make run      # build + capture 5s to ./bmc_capture_{enc,dec}.wav
#   make clean
CC      ?= gcc
CFLAGS  += -O2 -Wall $(shell pkg-config --cflags libusb-1.0)
LDFLAGS += $(shell pkg-config --libs libusb-1.0) -lm

bmc_audio_cli: bmc_audio_cli.c
	$(CC) $(CFLAGS) $< -o $@ $(LDFLAGS)

run: bmc_audio_cli
	./bmc_audio_cli -d 5 -o bmc_capture

clean:
	rm -f bmc_audio_cli bmc_capture_*.wav

.PHONY: run clean
