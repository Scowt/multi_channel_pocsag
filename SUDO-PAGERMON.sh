#!/usr/bin/env bash
# Run from the repository root with:  sudo bash SUDO-PAGERMON.sh
# Installs Node.js for PagerMon. Everything else is done as the pi user.
set -euo pipefail

echo "==> Installing Node.js 20 LTS + npm + sqlite3 CLI"
apt-get update
apt-get install -y nodejs npm sqlite3

echo
echo "node: $(node --version)"
echo "npm : $(npm --version)"
echo
echo "DONE. Nothing else needs root until the systemd service step."
