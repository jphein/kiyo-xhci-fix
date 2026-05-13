#!/bin/bash
# test-probe-commit-cycle.sh — discriminate rate-hypothesis from
# sequence-hypothesis for the Razer Kiyo Pro firmware hang.
#
# WHY THIS EXISTS
#
# The existing stress-test-kiyo.sh hammers SET_CUR repeatedly and was
# enough to confirm UVC_QUIRK_CTRL_THROTTLE at 50ms is sufficient under
# rate stress. But real-world Brave WebRTC use produced 4 commit-control
# timeouts in 41 minutes at uniform 50ms (and at least one suspect event
# at uniform 100ms — pending re-validation). Synthetic SET_CUR flooding
# under-represents the real-world failure mode.
#
# Hypothesis: the dangerous operation is COMMIT specifically, following
# a recent PROBE — not aggregate rate. WebRTC renegotiates format on
# bandwidth changes, which forces fresh probe+commit pairs at irregular
# intervals. This script reproduces that pattern.
#
# WHAT IT DOES
#
# Each cycle:
#   1. Open /dev/videoN
#   2. Set a video format (issues PROBE_CONTROL on the wire)
#   3. Stream a few frames (issues COMMIT_CONTROL + alt-setting)
#   4. Close (issues StreamOff)
#   5. Reopen with a different format (forces fresh probe/commit pair)
#
# This is the v4l2 equivalent of "the user joined the call, the call
# renegotiated to 720p, then to 1080p, then to 480p" — which is exactly
# what we saw on the wire when the crashes fired.
#
# USAGE
#
#   ./test-probe-commit-cycle.sh
#   CYCLES=200 ./test-probe-commit-cycle.sh           # longer run
#   INTERVAL_MS=500 ./test-probe-commit-cycle.sh      # slower pacing
#   DEV=/dev/video2 ./test-probe-commit-cycle.sh      # other camera
#
# Exits 0 on a clean run, 1 the moment a kernel failure marker appears.
#
# DISCRIMINATING THE HYPOTHESES
#
# Run this script three times with the *current quirk active*:
#   1. INTERVAL_MS=0      (back-to-back hot-restarts)
#   2. INTERVAL_MS=250    (modest pacing)
#   3. INTERVAL_MS=1000   (relaxed pacing)
#
# Hypothesis A (rate-only): all three should pass if the quirk's
# uniform throttle is sufficient. If any fails, the uniform throttle
# is too short.
#
# Hypothesis B (sequence-dependent): run 1 will fail, runs 2/3 will
# pass. The failure correlates with hot-restart cadence, not absolute
# transfer rate within a cycle. The fix is the COMMIT-specific extra
# delay added in v8.1.
#
# A truly definitive run also captures usbmon in parallel:
#   ./capture-usbmon.sh &
#   sleep 1
#   ./test-probe-commit-cycle.sh
#   # then kill the usbmon capture, examine in Wireshark

set -u

CYCLES="${CYCLES:-50}"
INTERVAL_MS="${INTERVAL_MS:-0}"
DEV="${DEV:-/dev/video0}"

# Formats to rotate through. Picked to match what Brave/Chromium WebRTC
# actually negotiates: a 480p/720p/1080p ladder in MJPG plus a YUYV
# fallback (Chromium prefers YUYV for low-res for processing efficiency).
# Every consecutive pair forces a fresh probe→commit because dimensions
# and/or pixelformat differ.
FORMATS=(
    "640x480 30 MJPG"
    "1280x720 30 MJPG"
    "1920x1080 30 MJPG"
    "1280x720 30 YUYV"
    "640x480 30 YUYV"
)

if ! command -v v4l2-ctl >/dev/null 2>&1; then
    echo "FATAL: v4l2-ctl not found. Install with: sudo apt install v4l-utils"
    exit 2
fi

if [ ! -e "$DEV" ]; then
    echo "FATAL: $DEV not present — is the Kiyo enumerated? Check lsusb."
    exit 2
fi

# Verify our device is actually the Kiyo (running this against the wrong
# camera would corrupt results without explaining anything)
prod=$(v4l2-ctl -d "$DEV" --info 2>/dev/null | awk -F': ' '/Card type/{print $2}')
case "$prod" in
    *Razer*Kiyo*) : ;;
    *) echo "WARNING: $DEV reports '$prod', not Razer Kiyo Pro. Continuing anyway." ;;
esac

# Time-mark for filtering dmesg to only events since the script started
START_TS="$(date '+%Y-%m-%d %H:%M:%S')"

# Check if any kernel failure marker appeared since START_TS.
# Uses sudo -n for dmesg because Ubuntu defaults to kernel.dmesg_restrict=1.
check_for_failure() {
    sudo -n dmesg --since "$START_TS" 2>/dev/null \
        | grep -qE "Failed to set UVC commit control|HC died|host controller not responding|Abort failed to stop"
}

echo "==========================================================="
echo "test-probe-commit-cycle started at $START_TS"
echo "  device:    $DEV  ($prod)"
echo "  cycles:    $CYCLES"
echo "  interval:  ${INTERVAL_MS}ms between cycles"
echo "  formats:   ${#FORMATS[@]} rotating (forces fresh probe/commit each cycle)"
echo "==========================================================="

success=0
v4l2_errs=0
for ((i=1; i<=CYCLES; i++)); do
    fmt_idx=$(( (i - 1) % ${#FORMATS[@]} ))
    fmt="${FORMATS[$fmt_idx]}"
    width=$(echo "$fmt" | cut -d' ' -f1 | cut -dx -f1)
    height=$(echo "$fmt" | cut -d' ' -f1 | cut -dx -f2)
    fps=$(echo "$fmt" | cut -d' ' -f2)
    pix=$(echo "$fmt" | cut -d' ' -f3)

    # 3 frames at 30fps is ~100ms — enough to drive STREAMON / STREAMOFF
    # paths fully (which trigger SET_INTERFACE alt-setting + URB submit/
    # cancel). --stream-to=/dev/null discards the frame data so we don't
    # bottleneck on disk I/O.
    out=$(v4l2-ctl -d "$DEV" \
        --set-fmt-video="width=$width,height=$height,pixelformat=$pix" \
        --set-parm="$fps" \
        --stream-mmap=3 --stream-count=3 \
        --stream-to=/dev/null 2>&1)
    rc=$?
    printf '[%3d/%d] %-23s ' "$i" "$CYCLES" "$fmt"
    if [ "$rc" -ne 0 ]; then
        echo "v4l2-ctl rc=$rc"
        v4l2_errs=$((v4l2_errs + 1))
        # A v4l2-ctl error doesn't necessarily mean the kernel crashed
        # (could be format-not-supported, no buffers, etc). Only the
        # dmesg check below decides whether to bail.
    else
        echo "ok"
        success=$((success + 1))
    fi

    if check_for_failure; then
        echo
        echo "==========================================================="
        echo "KERNEL FAILURE DETECTED at cycle $i"
        echo "==========================================================="
        echo "Dmesg context (since script start):"
        sudo -n dmesg --since "$START_TS" 2>/dev/null | tail -50 \
            || dmesg | tail -50
        echo
        echo "Last v4l2-ctl output:"
        echo "$out" | head -20
        exit 1
    fi

    if [ "$INTERVAL_MS" -gt 0 ]; then
        sleep "$(awk -v ms="$INTERVAL_MS" 'BEGIN{print ms/1000}')"
    fi
done

echo
echo "==========================================================="
echo "Completed $CYCLES cycles, $success successful, $v4l2_errs v4l2 errors"
echo "No kernel failure markers observed."
echo "==========================================================="
exit 0
