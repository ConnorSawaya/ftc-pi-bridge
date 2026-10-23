#!/bin/bash
# Puts the bridge's files in place on the Pi and restarts what needs it. Runs as root, from the
# folder holding the files: at first boot (from flash.sh's cloud-init) and on `ftc-bridge update-pi`.
#   bash install.sh VERSION [first-boot]
set -euo pipefail
cd "$(dirname "$0")"

install -m 0755 adb-forward.py /usr/local/bin/adb-forward.py
install -m 0644 adb-forward.service /etc/systemd/system/adb-forward.service
install -D -m 0644 no-gateway.conf /etc/NetworkManager/dnsmasq-shared.d/95-ftc-no-gateway.conf
install -m 0755 ftc-hub /usr/local/bin/ftc-hub
install -D -m 0644 watchdog.conf /etc/systemd/system.conf.d/watchdog.conf  # auto-restart if frozen
mkdir -p /var/log/journal  # keep logs across restarts, to see why a freeze happened

systemctl daemon-reload
# Applies the watchdog setting. Not during first boot (cloud-init is running under systemd then);
# it applies from the next boot instead.
[[ "${2:-}" == first-boot ]] || systemctl daemon-reexec
systemctl enable --quiet adb-forward.service
systemctl restart adb-forward.service
rfkill unblock wifi 2>/dev/null || true
nmcli radio wifi on 2>/dev/null || true  # Raspberry Pi OS starts with Wi-Fi switched off

install -D -m 0644 /dev/null /etc/ftc-pi-bridge/version
echo "${1:-unknown}" > /etc/ftc-pi-bridge/version
echo "Pi updated to version ${1:-unknown}"
