#!/bin/bash
# pre-call.sh — pre-call stability ritual for the Razer Kiyo Pro
#
# Born 2026-06-10: the first clean v8.1 real-world call (61-min Brave/Meet,
# crash-evidence/2026-06-10-v8.1-clean-call/) started from a fresh enumeration
# minutes earlier; both prior v8.1 failures (05-30, 06-06) had long-lived
# camera state. Until we know whether v8.1 or fresh firmware state deserves
# the credit, run this before every call:
#
#   1. Verify the v8.1 DKMS module is the loaded uvcvideo (srcversion match)
#   2. Verify the usb-watchdog user service is running
#   3. Refuse to cycle while something holds /dev/video0
#   4. Link-level port cycle → fresh enumeration (fresh firmware state)
#   5. Detect USB2 fallback (SS link doesn't always retrain — observed
#      2026-06-10) and fix it by cycling the HS-side port
#   6. Verify final state: SuperSpeed (5000), autosuspend pinned off,
#      no precursors fired during the dance
#
# Exit 0 = green light, join the call. Non-zero = read the output.
set -u

KIYO_VID=1532
KIYO_PID=0e05
FAIL=0

say()  { echo "  $1"; }
ok()   { echo "  [ok]   $1"; }
warn() { echo "  [WARN] $1"; }
bad()  { echo "  [FAIL] $1"; FAIL=1; }

find_kiyo() {
    local d
    for d in /sys/bus/usb/devices/*/; do
        [ "$(cat "$d/idVendor"  2>/dev/null)" = "$KIYO_VID" ] && \
        [ "$(cat "$d/idProduct" 2>/dev/null)" = "$KIYO_PID" ] && { basename "$d"; return 0; }
    done
    return 1
}

kiyo_speed() {
    local p="$1"
    cat "/sys/bus/usb/devices/$p/speed" 2>/dev/null
}

# Map "B-P" to the hub-port disable attribute (root ports only).
port_disable_path() {
    local bus="${1%%-*}" port="${1#*-}"
    echo "/sys/bus/usb/devices/${bus}-0:1.0/usb${bus}-port${port}/disable"
}

cycle_port() {
    local dis
    dis=$(port_disable_path "$1")
    [ -e "$dis" ] || { warn "no disable attr at $dis"; return 1; }
    echo 1 | sudo -n tee "$dis" >/dev/null
    sleep 3
    echo 0 | sudo -n tee "$dis" >/dev/null
    sleep 7
}

echo "=== pre-call ritual ($(date '+%H:%M:%S')) ==="

# --- 1. patched module loaded? -------------------------------------------
DKMS_KO="/lib/modules/$(uname -r)/updates/dkms/uvcvideo.ko.zst"
LOADED=$(cat /sys/module/uvcvideo/srcversion 2>/dev/null)
ONDISK=$(sudo -n /usr/sbin/modinfo -F srcversion "$DKMS_KO" 2>/dev/null)
if [ -z "$LOADED" ]; then
    bad "uvcvideo not loaded at all"
elif [ ! -e "$DKMS_KO" ]; then
    warn "no DKMS uvcvideo for this kernel ($(uname -r)) — running STOCK uvcvideo (rebuild: dkms install uvcvideo-kiyo/1.0)"
elif [ "$LOADED" = "$ONDISK" ]; then
    ok "v8.1 DKMS uvcvideo loaded (srcversion $LOADED)"
else
    bad "loaded uvcvideo ($LOADED) != DKMS build ($ONDISK) — stale module, reload before the call"
fi

# --- 2. watchdog alive? ----------------------------------------------------
if systemctl --user is-active --quiet usb-watchdog.service; then
    ok "usb-watchdog active (Level 0 early intervention armed)"
else
    bad "usb-watchdog NOT running — start it: systemctl --user start usb-watchdog"
fi

# --- 3. camera present and idle? -------------------------------------------
PORT=$(find_kiyo) || { bad "Kiyo not found on any USB port — plug it in / run revive-kiyo.sh"; echo; exit 1; }
if fuser /dev/video0 >/dev/null 2>&1; then
    bad "something is holding /dev/video0 — close it first, then re-run (cycling a held camera kills its stream)"
    echo; exit 1
fi
say "Kiyo at $PORT speed=$(kiyo_speed "$PORT") — cycling for fresh enumeration..."

# --- 4. fresh enumeration ---------------------------------------------------
CYCLE_T0=$(date '+%Y-%m-%d %H:%M:%S')
cycle_port "$PORT"
PORT=$(find_kiyo) || { bad "Kiyo did not re-enumerate — physically replug it"; echo; exit 1; }

# --- 5. USB2 fallback? (observed 2026-06-10: SS link may not retrain) ------
if [ "$(kiyo_speed "$PORT")" != "5000" ]; then
    warn "came back at $PORT speed=$(kiyo_speed "$PORT") (USB2 fallback) — cycling HS-side port to retrain SuperSpeed"
    cycle_port "$PORT"
    PORT=$(find_kiyo) || { bad "Kiyo did not re-enumerate after retrain — physically replug it"; echo; exit 1; }
fi

# --- 6. final verification ---------------------------------------------------
SPEED=$(kiyo_speed "$PORT")
if [ "$SPEED" = "5000" ]; then
    ok "fresh enumeration at $PORT, SuperSpeed (5000)"
else
    bad "still at speed=$SPEED — SS link won't retrain; physically replug the camera"
fi

PWR=$(cat "/sys/bus/usb/devices/$PORT/power/control" 2>/dev/null)
if [ "$PWR" = "on" ]; then
    ok "autosuspend pinned off (udev rule applied)"
else
    warn "power/control=$PWR — udev rule didn't apply? (expected 'on')"
fi

# Precursors during the dance? (probe-control -32 is a benign per-enumeration
# artifact and deliberately NOT matched — see 2026-06-10 RESULTS.md)
PRECURSORS=$(sudo -n dmesg --since "$CYCLE_T0" 2>/dev/null \
    | grep -cE "timeout: still [0-9]+ active urbs|Failed to set UVC commit control|HC died" || true)
if [ "${PRECURSORS:-0}" -eq 0 ]; then
    ok "no precursors during re-enumeration"
else
    bad "$PRECURSORS precursor line(s) fired during the cycle — check dmesg before joining"
fi

echo
if [ "$FAIL" -eq 0 ]; then
    echo "GREEN LIGHT — join the call. (Optional: run call-watch.sh for usbmon auto-capture.)"
else
    echo "NOT GREEN — fix the [FAIL] items above before joining."
fi
exit "$FAIL"
