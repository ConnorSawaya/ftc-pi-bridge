#!/bin/bash
# Make a ready-to-use ftc-pi-bridge SD card on macOS. Only needed once per card.
#
#   ./flash.sh                 # picks the SD card and writes it
#   ./flash.sh --disk disk4    # same, but erases disk4 without asking (still checks it's an SD card)
#   ./flash.sh --dry-run DIR   # only writes the cloud-init file to DIR (for checking)
#
# The card boots into: USB networking to the Mac (Pi = 10.12.194.1), an ADB forwarder, and
# `ftc-hub`, which the FTC Bridge menu bar app uses to pick the Control Hub's Wi-Fi.
# Wi-Fi country defaults to US; override with COUNTRY=GB ./flash.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
IMAGER="/Applications/Raspberry Pi Imager.app/Contents/MacOS/rpi-imager"
IMAGE_URL="https://downloads.raspberrypi.com/raspios_lite_arm64_latest"
CACHE="$HOME/Library/Caches/ftc-pi-bridge"
KEY="$HOME/.ssh/ftcpi"  # the Mac app logs into the Pi with this
COUNTRY="${COUNTRY:-US}"
MAX_CARD_BYTES=$((256 * 1000 * 1000 * 1000))  # refuse anything bigger than a normal SD card

die() { echo "error: $*" >&2; exit 1; }
yaml_str() { local s=${1//\\/\\\\}; s=${s//\"/\\\"}; printf '"%s"' "$s"; }  # YAML double-quoted
indent() { sed 's/^/      /' "$1"; }  # indent a file to sit under a write_files `content: |`

[[ "$COUNTRY" =~ ^[A-Z]{2}$ ]] || die "COUNTRY must be two capital letters, e.g. US"
DRY_RUN=""; DISK=""
case "${1:-}" in
  --dry-run) DRY_RUN="${2:?--dry-run needs a directory}" ;;
  --disk) DISK="${2:?--disk needs a disk, e.g. disk4}" ;;
esac

# --- SSH key -----------------------------------------------------------------
if [[ ! -f "$KEY" ]]; then
  echo "Creating SSH key $KEY"
  ssh-keygen -q -t ed25519 -N "" -C "ftcpi" -f "$KEY"
fi
PUBKEY="$(cat "$KEY.pub")"

# --- Cloud-init --------------------------------------------------------------
if [[ -n "$DRY_RUN" ]]; then
  OUT="$DRY_RUN"; mkdir -p "$OUT"
else
  OUT="$(mktemp -d)"; trap 'rm -rf "$OUT"' EXIT
fi

cat > "$OUT/user-data" <<EOF
#cloud-config
hostname: ftcpi
manage_etc_hosts: true
user:
  name: ftc
  shell: /bin/bash
  lock_passwd: true
  sudo: ALL=(ALL) NOPASSWD:ALL
  ssh_authorized_keys:
    - $(yaml_str "$PUBKEY")
ssh_pwauth: false
enable_ssh: true
rpi:
  enable_usb_gadget: true
write_files:
  - path: /usr/local/bin/adb-forward.py
    permissions: "0755"
    content: |
$(indent "$HERE/pi/adb-forward.py")
  - path: /etc/systemd/system/adb-forward.service
    content: |
$(indent "$HERE/pi/adb-forward.service")
  - path: /etc/NetworkManager/dnsmasq-shared.d/95-ftc-no-gateway.conf
    content: |
$(indent "$HERE/pi/no-gateway.conf")
  - path: /usr/local/bin/ftc-hub
    permissions: "0755"
    content: |
$(indent "$HERE/pi/ftc-hub")
runcmd:
  - [systemctl, enable, --now, ssh]
  - [systemctl, daemon-reload]
  - [systemctl, enable, --now, adb-forward.service]
  - [rfkill, unblock, wifi]
  - [nmcli, radio, wifi, "on"]
EOF

if [[ -n "$DRY_RUN" ]]; then echo "Wrote $OUT/user-data"; exit 0; fi

