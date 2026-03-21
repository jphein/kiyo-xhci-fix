#!/bin/bash
# Test CTRL_THROTTLE patch in isolation (without NO_LPM quirk)
# Must be run with sudo. Turn off camera in Meet/Chrome first.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCHED_KO="$SCRIPT_DIR/uvcvideo-patched.ko"
ROUNDS="${1:-50}"
EVIDENCE_DIR="$SCRIPT_DIR/crash-evidence"
LOG="$EVIDENCE_DIR/ctrl-throttle-test-$(date +%Y%m%d-%H%M%S).log"

restore() {
    echo "" | tee -a "$LOG"
    echo "=== Restoring stock module and quirk ===" | tee -a "$LOG"
    rmmod uvcvideo 2>/dev/null || true
    sleep 1
    modprobe uvcvideo 2>/dev/null || true
    echo "1532:0e05:n" > /sys/module/usbcore/parameters/quirks
    echo "  Restored: stock uvcvideo + NO_LPM quirk" | tee -a "$LOG"
}
trap restore EXIT

if [ ! -f "$PATCHED_KO" ]; then
    echo "ERROR: $PATCHED_KO not found. Run build-uvc-module.sh first."
    exit 1
fi

echo "=== CTRL_THROTTLE Isolation Test ===" | tee "$LOG"
echo "Rounds: $ROUNDS" | tee -a "$LOG"
echo "Patched module: $PATCHED_KO" | tee -a "$LOG"
echo "" | tee -a "$LOG"

# Step 1: Pin deps, kill camera users, swap module — all in one shot to avoid race
echo "[1/3] Swapping to patched uvcvideo module..." | tee -a "$LOG"

# Pin dependencies so rmmod doesn't cascade
modprobe videobuf2-vmalloc 2>/dev/null || true
modprobe videobuf2-v4l2 2>/dev/null || true
modprobe videodev 2>/dev/null || true

# Kill anything holding the camera so rmmod succeeds
if fuser /dev/video0 >/dev/null 2>&1; then
    echo "  Killing processes using /dev/video0..." | tee -a "$LOG"
    fuser -k /dev/video0 2>/dev/null || true
    sleep 1
fi

rmmod uvcvideo 2>/dev/null || true
sleep 1

# Verify deps survived, reload if needed
if ! lsmod | grep -q videobuf2_v4l2; then
    modprobe videobuf2-v4l2 2>/dev/null || true
fi

insmod "$PATCHED_KO" 2>&1 | tee -a "$LOG"
if [ $? -ne 0 ]; then
    echo "  ERROR: insmod failed. Check: journalctl -k --since '30 sec ago'" | tee -a "$LOG"
    exit 1
fi
sleep 3
echo "  Patched module loaded" | tee -a "$LOG"

# Step 2: Remove NO_LPM quirk (do this AFTER module swap to minimize unprotected window)
echo "[2/3] Removing NO_LPM quirk..." | tee -a "$LOG"
echo "" > /sys/module/usbcore/parameters/quirks
echo "  NO_LPM removed — CTRL_THROTTLE is the only protection" | tee -a "$LOG"

# Step 3: Verify Kiyo and run stress test
echo "[3/3] Running stress test ($ROUNDS rounds)..." | tee -a "$LOG"
if lsusb | grep -q "1532:0e05"; then
    echo "  Kiyo present" | tee -a "$LOG"
else
    echo "  WARNING: Kiyo not found in lsusb" | tee -a "$LOG"
fi
echo "" | tee -a "$LOG"

# Capture kernel log in background
journalctl -k -f --no-pager >> "$LOG" 2>&1 &
JPID=$!

REAL_USER=$(logname 2>/dev/null || echo "${SUDO_USER:-root}")
sudo -u "$REAL_USER" bash "$SCRIPT_DIR/stress-test-kiyo.sh" "$ROUNDS" 2>&1 | tee -a "$LOG"

kill $JPID 2>/dev/null || true
echo "" | tee -a "$LOG"

# Post-test health check (restore happens via trap)
echo "=== Post-test health check ===" | tee -a "$LOG"
if lsusb | grep -q "1532:0e05"; then
    echo "  Kiyo still alive — CTRL_THROTTLE held" | tee -a "$LOG"
else
    echo "  KIYO GONE — crash occurred, CTRL_THROTTLE insufficient alone" | tee -a "$LOG"
fi

ERRORS=$(journalctl -k --since "2 min ago" --no-pager | grep -ciE 'HC died|not responding' || true)
echo "  Fatal xHCI errors: $ERRORS" | tee -a "$LOG"

echo "" | tee -a "$LOG"
echo "Log saved to: $LOG"
# restore() runs automatically via trap EXIT
