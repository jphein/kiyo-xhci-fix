#!/bin/bash
# revive-kiyo.sh — bring a firmware-locked Razer Kiyo Pro back WITHOUT a
# physical replug, by software-cycling its USB root port.
#
# Use after an xHCI crash where the watchdog recovered the controller but the
# Kiyo stays absent ("usb 2-1: device not accepting address, error -71"). The
# firmware lock sometimes clears on the controller rebind and sometimes does
# not; when it does not, this is the no-cable alternative to unplugging it.
#
# Best-effort: a USB3 root-port "disable" is a link-level cycle, not guaranteed
# VBUS removal. If the firmware needs a true power cycle, fall back to a
# physical replug — this script will tell you.
#
# Status: EXPERIMENTAL (introduced 2026-05-30). Not yet folded into
# usb-watchdog.sh — validate it survives a few real locks first.
set -u

KIYO_VID=1532
KIYO_PID=0e05
# The bus-port the Kiyo sits on — it must be on its own root port (see the
# hub-isolation finding). Override with KIYO_ROOTPORT=<bus>-<port> if it moves.
KIYO_ROOTPORT="${KIYO_ROOTPORT:-2-1}"

find_kiyo() {
    local d
    for d in /sys/bus/usb/devices/*/; do
        [ "$(cat "$d/idVendor" 2>/dev/null)"  = "$KIYO_VID" ] && \
        [ "$(cat "$d/idProduct" 2>/dev/null)" = "$KIYO_PID" ] && { basename "$d"; return 0; }
    done
    return 1
}

# Map a root bus-port "B-P" to its hub-port "disable" attribute.
port_disable_path() {
    local bp="$1"
    local bus="${bp%%-*}"
    local port="${bp#*-}"
    echo "/sys/bus/usb/devices/${bus}-0:1.0/usb${bus}-port${port}/disable"
}

if node=$(find_kiyo); then
    echo "Kiyo already present at $node — nothing to revive."
    ls /dev/video* 2>/dev/null
    exit 0
fi

echo "Kiyo absent (firmware locked). Software port-cycle on root port $KIYO_ROOTPORT ..."
DIS=$(port_disable_path "$KIYO_ROOTPORT")
# The disable attr is root-owned (writes go through sudo tee), so test for
# existence, not user-writability — a `[ -w ]` check is always false for $USER.
if [ -e "$DIS" ]; then
    echo 1 | sudo tee "$DIS" >/dev/null && echo "  port disabled  ($DIS)"
    sleep 3
    echo 0 | sudo tee "$DIS" >/dev/null && echo "  port re-enabled"
    sleep 6
else
    echo "  WARN: $DIS not found — wrong port? (override with KIYO_ROOTPORT=<bus>-<port>)"
fi

if node=$(find_kiyo); then
    echo "SUCCESS: Kiyo back at $node — no physical replug needed."
    ls /dev/video* 2>/dev/null
    exit 0
fi

echo "Port-cycle did not revive it — the firmware needs a true VBUS cycle."
echo "ACTION: physically unplug and replug the Kiyo."
exit 1
