#!/usr/bin/env bash
# Power-sweep the VHF paging band to see which channels are actually radiating
# here. Much faster than waiting for decodes. Default 148-149 MHz for ~2 min.
#
#   bin/band-scan.sh              # 148-149 MHz, 2 minutes
#   bin/band-scan.sh 5m           # scan for 5 minutes
#   bin/band-scan.sh 2m 148M 149M # explicit range
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$ROOT/logs"
PY="$ROOT/.venv/bin/python"
DUR="${1:-2m}"
LO="${2:-148M}"
HI="${3:-149M}"
GAIN="${GAIN:-auto}"
CSV="$ROOT/logs/power-$(date +%Y%m%d-%H%M%S).csv"
GAIN_ARGS=()
[[ "$GAIN" != "auto" ]] && GAIN_ARGS=(-g "$GAIN")

command -v rtl_power >/dev/null || { echo "rtl_power not installed - run: sudo bash $ROOT/sudo-setup.sh" >&2; exit 1; }

echo "Sweeping $LO..$HI for $DUR at 1 kHz bins (gain $GAIN)"
echo "CSV: $CSV"
rtl_power -f "${LO}:${HI}:1k" -i 1 "${GAIN_ARGS[@]+"${GAIN_ARGS[@]}"}" -e "$DUR" "$CSV"
echo
"$PY" "$ROOT/bandscan.py" "$CSV"
