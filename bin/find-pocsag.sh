#!/usr/bin/env bash
# Dwell on each known Victorian paging frequency in turn, count what decodes,
# and rank them. Use this to discover which channels are live where you are.
#
#   bin/find-pocsag.sh            # 45s per channel
#   bin/find-pocsag.sh 90         # 90s per channel
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$ROOT/logs"
PY="$ROOT/.venv/bin/python"
DWELL="${1:-45}"
GAIN="${GAIN:-auto}"
PPM="${PPM:-0}"
OUT="$ROOT/logs/survey-$(date +%Y%m%d-%H%M%S).txt"
GAIN_ARGS=()
[[ "$GAIN" != "auto" ]] && GAIN_ARGS=(-g "$GAIN")

# Victorian VHF paging channels (Melbourne/statewide). See the 'Victorian VHF paging channels' table in README.md.
FREQS=(
  148.3375 148.3625 148.4125 148.4375 148.5125 148.5375
  148.5625 148.5875 148.6125 148.6375 148.6875 148.7125
  148.7375 148.7875 148.8125 148.8375 148.9125 148.9375
  148.9625 148.9875
)

command -v rtl_fm >/dev/null || { echo "rtl_fm not installed - run: sudo bash $ROOT/sudo-setup.sh" >&2; exit 1; }

echo "Surveying ${#FREQS[@]} channels x ${DWELL}s  (~$(( ${#FREQS[@]} * DWELL / 60 )) min total)"
echo "Log: $OUT"
echo
printf "%-12s %8s %8s  %s\n" "FREQ(MHz)" "MSGS" "ALPHA" "SAMPLE"
printf "%-12s %8s %8s  %s\n" "---------" "----" "-----" "------"

: > "$OUT"
for f in "${FREQS[@]}"; do
  raw=$(timeout "$DWELL" rtl_fm -f "${f}M" -M fm -s 22050 "${GAIN_ARGS[@]+"${GAIN_ARGS[@]}"}" -p "$PPM" -l 0 -E dc - 2>/dev/null \
        | timeout "$DWELL" multimon-ng -a POCSAG512 -a POCSAG1200 -a POCSAG2400 -f auto -e -u -t raw /dev/stdin 2>/dev/null \
        | grep -a '^POCSAG' || true)
  n=$(printf '%s' "$raw"    | grep -ac 'Address:'     || true)
  a=$(printf '%s' "$raw"    | grep -ac 'Alpha:'       || true)
  sample=$(printf '%s' "$raw" | grep -a 'Alpha:' | head -1 | sed 's/.*Alpha:[[:space:]]*//' | cut -c1-46)
  printf "%-12s %8s %8s  %s\n" "$f" "$n" "$a" "$sample"
  { echo "=== $f  msgs=$n alpha=$a"; printf '%s\n' "$raw"; } >> "$OUT"
done

echo
echo "Full capture: $OUT"
echo "Now run the busiest one, e.g.:  bin/pocsag-rx.sh -f 148.9125M --av"
