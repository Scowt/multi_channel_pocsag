#!/usr/bin/env bash
# Receive POCSAG paging on one frequency and print clear text to the console.
#
# NOTE: measured on this site, rtl_fm's channel filter is too broad to reject
# the +50 dB carrier at 148.4961 MHz, and it decodes nothing on the ambulance
# channel. Use bin/pocsag-multi.sh for 148.6875 / 148.9125. This script is
# fine for strong, well-isolated channels.
#
#   bin/pocsag-rx.sh                          # default freq, show everything
#   bin/pocsag-rx.sh -f 148.6875M             # pick a frequency
#   bin/pocsag-rx.sh --only-av                # emergency-services traffic only
#   bin/pocsag-rx.sh -g 49.6 -p 12            # set gain / ppm correction
#
# Any flag this script does not recognise is passed through to pocsagfmt.py.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PY="$ROOT/.venv/bin/python"

FREQ="${FREQ:-148.9125M}"
GAIN="${GAIN:-auto}"   # "auto" = let the tuner AGC decide (usually far better)
PPM="${PPM:-0}"
RATE=22050
SQUELCH="${SQUELCH:-0}"
BAUDS=(POCSAG512 POCSAG1200 POCSAG2400)
FMT_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -f|--freq)    FREQ="$2"; shift 2 ;;
    -g|--gain)    GAIN="$2"; shift 2 ;;
    -p|--ppm)     PPM="$2";  shift 2 ;;
    -s|--squelch) SQUELCH="$2"; shift 2 ;;
    --512)        BAUDS=(POCSAG512);  shift ;;
    --1200)       BAUDS=(POCSAG1200); shift ;;
    -h|--help)    sed -n '2,10p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *)            FMT_ARGS+=("$1"); shift ;;
  esac
done

command -v rtl_fm      >/dev/null || { echo "rtl_fm not installed - run: sudo bash $ROOT/SUDO-SETUP.sh" >&2; exit 1; }
command -v multimon-ng >/dev/null || { echo "multimon-ng not installed - run: sudo bash $ROOT/SUDO-SETUP.sh" >&2; exit 1; }

GAIN_ARGS=()
[[ "$GAIN" != "auto" ]] && GAIN_ARGS=(-g "$GAIN")

MM_ARGS=()
for b in "${BAUDS[@]}"; do MM_ARGS+=(-a "$b"); done

echo "# freq=$FREQ gain=$GAIN ppm=$PPM squelch=$SQUELCH bauds=${BAUDS[*]}" >&2

# rtl_fm -> multimon-ng -> formatter.  rtl_fm chatter goes to stderr.
#
# The trap kills our direct children on the way out. Without it, a Ctrl-C or a
# `timeout` leaves rtl_fm orphaned still holding the USB device, and the next
# run dies with "usb_claim_interface error -6".
trap 'pkill -P $$ >/dev/null 2>&1' EXIT INT TERM

rtl_fm -f "$FREQ" -M fm -s "$RATE" "${GAIN_ARGS[@]+"${GAIN_ARGS[@]}"}" -p "$PPM" -l "$SQUELCH" -E dc - \
  | multimon-ng "${MM_ARGS[@]}" -f auto -e -u -t raw /dev/stdin 2>/dev/null \
  | "$PY" "$ROOT/pocsagfmt.py" --freq "$FREQ" "${FMT_ARGS[@]+"${FMT_ARGS[@]}"}"
