#!/bin/bash
# Matrix runner — runs one (cell, workload, rep) and records a verdict.
#
# Exits 0 on clean completion (PASS or soft-FAIL), exits 100 on HC death
# (caller should reboot). Exits >0 on script error.
#
# Usage: runner.sh <cell> <workload> <rep>
#   cell:     1 | 2 | 3 | 4 | 5  (see README for matrix)
#   workload: spam-only | spam-stream
#   rep:      positive integer

set -u

CELL="${1:?cell required}"
WORKLOAD="${2:?workload required}"
REP="${3:?rep required}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
STRESS_TEST="$REPO_DIR/stress-test-kiyo.sh"
RESULTS_DIR="$SCRIPT_DIR/results"
RUN_DIR="$RESULTS_DIR/cell${CELL}_${WORKLOAD}_rep${REP}"
SUMMARY="$RESULTS_DIR/summary.tsv"

mkdir -p "$RUN_DIR"

log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$RUN_DIR/runner.log"; }

# --- Expected boot config per cell ----------------------------------------
# Cells differ in:
#   kernel:  stock=regular 6.17, michal=6.17 + michal-xhci-test.patch
#   cmdline: whether usbcore.quirks=1532:0e05:k is present
#   module:  whether uvcvideo-patched.ko (CTRL_THROTTLE) is loaded

case "$CELL" in
    1) EXPECT_KERNEL=stock  ; EXPECT_NOLPM=0 ; EXPECT_THROTTLE=0 ;;
    2) EXPECT_KERNEL=michal ; EXPECT_NOLPM=0 ; EXPECT_THROTTLE=0 ;;
    3) EXPECT_KERNEL=stock  ; EXPECT_NOLPM=1 ; EXPECT_THROTTLE=0 ;;
    4) EXPECT_KERNEL=stock  ; EXPECT_NOLPM=1 ; EXPECT_THROTTLE=1 ;;
    5) EXPECT_KERNEL=michal ; EXPECT_NOLPM=1 ; EXPECT_THROTTLE=1 ;;
    *) echo "bad cell: $CELL" >&2 ; exit 2 ;;
esac

# --- Validate current boot matches expected config ------------------------
KVER=$(uname -r)
CMDLINE=$(cat /proc/cmdline)
HAS_NOLPM=0
grep -q 'usbcore.quirks=.*1532:0e05:k' /proc/cmdline && HAS_NOLPM=1

# Heuristic: if uname includes "michal" or "xhci-test", assume Michal kernel.
# Otherwise stock. Override by setting KIYO_MATRIX_KERNEL_OVERRIDE=michal|stock.
KERNEL_KIND="${KIYO_MATRIX_KERNEL_OVERRIDE:-}"
if [ -z "$KERNEL_KIND" ]; then
    if echo "$KVER" | grep -qiE 'michal|xhci-test'; then
        KERNEL_KIND=michal
    else
        KERNEL_KIND=stock
    fi
fi

# Throttle module state: look for the CTRL_THROTTLE symbol in the loaded module
HAS_THROTTLE=0
if modinfo uvcvideo 2>/dev/null | grep -q 'filename.*uvcvideo-patched'; then
    HAS_THROTTLE=1
fi
# Fallback: check /sys for the quirk sysfs attribute if we added one (not in v7)
# Or check module source path — if loaded from our patched .ko
LOADED_PATH=$(awk '/^uvcvideo/ {exit} END {print}' /proc/modules >/dev/null 2>&1 || true)

if [ "$KERNEL_KIND" != "$EXPECT_KERNEL" ] || [ "$HAS_NOLPM" != "$EXPECT_NOLPM" ]; then
    # Kernel / cmdline mismatches need a reboot — can't fix here
    log "CONFIG MISMATCH (kernel/cmdline) for cell $CELL — reboot required"
    log "  expected: kernel=$EXPECT_KERNEL nolpm=$EXPECT_NOLPM"
    log "  got:      kernel=$KERNEL_KIND   nolpm=$HAS_NOLPM"
    log "  uname -r: $KVER"
    log "  cmdline:  $CMDLINE"
    echo -e "${CELL}\t${WORKLOAD}\t${REP}\tSKIP\tconfig-mismatch\t$(date -Iseconds)" >> "$SUMMARY"
    echo "SKIP: config mismatch (needs reboot)" > "$RUN_DIR/verdict"
    exit 3
