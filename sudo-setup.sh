#!/usr/bin/env bash
# Every root-requiring step, in one place.
#
#   sudo bash sudo-setup.sh
#
# Installs packages, frees the RTL-SDR from the DVB-T drivers, and installs the
# systemd units. Safe to re-run: it is idempotent, and re-running it after
# setup.sh is how you start the services for the first time.
#
# Run setup.sh (as your normal user, NOT root) in between - it needs the Node.js
# this script installs, and this script needs the config that one generates
# before it can start anything.
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "This script needs root. Run: sudo bash $0" >&2; exit 1; }

# systemd units need absolute paths and a real user, and $HOME is /root here.
RUN_USER="${SUDO_USER:-pi}"
USER_HOME="$(getent passwd "$RUN_USER" | cut -d: -f6)"
[[ -n "$USER_HOME" ]] || { echo "cannot resolve home for user '$RUN_USER'" >&2; exit 1; }
REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PM="$USER_HOME/opt/pagermon"

echo "==> user $RUN_USER, repo $REPO, pagermon $PM"

echo "==> 1/5  Installing packages"
apt-get update
apt-get install -y rtl-sdr multimon-ng sox gnuradio gr-osmosdr \
                   nodejs npm sqlite3 git python3-venv

echo "==> 2/5  Blacklisting the DVB-T kernel drivers that hold the dongle"
cat > /etc/modprobe.d/blacklist-rtlsdr.conf <<'EOF'
# Keep the DVB-T TV drivers off the RTL2832U so rtl_fm/rtl_sdr can claim it.
blacklist dvb_usb_rtl28xxu
blacklist rtl2832
blacklist rtl2832_sdr
blacklist rtl2830
blacklist r820t
EOF

echo "==> 3/5  Unloading them now (so no reboot is needed)"
for m in rtl2832_sdr dvb_usb_rtl28xxu rtl2832 r820t dvb_usb_v2 dvb_core; do
  modprobe -r "$m" 2>/dev/null || true
done

echo "==> 4/5  udev rule so '$RUN_USER' can use the dongle without root"
cat > /etc/udev/rules.d/20-rtlsdr.rules <<'EOF'
SUBSYSTEM=="usb", ATTRS{idVendor}=="0bda", ATTRS{idProduct}=="2838", GROUP="plugdev", MODE="0666", SYMLINK+="rtl_sdr"
SUBSYSTEM=="usb", ATTRS{idVendor}=="0bda", ATTRS{idProduct}=="2832", GROUP="plugdev", MODE="0666"
EOF
udevadm control --reload-rules
udevadm trigger

echo "==> 5/5  Installing systemd units"
cat > /etc/systemd/system/pagermon.service <<UNIT
[Unit]
Description=PagerMon server
Documentation=https://github.com/pagermon/pagermon
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$RUN_USER
Group=$RUN_USER
WorkingDirectory=$PM/server
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
User=$RUN_USER
Group=$RUN_USER
# plugdev + the udev rule above give this user the RTL-SDR.
SupplementaryGroups=plugdev
WorkingDirectory=$REPO
# --gain 49.6, not auto: the R820T's AGC buries the signal on this hardware.
# See "Gain" in the README.
ExecStart=$REPO/.venv/bin/python $REPO/multichannel.py \\
  --av --no-color --gain 49.6 \\
  --pagermon-config $REPO/pagermon-client.json
# The dongle may not be enumerated yet at boot, so keep retrying.
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable pagermon.service pocsag-rx.service >/dev/null

# Only start once setup.sh has produced the things the services need.
if [[ -f "$PM/server/config/config.json" && -f "$REPO/pagermon-client.json" ]]; then
  echo "==> Config present - starting services"
  systemctl restart pagermon.service
  sleep 5
  systemctl restart pocsag-rx.service
  echo
  systemctl --no-pager --lines=0 status pagermon.service  || true
  echo
  systemctl --no-pager --lines=0 status pocsag-rx.service || true
  echo
  echo "Logs:  journalctl -u pagermon -f     journalctl -u pocsag-rx -f"
else
  echo
  echo "Units installed and enabled, but NOT started - PagerMon is not configured yet."
  echo "Next:  bash $REPO/setup.sh      (as $RUN_USER, not root)"
  echo "Then:  sudo bash $0             (re-run me to start everything)"
fi

echo
echo "DONE. If the dongle was plugged in before this ran, unplug and replug it,"
echo "then check with:  rtl_test -t"
