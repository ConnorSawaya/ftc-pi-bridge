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
install -m 0755 ftc-linkwatch /usr/local/bin/ftc-linkwatch  # re-plugs the USB link when it goes dead
install -m 0644 ftc-linkwatch.service /etc/systemd/system/ftc-linkwatch.service
install -D -m 0644 watchdog.conf /etc/systemd/system.conf.d/watchdog.conf  # auto-restart if frozen
install -D -m 0644 journald.conf /etc/systemd/journald.conf.d/ftc-persistent.conf  # keep logs across restarts
install -D -m 0644 wifi-powersave.conf /etc/NetworkManager/conf.d/ftc-wifi-powersave.conf
mkdir -p /var/log/journal
systemctl restart systemd-journald
journalctl --flush 2>/dev/null || true  # move this boot's log from memory onto the card

systemctl daemon-reload
# Applies the watchdog setting. Not during first boot (cloud-init is running under systemd then);
# it applies from the next boot instead.
[[ "${2:-}" == first-boot ]] || systemctl daemon-reexec
systemctl enable --quiet adb-forward.service
systemctl restart adb-forward.service
systemctl enable --quiet ftc-linkwatch.service
systemctl restart ftc-linkwatch.service
systemctl reload NetworkManager 2>/dev/null || true  # applies the Wi-Fi power-save setting
rfkill unblock wifi 2>/dev/null || true
nmcli radio wifi on 2>/dev/null || true  # Raspberry Pi OS starts with Wi-Fi switched off

install -D -m 0644 /dev/null /etc/ftc-pi-bridge/version
echo "${1:-unknown}" > /etc/ftc-pi-bridge/version
echo "Pi updated to version ${1:-unknown}"