# --- Image ------------------------------------------------------------------
[[ -x "$IMAGER" ]] || die "Raspberry Pi Imager not found. Install it: brew install --cask raspberry-pi-imager"
mkdir -p "$CACHE"
URL="$(curl -fsSIL -o /dev/null -w '%{url_effective}' "$IMAGE_URL")"  # HEAD only: just find the file name
IMG="$CACHE/$(basename "$URL")"
if [[ ! -f "$IMG" ]]; then
  echo "Downloading $(basename "$URL")"
  curl -fL --progress-bar -o "$IMG.part" "$URL" && mv "$IMG.part" "$IMG"
fi
WANT="$(curl -fsSL "$URL.sha256" | awk '{print $1}')"
GOT="$(shasum -a 256 "$IMG" | awk '{print $1}')"
[[ -n "$WANT" && "$WANT" == "$GOT" ]] || { rm -f "$IMG"; die "image checksum mismatch; deleted it, run again"; }
echo "Image OK: $(basename "$IMG")"

# --- Pick the SD card (human types it; we refuse anything that looks wrong) ---
# A Mac's built-in SD slot counts as "internal", so filter on removable instead.
removable() { diskutil info -plist "/dev/$1" | plutil -extract RemovableMediaOrExternalDevice raw - 2>/dev/null; }
if [[ -z "$DISK" ]]; then
  echo
  for d in $(diskutil list physical | awk '/^\/dev\/disk/ {sub("/dev/", "", $1); print $1}'); do
    [[ "$(removable "$d")" == "true" ]] && diskutil list "$d"
  done
  echo
  read -r -p "Type the SD card's disk (e.g. disk4). EVERYTHING ON IT WILL BE ERASED: " DISK
  ASK=1
fi
[[ "$DISK" =~ ^disk[0-9]+$ ]] || die "expected something like disk4"
INFO="$(diskutil info -plist "/dev/$DISK")" || die "no such disk"
[[ "$(removable "$DISK")" == "true" ]] || die "/dev/$DISK is not a removable disk"
SIZE="$(plutil -extract TotalSize raw - <<<"$INFO")"
(( SIZE <= MAX_CARD_BYTES )) || die "/dev/$DISK is bigger than 256 GB; that's not an SD card"
if [[ -n "${ASK:-}" ]]; then
  read -r -p "Erase /dev/$DISK ($((SIZE / 1000000000)) GB)? Type yes: " OK
  [[ "$OK" == "yes" ]] || die "cancelled"
else
  echo "Erasing /dev/$DISK ($((SIZE / 1000000000)) GB)"
fi

# --- Write -------------------------------------------------------------------
echo "Writing (macOS will ask for your password)..."
sudo "$IMAGER" --cli \
  --cloudinit-userdata "$OUT/user-data" \
  --disable-eject \
  "$IMG" "/dev/$DISK"

# --- Final touches on the boot partition -------------------------------------
diskutil mountDisk "/dev/$DISK" >/dev/null
BOOT="$(diskutil info -plist "/dev/${DISK}s1" | plutil -extract MountPoint raw -)"
[[ -f "$BOOT/user-data" ]] || die "Imager didn't write user-data to $BOOT; card is not set up"
# Competition rule E301: no Bluetooth in the venue.
grep -q 'disable-bt' "$BOOT/config.txt" || printf '\n[all]\ndtoverlay=disable-bt\n' >> "$BOOT/config.txt"
# Wi-Fi stays blocked until a country is set; the Imager GUI does this, its CLI doesn't.
grep -q 'ieee80211_regdom' "$BOOT/cmdline.txt" ||
  sed -i '' "1 s/\$/ cfg80211.ieee80211_regdom=$COUNTRY/" "$BOOT/cmdline.txt"
diskutil eject "/dev/$DISK" >/dev/null

cat <<EOF

Done. Remove the SD card. Next:
  1. Put the card in the Pi. Plug the Pi's middle micro-USB port (labelled USB) into your Mac.
  2. Wait ~3 minutes the first time (it reboots once).
  3. In the FTC Bridge menu bar app, pick the Control Hub and type its Wi-Fi password.
EOF
