#!/usr/bin/env bash
# capture-flash.sh — Capture USB traffic during Razer Kiyo Pro firmware flash
#
# Prerequisites:
#   sudo modprobe usbmon
#   sudo apt install tshark   (optional, for better decoded output)
#
# Usage:
#   sudo ./capture-flash.sh [--tshark] [--firmware /path/to/firmware.bin]
#
# Output:
#   /tmp/kiyo-flash-capture-<timestamp>.{usbmon-raw.txt,pcap}
#   /tmp/kiyo-flash-capture-<timestamp>.parsed.txt
#
# The flash tool uses raw USB control transfers (USBDEVFS_CONTROL ioctl)
# to send UVC class requests to Extension Unit 6 on the Razer Kiyo Pro.
# usbmon captures these at the bus level, showing the setup packet bytes.
#
# UVC control transfer setup packet layout:
#   bmRequestType  bRequest  wValue    wIndex    wLength
#   0x21 (SET_CUR) 0x01      CS<<8|0   Unit<<8|IF  len
#   0xA1 (GET_CUR) 0x81      CS<<8|0   Unit<<8|IF  len
#
# For XU6, IF=0:
#   sel=3: wValue=0x0300, wIndex=0x0600, wLength=0x0020 (32 bytes)
#   sel=4: wValue=0x0400, wIndex=0x0600, wLength=0x0008 (8 bytes)
#   sel=5: wValue=0x0500, wIndex=0x0600, wLength=0x0008 (8 bytes)

set -euo pipefail

FIRMWARE="/tmp/razer-fw/fwimage-patched.bin"
FLASH_TOOL="/home/jp/Projects/kiyo-xhci-fix/firmware-analysis/kiyo-flash.py"
USE_TSHARK=false
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
CAPTURE_BASE="/tmp/kiyo-flash-capture-${TIMESTAMP}"

# --- Parse args ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --tshark) USE_TSHARK=true; shift ;;
        --firmware) FIRMWARE="$2"; shift 2 ;;
        *) shift ;;
    esac
done

# --- Determine USB bus and device number ---
BUS=$(lsusb -d 1532:0e05 | head -1 | sed 's/Bus \([0-9]*\).*/\1/' | sed 's/^0*//')
DEV=$(lsusb -d 1532:0e05 | head -1 | sed 's/.*Device \([0-9]*\).*/\1/' | sed 's/^0*//')

if [ -z "$BUS" ]; then
    echo "ERROR: Razer Kiyo Pro (1532:0e05) not found on USB bus."
    exit 1
fi

echo "=== Kiyo Flash USB Capture ==="
echo "Bus: $BUS, Device: $DEV"
echo "Firmware: $FIRMWARE"
echo "Output base: $CAPTURE_BASE"
echo ""

# --- Ensure usbmon is loaded ---
if ! lsmod | grep -q usbmon; then
    echo "Loading usbmon kernel module..."
    modprobe usbmon
fi

# Verify usbmon text interface exists
USBMON_TEXT="/sys/kernel/debug/usb/usbmon/${BUS}u"
if [ ! -r "$USBMON_TEXT" ]; then
    echo "ERROR: Cannot read $USBMON_TEXT"
    echo "  1. sudo modprobe usbmon"
    echo "  2. mount -t debugfs none /sys/kernel/debug"
    echo "  3. Run as root (sudo)"
    exit 1
fi

echo "usbmon text interface: $USBMON_TEXT"
echo ""

# --- Start pcap capture (tshark or tcpdump) ---
CAPTURE_PID=""
if $USE_TSHARK && command -v tshark &>/dev/null; then
    echo "[Capture] Using tshark on usbmon${BUS}..."
    PCAP_FILE="${CAPTURE_BASE}.pcap"
    tshark -i "usbmon${BUS}" -w "$PCAP_FILE" 2>/dev/null &
    CAPTURE_PID=$!
    echo "  tshark PID: $CAPTURE_PID, pcap: $PCAP_FILE"
elif command -v tcpdump &>/dev/null; then
    echo "[Capture] Using tcpdump on usbmon${BUS}..."
    PCAP_FILE="${CAPTURE_BASE}.pcap"
    tcpdump -i "usbmon${BUS}" -w "$PCAP_FILE" 2>/dev/null &
    CAPTURE_PID=$!
    echo "  tcpdump PID: $CAPTURE_PID, pcap: $PCAP_FILE"
fi

# Always capture raw usbmon text (most parseable format)
RAW_FILE="${CAPTURE_BASE}.usbmon-raw.txt"
cat "$USBMON_TEXT" > "$RAW_FILE" &
RAW_PID=$!
echo "Raw usbmon: $RAW_FILE (PID: $RAW_PID)"
echo ""

sleep 0.5

# --- Run the flash tool ---
echo "=========================================="
echo "[Flash] Running: python3 $FLASH_TOOL flash-normal --firmware $FIRMWARE --force"
echo "=========================================="
echo ""

python3 "$FLASH_TOOL" flash-normal --firmware "$FIRMWARE" --force
FLASH_EXIT=$?

echo ""
echo "[Flash] Exit code: $FLASH_EXIT"

# Catch trailing USB traffic
sleep 1

# --- Stop captures ---
echo ""
echo "Stopping captures..."
if [ -n "$CAPTURE_PID" ]; then
    kill "$CAPTURE_PID" 2>/dev/null || true
    wait "$CAPTURE_PID" 2>/dev/null || true
fi
kill "$RAW_PID" 2>/dev/null || true
wait "$RAW_PID" 2>/dev/null || true

echo ""
echo "=== Capture files ==="
ls -lh "${CAPTURE_BASE}"* 2>/dev/null
echo ""

# --- Parse the raw usbmon output ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PARSE_SCRIPT="${SCRIPT_DIR}/parse-usbmon.sh"
if [ -x "$PARSE_SCRIPT" ]; then
    PARSED_FILE="${CAPTURE_BASE}.parsed.txt"
    "$PARSE_SCRIPT" "$RAW_FILE" "$DEV" | tee "$PARSED_FILE"
    echo ""
    echo "Parsed output saved: $PARSED_FILE"
else
    echo "Parse script not found at $PARSE_SCRIPT"
    echo "Run manually after creating it."
fi

echo ""
echo "=== Done ==="
if [ -f "${CAPTURE_BASE}.pcap" ]; then
    echo "Open in Wireshark:  wireshark ${CAPTURE_BASE}.pcap"
fi
echo "Raw usbmon text:    $RAW_FILE"
echo "Re-parse:           $PARSE_SCRIPT $RAW_FILE $DEV"
