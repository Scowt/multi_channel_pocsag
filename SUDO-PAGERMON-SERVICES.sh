#!/usr/bin/env bash
# Run AFTER setup-pagermon.sh has succeeded and you have confirmed both parts
# work by hand:  sudo bash SUDO-PAGERMON-SERVICES.sh
#
# Installs two systemd services so everything survives a reboot:
#   pagermon.service  - the web UI on port 3000
#   pocsag-rx.service - the GNU Radio receiver feeding it
set -euo pipefail

# systemd needs absolute paths, so resolve the repository root rather than
# assuming where it was cloned.
RADIO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[[ -f /home/pi/pagermon/server/config/config.json ]] || {
  echo "PagerMon is not configured yet - run setup-pagermon.sh first" >&2; exit 1; }
[[ -f "$RADIO/pagermon-client.json" ]] || {
  echo "$RADIO/pagermon-client.json missing - run setup-pagermon.sh first" >&2; exit 1; }

cat > /etc/systemd/system/pagermon.service <<'UNIT'
[Unit]
Description=PagerMon server
Documentation=https://github.com/pagermon/pagermon
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=pi
Group=pi
WorkingDirectory=/home/pi/pagermon/server
Environment=NODE_ENV=production
Environment=PORT=3000
ExecStart=/usr/bin/node app.js
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT

cat > /etc/systemd/system/pocsag-rx.service <<UNIT
[Unit]
Description=POCSAG multichannel receiver feeding PagerMon
After=pagermon.service
Wants=pagermon.service

[Service]
Type=simple
User=pi
Group=pi
# plugdev + the udev rule from SUDO-SETUP.sh give this user the RTL-SDR.
SupplementaryGroups=plugdev
WorkingDirectory=$RADIO
ExecStart=$RADIO/.venv/bin/python $RADIO/multichannel.py \\
  --av --no-color --gain 49.6 \\
  --pagermon-config $RADIO/pagermon-client.json
# The dongle may not be enumerated yet at boot, so keep retrying.
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now pagermon.service
sleep 5
systemctl enable --now pocsag-rx.service

echo
systemctl --no-pager --lines=0 status pagermon.service  || true
echo
systemctl --no-pager --lines=0 status pocsag-rx.service || true
echo
echo "Logs:  journalctl -u pagermon -f     journalctl -u pocsag-rx -f"
