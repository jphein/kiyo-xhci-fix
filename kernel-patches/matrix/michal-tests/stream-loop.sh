#!/bin/bash
# Michal's stream-open/close loop test.
# Asked 2026-04-13 (Test 1 walk-through), nudged 2026-04-27.
# Goal: reproduce HC death with stock kernel + stock uvcvideo, no quirks.

set -u

DEVICE="${DEVICE:-/dev/video0}"
DURATION_SEC="${DURATION_SEC:-600}"
LOG_DIR="${LOG_DIR:-$(dirname "$0")/results}"
# Format must be set explicitly on every v4l2-ctl invocation. Without it the
# Kiyo Pro driver returns VIDIOC_REQBUFS = -EINVAL and the loop spins on
# REQBUFS failures instead of actually streaming. MJPG 1920x1080 @ 30fps
# matches the typical Twitch/Zoom use case and exercises the firmware's
# hardware-accelerated MJPEG path — same hot path Michal's hammerint found
# firmware-locking on.
WIDTH="${WIDTH:-1920}"
HEIGHT="${HEIGHT:-1080}"
PIXFMT="${PIXFMT:-MJPG}"
FPS="${FPS:-30}"
SET_FMT="--set-fmt-video=width=$WIDTH,height=$HEIGHT,pixelformat=$PIXFMT --set-parm=$FPS"

mkdir -p "$LOG_DIR"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
LOG="$LOG_DIR/stream-loop_${TS}.log"
DMESG_PRE="$LOG_DIR/stream-loop_${TS}.dmesg.pre"
DMESG_POST="$LOG_DIR/stream-loop_${TS}.dmesg.post"

echo "=== Pre-flight ===" | tee "$LOG"
uname -r | tee -a "$LOG"
lsmod | grep -E '^(uvcvideo|xhci_)' | tee -a "$LOG"
cat /proc/cmdline | tee -a "$LOG"
echo | tee -a "$LOG"

if [[ ! -e "$DEVICE" ]]; then
    echo "FATAL: $DEVICE not found" | tee -a "$LOG"
    exit 2
fi

dmesg --since '1 second ago' > "$DMESG_PRE" 2>/dev/null || dmesg -t > "$DMESG_PRE"

echo "=== Streaming config: $WIDTH x $HEIGHT $PIXFMT @ ${FPS}fps ===" | tee -a "$LOG"
echo "=== Warm-up: open and close the device once ===" | tee -a "$LOG"
v4l2-ctl -d "$DEVICE" $SET_FMT --stream-mmap --stream-count=10 --stream-to=/dev/null 2>&1 | tee -a "$LOG"
sleep 2

echo | tee -a "$LOG"
echo "=== Streaming loop (will run for ${DURATION_SEC}s or until kill) ===" | tee -a "$LOG"
START=$(date +%s)
ITER=0
while true; do
    ITER=$((ITER + 1))
    NOW=$(date +%s)
    if (( NOW - START >= DURATION_SEC )); then
        echo "Reached duration cap ${DURATION_SEC}s after $ITER iters" | tee -a "$LOG"
        break
    fi
    if ! v4l2-ctl -d "$DEVICE" $SET_FMT --stream-mmap --stream-count=1 --stream-to=/dev/null \
            >>"$LOG" 2>&1; then
        echo "iter $ITER: v4l2-ctl failed (rc=$?)" | tee -a "$LOG"
        if ! [[ -e "$DEVICE" ]]; then
            echo "DEVICE DISAPPEARED at iter $ITER" | tee -a "$LOG"
            break
        fi
    fi
    if (( ITER % 50 == 0 )); then
        echo "iter $ITER ($(( NOW - START ))s elapsed) ok" | tee -a "$LOG"
    fi
done

dmesg --since "${DURATION_SEC} seconds ago" > "$DMESG_POST" 2>/dev/null || dmesg -t > "$DMESG_POST"

echo | tee -a "$LOG"
echo "=== Verdict ===" | tee -a "$LOG"
if grep -qE 'xhci_hc_died|HC died|Host halt failed|probably busted' "$DMESG_POST"; then
    echo "FAIL: HC died" | tee -a "$LOG"
elif grep -qE 'event condition 198' "$DMESG_POST"; then
    echo "FAIL: event-198 (HC probably busted)" | tee -a "$LOG"
elif grep -qE 'Command timeout|Stop Endpoint timeout' "$DMESG_POST"; then
    echo "WARN: command timeout, no HC death" | tee -a "$LOG"
else
    echo "PASS: clean (or just didn't reproduce in this run)" | tee -a "$LOG"
fi

echo "Log: $LOG"
echo "Dmesg pre/post: $DMESG_PRE $DMESG_POST"
