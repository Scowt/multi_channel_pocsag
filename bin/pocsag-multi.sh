#!/usr/bin/env bash
# Watch every Victorian paging channel simultaneously with one dongle.
# Paging is bursty, so parallel channels find traffic far faster than tuning
# them one at a time.
#
#   bin/pocsag-multi.sh                 # all 8 channels, until Ctrl-C
#   bin/pocsag-multi.sh --duration 1200 # 20 minutes then stop
#   bin/pocsag-multi.sh --av            # highlight emergency traffic
#   bin/pocsag-multi.sh --channels 148.6875,148.9125
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v multimon-ng >/dev/null || { echo "multimon-ng missing - run: sudo bash $ROOT/sudo-setup.sh" >&2; exit 1; }
exec "$ROOT/.venv/bin/python" "$ROOT/multichannel.py" "$@"
