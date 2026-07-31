#!/usr/bin/env bash
# End-to-end audio quality check for the BMC S-USB on Linux.
#
# Plays a reference signal through the PC speakers, captures the microphone
# through the USB isochronous endpoint (bit-exact, so XOR decryption works),
# and prints an objective report.
#
#   ./audio_test.sh room     10       # ambient: noise floor, hum, rumble
#   ./audio_test.sh tone     10       # 1 kHz sine: THD, clipping, gain
#   ./audio_test.sh sweep    14       # stepped tones: frequency response
#
# Captures land in ./captures/<label>_<timestamp>_dec.wav so successive runs can
# be compared. Comparing two runs is the point -- absolute numbers from a room
# mic mean much less than the difference a firmware change makes.
set -euo pipefail

cd "$(dirname "$0")"

MODE="${1:-room}"
SECS="${2:-10}"
OUTDIR="captures"
STAMP="$(date +%Y%m%d-%H%M%S)"
BASE="$OUTDIR/${MODE}_${STAMP}"

mkdir -p "$OUTDIR"

[ -x ./bmc_audio_cli ] || make
command -v aplay >/dev/null || { echo "aplay not found (install alsa-utils)"; exit 1; }

case "$MODE" in
  room)  REF="";                ANALYZE_ARGS=() ;;
  tone)  REF="ref_tone1k.wav";  ANALYZE_ARGS=(--tone 1000) ;;
  sweep) REF="ref_sweep.wav";   ANALYZE_ARGS=() ;;

  # Injected modes: the firmware substitutes a known waveform for the
  # microphone, so nothing is played through the speakers. Set PDM_TEST_SIGNAL
  # in source/uac/usb_audio_config.h and reflash before using these.
  inject-tone)   REF=""; ANALYZE_ARGS=(--tone 1000) ;;   # PDM_TEST_SIGNAL=1
  inject-sweep)  REF=""; ANALYZE_ARGS=(--sweep) ;;       # PDM_TEST_SIGNAL=2
  inject-silence) REF=""; ANALYZE_ARGS=() ;;             # PDM_TEST_SIGNAL=3

  *) echo "usage: $0 {room|tone|sweep|inject-tone|inject-sweep|inject-silence} [seconds]"
     exit 1 ;;
esac

case "$MODE" in
  inject-*)
    echo "NOTE: this mode expects firmware built with PDM_TEST_SIGNAL set."
    echo "      inject-tone=1  inject-sweep=2  inject-silence=3"
    echo "      (source/uac/usb_audio_config.h)"
    echo
    ;;
esac

if [ -n "$REF" ] && [ ! -f "$REF" ]; then
  echo "Generating reference signals..."
  python3 ./make_reference.py --secs 20
fi

if [ -n "$REF" ]; then
  echo "Playing $REF through the default output — keep the mic near the speaker."
  aplay -q "$REF" &
  APLAY_PID=$!
  trap 'kill $APLAY_PID 2>/dev/null || true' EXIT
  sleep 1   # let the tone settle before the capture window opens
fi

echo "Capturing ${SECS}s..."
./bmc_audio_cli -d "$SECS" -o "$BASE"

if [ -n "$REF" ]; then
  kill $APLAY_PID 2>/dev/null || true
  trap - EXIT
fi

echo
python3 ./analyze_wav.py "${BASE}_dec.wav" "${ANALYZE_ARGS[@]}"

echo
echo "Capture saved: ${BASE}_dec.wav"
echo "Compare with an earlier run:"
echo "  python3 ./analyze_wav.py $OUTDIR/<older>_dec.wav ${ANALYZE_ARGS[*]}"
