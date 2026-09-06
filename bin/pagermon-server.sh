#!/usr/bin/env bash
# Run the PagerMon server in the foreground. Listens on 0.0.0.0:3000, so it is
# reachable from any device on the LAN.
set -uo pipefail
SRV="${PAGERMON_HOME:-$HOME/opt/pagermon}/server"
[[ -f "$SRV/config/config.json" ]] || { echo "not configured - run setup.sh first" >&2; exit 1; }
cd "$SRV"
export NODE_ENV=production
export PORT="${PORT:-3000}"
echo "PagerMon starting on http://$(hostname -I | awk '{print $1}'):$PORT"
exec node app.js
