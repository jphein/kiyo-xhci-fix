#!/bin/bash
# Stress test Razer Kiyo Pro — exercises controls that trigger -32 EPIPE crashes
# Run alongside: journalctl -k -f | grep -i 'xhci\|uvc\|kiyo\|error'
#
# Usage: bash stress-test-kiyo.sh [rounds] [delay_ms]  (default 50 rounds, 0ms delay)

DEV=/dev/video0
ROUNDS=${1:-50}
DELAY_MS=${2:-0}
PASS=0
FAIL=0

# Convert ms to seconds for sleep
if [ "$DELAY_MS" -gt 0 ] 2>/dev/null; then
    DELAY_S=$(awk "BEGIN {printf \"%.3f\", $DELAY_MS/1000}")
else
    DELAY_S=""
fi

ctrl() {
    v4l2-ctl -d "$DEV" "$@" 2>/dev/null
    [ -n "$DELAY_S" ] && sleep "$DELAY_S"
}

echo "=== Razer Kiyo Pro Stress Test ==="
echo "Device: $DEV"
echo "Rounds: $ROUNDS"
echo "Delay: ${DELAY_MS}ms between controls"
echo "Watch logs in another terminal: journalctl -k -f | grep -i 'xhci\|uvc\|error'"
echo ""

check_alive() {
    v4l2-ctl -d "$DEV" --get-ctrl=brightness >/dev/null 2>&1
}

if ! check_alive; then
    echo "ABORT: $DEV not responding"
    exit 1
fi

for i in $(seq 1 $ROUNDS); do
    printf "Round %3d/%d: " "$i" "$ROUNDS"

    # Toggle autofocus (known crash trigger)
    ctrl --set-ctrl=focus_automatic_continuous=0 2>/dev/null
    ctrl --set-ctrl=focus_absolute=300 2>/dev/null
    ctrl --set-ctrl=focus_automatic_continuous=1 2>/dev/null

    # Slam white balance
    ctrl --set-ctrl=white_balance_automatic=0 2>/dev/null
    ctrl --set-ctrl=white_balance_temperature=2000 2>/dev/null
    ctrl --set-ctrl=white_balance_temperature=7500 2>/dev/null
    ctrl --set-ctrl=white_balance_automatic=1 2>/dev/null

    # Slam exposure
    ctrl --set-ctrl=auto_exposure=1 2>/dev/null
    ctrl --set-ctrl=exposure_time_absolute=3 2>/dev/null
    ctrl --set-ctrl=exposure_time_absolute=2047 2>/dev/null
    ctrl --set-ctrl=auto_exposure=3 2>/dev/null

    # Pan/tilt/zoom slam
    ctrl --set-ctrl=zoom_absolute=400 2>/dev/null
    ctrl --set-ctrl=pan_absolute=-36000 2>/dev/null
    ctrl --set-ctrl=tilt_absolute=36000 2>/dev/null
    ctrl --set-ctrl=zoom_absolute=100 2>/dev/null
    ctrl --set-ctrl=pan_absolute=0 2>/dev/null
    ctrl --set-ctrl=tilt_absolute=0 2>/dev/null

    # Rapid brightness/contrast/saturation cycling
    for val in 0 255 128; do
        ctrl --set-ctrl=brightness=$val 2>/dev/null
        ctrl --set-ctrl=contrast=$val 2>/dev/null
        ctrl --set-ctrl=saturation=$val 2>/dev/null
    done

    # Verify device still alive
    if check_alive; then
        echo "OK"
        ((PASS++))
    else
        echo "FAILED — device not responding!"
        ((FAIL++))
        sleep 3
        if ! check_alive; then
            echo ""
            echo "ABORT: Device dead after round $i. Check journalctl -k for crash details."
            echo "Results: $PASS passed, $FAIL failed out of $i rounds"
            exit 1
        fi
        echo "  Device recovered after 3s pause"
    fi

    sleep 0.2
done

echo ""
echo "=== Complete ==="
echo "Results: $PASS passed, $FAIL failed out of $ROUNDS rounds"
if [ "$FAIL" -eq 0 ]; then
    echo "No crashes detected — quirks are holding."
fi
