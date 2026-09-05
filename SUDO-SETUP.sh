#!/usr/bin/env bash
# Run this from the repository root with:  sudo bash SUDO-SETUP.sh
# Everything in here needs root. Nothing else in this project does.
set -euo pipefail

echo "==> 1/4  Installing packages"
apt-get update
apt-get install -y rtl-sdr multimon-ng sox gnuradio gr-osmosdr

echo "==> 2/4  Blacklisting the DVB-T kernel drivers that hold the dongle"
cat > /etc/modprobe.d/blacklist-rtlsdr.conf <<'EOF'
# Keep the DVB-T TV drivers off the RTL2832U so rtl_fm/rtl_sdr can claim it.
blacklist dvb_usb_rtl28xxu
blacklist rtl2832
blacklist rtl2832_sdr
blacklist rtl2830
blacklist r820t
EOF

echo "==> 3/4  Unloading them now (so no reboot is needed)"
modprobe -r rtl2832_sdr        2>/dev/null || true
modprobe -r dvb_usb_rtl28xxu   2>/dev/null || true
modprobe -r rtl2832            2>/dev/null || true
modprobe -r r820t              2>/dev/null || true
modprobe -r dvb_usb_v2         2>/dev/null || true
modprobe -r dvb_core           2>/dev/null || true

echo "==> 4/4  udev rule so user 'pi' can use the dongle without root"
cat > /etc/udev/rules.d/20-rtlsdr.rules <<'EOF'
SUBSYSTEM=="usb", ATTRS{idVendor}=="0bda", ATTRS{idProduct}=="2838", GROUP="plugdev", MODE="0666", SYMLINK+="rtl_sdr"
SUBSYSTEM=="usb", ATTRS{idVendor}=="0bda", ATTRS{idProduct}=="2832", GROUP="plugdev", MODE="0666"
EOF
udevadm control --reload-rules
udevadm trigger

echo
echo "DONE. Now unplug and replug the RTL-SDR, then run:  rtl_test -t"
