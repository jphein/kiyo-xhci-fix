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

# Derive the root port the Kiyo last occupied from kernel messages.
# Matches lines like "uvcvideo 2-3:1.1: ..." and "usb 2-3: timeout: still N active urbs".
# Falls back to sysfs scan (device present), then to the env override or hardcoded default.
_derive_kiyo_port() {
    # Try uvcvideo log lines first — most specific.
    # journalctl -k is used (not dmesg) since dmesg requires CAP_SYSLOG on this system.
    local p
    p=$(journalctl -k --no-pager 2>/dev/null | grep -oP 'uvcvideo \K[0-9]+-[0-9]+(?=:[0-9]+\.[0-9]+)' | tail -1)
    [ -n "$p" ] && { echo "$p"; return; }
    # Fall back to generic usb timeout lines
    p=$(journalctl -k --no-pager 2>/dev/null | grep -oP 'usb \K[0-9]+-[0-9]+(?=: timeout:)' | tail -1)
    [ -n "$p" ] && { echo "$p"; return; }
    # Fall back to sysfs (works when device is still present — rare case for this script)
    for d in /sys/bus/usb/devices/*/; do
        [ "$(cat "$d/idVendor"  2>/dev/null)" = "$KIYO_VID" ] && \
        [ "$(cat "$d/idProduct" 2>/dev/null)" = "$KIYO_PID" ] && { basename "$d"; return; }
    done
    echo "${KIYO_ROOTPORT_FALLBACK:-2-3}"
}

# Override with KIYO_ROOTPORT=<bus>-<port> to skip auto-detection.
KIYO_ROOTPORT="${KIYO_ROOTPORT:-$(_derive_kiyo_port)}"

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

kiyo_speed() { cat "/sys/bus/usb/devices/$1/speed" 2>/dev/null; }

# A link cycle can strand the Kiyo on its USB2 pins: observed 2026-06-10, the
# SS-port cycle came back as 1-3 @480 (with benign -71 descriptor noise from
# the failed SS training). Cycling the port the device CURRENTLY occupies —
# the HS-side one — makes it retrain SuperSpeed.
retrain_superspeed() {
    local node="$1" dis
    dis=$(port_disable_path "$node")
    [ -e "$dis" ] || { echo "  WARN: no disable attr at $dis — replug to restore SuperSpeed"; return 1; }
    echo "  Kiyo at $node speed=$(kiyo_speed "$node") (USB2 fallback) — cycling HS-side port to retrain SS..."
    echo 1 | sudo tee "$dis" >/dev/null
    sleep 3
    echo 0 | sudo tee "$dis" >/dev/null
    sleep 6
}

if node=$(find_kiyo); then
    if [ "$(kiyo_speed "$node")" = "5000" ]; then
        echo "Kiyo already present at $node (SuperSpeed) — nothing to revive."
        ls /dev/video* 2>/dev/null
        exit 0
    fi
    # Present but degraded — a prior cycle/recovery left it at USB2.
    retrain_superspeed "$node"
    if node=$(find_kiyo) && [ "$(kiyo_speed "$node")" = "5000" ]; then
        echo "SUCCESS: Kiyo retrained to SuperSpeed at $node."
        ls /dev/video* 2>/dev/null
        exit 0
    fi
    echo "Kiyo present but not SuperSpeed — physically replug it."
    exit 1
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
    if [ "$(kiyo_speed "$node")" != "5000" ]; then
        retrain_superspeed "$node"
        node=$(find_kiyo) || { echo "Kiyo vanished during SS retrain — physically replug it."; exit 1; }
    fi
    if [ "$(kiyo_speed "$node")" = "5000" ]; then
        echo "SUCCESS: Kiyo back at $node (SuperSpeed) — no physical replug needed."
    else
        echo "PARTIAL: Kiyo back at $node but speed=$(kiyo_speed "$node") (USB2) — works degraded; replug to restore SuperSpeed."
    fi
    ls /dev/video* 2>/dev/null
    exit 0
fi

echo "Port-cycle did not revive it — the firmware needs a true VBUS cycle."
echo "ACTION: physically unplug and replug the Kiyo."
exit 1