fi

# Module mismatch is fixable in-place (rmmod / modprobe)
if [ "$HAS_THROTTLE" != "$EXPECT_THROTTLE" ]; then
    log "Swapping uvcvideo module: throttle $HAS_THROTTLE -> $EXPECT_THROTTLE"
    sudo rmmod uvcvideo 2>&1 | tee -a "$RUN_DIR/runner.log" || true
    sleep 1
    if [ "$EXPECT_THROTTLE" = "1" ]; then
        PATCHED="$REPO_DIR/kernel-patches/uvcvideo-patched.ko"
        if [ ! -f "$PATCHED" ]; then
            log "ABORT: patched module not found at $PATCHED"
            echo -e "${CELL}\t${WORKLOAD}\t${REP}\tSKIP\tno-patched-ko\t$(date -Iseconds)" >> "$SUMMARY"
            echo "SKIP: uvcvideo-patched.ko missing" > "$RUN_DIR/verdict"
            exit 3
        fi
        sudo insmod "$PATCHED" 2>&1 | tee -a "$RUN_DIR/runner.log" || true
    else
        sudo modprobe uvcvideo 2>&1 | tee -a "$RUN_DIR/runner.log" || true
    fi
    sleep 3  # let uvcvideo re-enumerate
    # Re-check
    HAS_THROTTLE=0
    if modinfo uvcvideo 2>/dev/null | grep -q 'filename.*uvcvideo-patched'; then
        HAS_THROTTLE=1
    fi
    if [ "$HAS_THROTTLE" != "$EXPECT_THROTTLE" ]; then
        log "ABORT: module swap did not take effect"
        echo -e "${CELL}\t${WORKLOAD}\t${REP}\tSKIP\tmodule-swap-failed\t$(date -Iseconds)" >> "$SUMMARY"
        echo "SKIP: module swap failed" > "$RUN_DIR/verdict"
        exit 3
    fi
fi

log "=== Cell $CELL ($EXPECT_KERNEL kernel, nolpm=$EXPECT_NOLPM, throttle=$EXPECT_THROTTLE) ==="
log "Workload: $WORKLOAD  Rep: $REP"

# --- Capture environment --------------------------------------------------
{
    echo "kernel: $KVER"
    echo "cmdline: $CMDLINE"
    echo "date: $(date -Iseconds)"
    echo "--- lsusb ---"
    lsusb 2>&1 | grep -i 'razer\|1532' || true
    echo "--- modinfo uvcvideo ---"
    modinfo uvcvideo 2>&1 | grep -E 'filename|version|srcversion' || true
    echo "--- lsmod | grep usb ---"
    lsmod | grep -E 'usb|uvc' || true
} > "$RUN_DIR/env.txt"

# --- Pre-run checks -------------------------------------------------------
if ! v4l2-ctl -d /dev/video0 --get-ctrl=brightness >/dev/null 2>&1; then
    log "Camera not responding before test — skipping"
    echo -e "${CELL}\t${WORKLOAD}\t${REP}\tSKIP\tcamera-down-pre\t$(date -Iseconds)" >> "$SUMMARY"
    echo "SKIP: camera down before run" > "$RUN_DIR/verdict"
    exit 3
fi

# --- Dmesg snapshot cursor ------------------------------------------------
DMESG_CURSOR=$(sudo dmesg --since='1 second ago' 2>/dev/null | wc -l)
sudo dmesg --ctime 2>&1 > "$RUN_DIR/dmesg.pre" || true

