#!/bin/bash
# capture-usbmon.sh — record raw USB wire traffic for the Kiyo Pro's bus
#
# Run this BEFORE joining a video call. If a crash happens during the call,
# the resulting .usbmon file gives byte-for-byte UVC control sequence the
# WebRTC stack sent immediately before the firmware stalled — discriminating
# rate-hypothesis from sequence-hypothesis directly, and giving Mathias/Michal
# wire-level data instead of just dmesg.
#
# Output: /tmp/kiyo-usbmon-<ISO-timestamp>.bin
# Stop the capture with Ctrl-C; the dd process is logged to stdout so you can
# `kill` it from another shell if needed.
#
# Bus 2 is hardcoded — that's where the Kiyo lives on JP's machine. Pass
# BUS=N to override (e.g., BUS=3 for the secondary controller).
#
# Filtering: post-process with tshark / Wireshark — open the .bin as
# "Linux USB capture (libpcap)". Filter by interface address to see only
# Kiyo traffic (interface bus.device, e.g. "2.2" for Bus 002 Dev 002).
#
# References:
#   Documentation/usb/usbmon.rst (kernel tree)
#   Wireshark's "USB capture format" docs

set -e

BUS="${BUS:-2}"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="/tmp/kiyo-usbmon-${TS}.bin"

# usbmon is a module on most distros. Loaded already on JP's machine
# (Ubuntu 6.17), but try anyway — fails silently if already present.
sudo modprobe usbmon 2>/dev/null || true

SRC="/sys/kernel/debug/usb/usbmon/${BUS}u"
if [ ! -r "$SRC" ]; then
    echo "usbmon source $SRC is not readable. Possible causes:"
    echo "  - debugfs not mounted: sudo mount -t debugfs none /sys/kernel/debug"
    echo "  - usbmon module not loaded: sudo modprobe usbmon"
    echo "  - You need to run this script with sudo for the dd"
    exit 1
fi

echo "Recording bus $BUS in binary form (suitable for Wireshark)"
echo "  Output: $OUT"
echo "  Stop with Ctrl-C, or kill the dd PID printed below"
echo

# `1u` is text format; `Nu` is binary (mon_bin). Binary is what Wireshark
# expects. We use dd with bs=1M and unlimited count.
exec sudo dd if="$SRC" of="$OUT" bs=1M status=progress
