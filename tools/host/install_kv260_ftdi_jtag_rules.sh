#!/bin/sh
set -eu

RULE_NAME=59-kv260-ftdi-jtag.rules
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
RULE_SRC="$SCRIPT_DIR/kv260-ftdi-jtag.rules"
RULE_DST="/etc/udev/rules.d/$RULE_NAME"
SERIAL="XFL15KDTUSIW"

if [ "$(id -u)" -ne 0 ]; then
    echo "Run as root, for example:"
    echo "  sudo $0"
    exit 1
fi

install -m 0644 "$RULE_SRC" "$RULE_DST"
udevadm control --reload-rules

dev_path=""
for candidate in /sys/bus/usb/devices/*; do
    [ -f "$candidate/idVendor" ] || continue
    [ "$(cat "$candidate/idVendor")" = "0403" ] || continue
    [ "$(cat "$candidate/idProduct")" = "6011" ] || continue
    serial=$(cat "$candidate/serial" 2>/dev/null || true)
    [ "$serial" = "$SERIAL" ] || continue
    dev_path="$candidate"
    break
done

if [ -n "$dev_path" ]; then
    udevadm trigger --action=change "$dev_path" || true
    iface_path="${dev_path}:1.0"
    if [ -e "$iface_path/driver/unbind" ]; then
        printf '%s' "$(basename "$iface_path")" > "$iface_path/driver/unbind"
    fi
    udevadm trigger --action=change "$iface_path" || true
fi

echo "Installed $RULE_DST"
echo "If hw_server still shows no JTAG targets, unplug and replug the KV260 J4 USB cable."