# --- Enable dynamic debug for the run -------------------------------------
DD_STATE=$(cat /sys/kernel/debug/dynamic_debug/control 2>/dev/null \
    | grep -cE 'module (xhci_hcd|usbcore).*=p' || true)
sudo sh -c 'echo "module xhci_hcd +p" > /sys/kernel/debug/dynamic_debug/control' 2>/dev/null || true
sudo sh -c 'echo "module usbcore +p"  > /sys/kernel/debug/dynamic_debug/control' 2>/dev/null || true

# --- Run workload ---------------------------------------------------------
STREAM_PID=""
STREAM_LOG="$RUN_DIR/stream.log"
if [ "$WORKLOAD" = "spam-stream" ]; then
    log "Starting 120s v4l2 stream in background"
    (ffmpeg -hide_banner -loglevel warning \
        -f v4l2 -input_format mjpeg -framerate 30 -video_size 1920x1080 \
        -i /dev/video0 -t 120 -f null - 2>&1) > "$STREAM_LOG" &
    STREAM_PID=$!
    sleep 2  # let stream settle
fi

log "Running stress-test 100 rounds, 0ms delay"
timeout 180 bash "$STRESS_TEST" 100 0 > "$RUN_DIR/workload.log" 2>&1
STRESS_EXIT=$?

if [ -n "$STREAM_PID" ]; then
    wait "$STREAM_PID" 2>/dev/null || true
fi

log "Stress-test exit: $STRESS_EXIT"

# --- Disable dynamic debug ------------------------------------------------
sudo sh -c 'echo "module xhci_hcd -p" > /sys/kernel/debug/dynamic_debug/control' 2>/dev/null || true
sudo sh -c 'echo "module usbcore -p"  > /sys/kernel/debug/dynamic_debug/control' 2>/dev/null || true

# --- Capture post-run dmesg delta -----------------------------------------
sleep 2  # let any trailing errors land
sudo dmesg --ctime 2>&1 > "$RUN_DIR/dmesg.post" || true
diff "$RUN_DIR/dmesg.pre" "$RUN_DIR/dmesg.post" | grep '^>' | sed 's/^> //' \
    > "$RUN_DIR/dmesg.delta" || true

# --- Determine verdict ----------------------------------------------------
VERDICT=""
REASON=""

if grep -qE 'xhci_hc_died|HC died|Host halt failed|probably busted' "$RUN_DIR/dmesg.delta"; then
    VERDICT=FAIL
    REASON=hc-died
elif grep -qE 'event condition 198' "$RUN_DIR/dmesg.delta"; then
    VERDICT=FAIL
    REASON=event-198
elif ! v4l2-ctl -d /dev/video0 --get-ctrl=brightness >/dev/null 2>&1; then
    VERDICT=FAIL
    REASON=camera-unresponsive-post
elif [ "$STRESS_EXIT" -eq 124 ]; then
    VERDICT=FAIL
    REASON=stress-test-timeout
elif [ "$STRESS_EXIT" -ne 0 ]; then
    VERDICT=FAIL
    REASON=stress-test-exit-$STRESS_EXIT
elif grep -qE 'Stop Endpoint.*timeout|Command timeout.*USBSTS' "$RUN_DIR/dmesg.delta"; then
    VERDICT=WARN
    REASON=stop-ep-timeout-no-hc-death
else
    VERDICT=PASS
    REASON=clean
fi

log "VERDICT: $VERDICT ($REASON)"
echo "$VERDICT: $REASON" > "$RUN_DIR/verdict"
echo -e "${CELL}\t${WORKLOAD}\t${REP}\t${VERDICT}\t${REASON}\t$(date -Iseconds)" >> "$SUMMARY"

# --- Signal caller whether reboot is needed -------------------------------
if [ "$REASON" = "hc-died" ] || [ "$REASON" = "event-198" ] \
   || [ "$REASON" = "camera-unresponsive-post" ]; then
    log "Reboot required to recover"
    exit 100
fi

exit 0
