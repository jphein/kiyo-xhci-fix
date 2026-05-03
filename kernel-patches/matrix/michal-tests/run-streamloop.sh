#!/bin/bash
# Sequential stream-mmap loop harness for one or more Kiyo Pros.
# Pairs Michal's stream-loop.sh reproducer with usb-watchdog.sh in test mode
# so we capture forensics on HC death and recover automatically.
#
# - Discovers all 1532:0e05 devices by sysfs path
# - Maps each to its /dev/videoN streaming endpoint (interface :1.0)
# - Per Kiyo: unbinds the others, starts test-mode watchdog, runs stream-loop
#   under sudo (dmesg needs CAP_SYS_ADMIN), waits for watchdog to settle on
#   HC death, rebinds the others.
# - On a true wedge (recovery failed), aborts before testing further units.
#
# Mirrors run-hammerint.sh.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
WATCHDOG="$REPO_ROOT/usb-watchdog.sh"
STREAMLOOP="$HERE/stream-loop.sh"
RESULTS_ROOT="$HERE/results"

KIYO_VID="1532"
KIYO_PID="0e05"
DURATION_SEC="${DURATION_SEC:-300}"                 # per Kiyo
SETTLE_AFTER_LOOP="${SETTLE_AFTER_LOOP:-60}"        # max wait for watchdog post-loop
MAX_RECOVERIES="${WATCHDOG_MAX_RECOVERIES:-1}"      # per-Kiyo cap

log() { echo "$(date -u +%H:%M:%SZ) [run-streamloop] $*"; }
bail() { log "FATAL: $*"; exit 2; }

discover_kiyos() {
    local paths=()
    for d in /sys/bus/usb/devices/*/; do
        [ -f "$d/idVendor" ] || continue
        [ "$(cat "$d/idVendor" 2>/dev/null)" = "$KIYO_VID" ] || continue
        [ "$(cat "$d/idProduct" 2>/dev/null)" = "$KIYO_PID" ] || continue
        local b
        b=$(basename "$d")
        case "$b" in *:*) continue ;; esac
        paths+=("$b")
    done
    printf '%s\n' "${paths[@]}"
}

# Map sysfs port (e.g., "2-1") to /dev/videoN. Each Kiyo exposes a main +
# metadata pair; we want the lowest-numbered child of interface :1.0.
find_video_for_port() {
    local port="$1"
    local lowest=""
    for v in /sys/bus/usb/devices/$port:1.0/video4linux/video* \
             /sys/bus/usb/devices/$port:*/video4linux/video*; do
        [ -d "$v" ] || continue
        local name
        name="$(basename "$v")"
        if [ -z "$lowest" ] || [ "$name" \< "$lowest" ]; then
            lowest="$name"
        fi
    done
    [ -n "$lowest" ] || return 1
    echo "/dev/$lowest"
}

unbind_path() {
    local p="$1"
    [ -d "/sys/bus/usb/devices/$p" ] || return 0
    [ -L "/sys/bus/usb/devices/$p/driver" ] || return 0
    echo "$p" | sudo tee /sys/bus/usb/drivers/usb/unbind >/dev/null 2>&1
}

# Bind path AND restore bConfigurationValue. After watchdog rebind the device
# may come back at config 0 with no interfaces — write 1 to revive it.
# Same gotcha hammerint hit (commit 655ea16).
bind_path() {
    local p="$1"
    local devdir="/sys/bus/usb/devices/$p"
    [ -d "$devdir" ] || return 0
    if [ ! -L "$devdir/driver" ]; then
        echo "$p" | sudo tee /sys/bus/usb/drivers/usb/bind >/dev/null 2>&1
        sleep 1
    fi
    local cfg_file="$devdir/bConfigurationValue"
    if [ -f "$cfg_file" ]; then
        local cfg
        cfg=$(cat "$cfg_file" 2>/dev/null)
        if [ -z "$cfg" ] || [ "$cfg" = "0" ]; then
            echo 1 | sudo tee "$cfg_file" >/dev/null 2>&1
            sleep 1
        fi
    fi
}

# --- Pre-flight ----------------------------------------------------------

[ -x "$STREAMLOOP" ] || bail "$STREAMLOOP not found or not executable"
[ -x "$WATCHDOG" ]   || bail "watchdog not found at $WATCHDOG"
command -v v4l2-ctl >/dev/null || bail "v4l2-ctl not installed (apt: v4l-utils)"

mapfile -t INITIAL_KIYOS < <(discover_kiyos)
if [ "${#INITIAL_KIYOS[@]}" -eq 0 ]; then
    bail "no $KIYO_VID:$KIYO_PID devices found"
fi
log "found ${#INITIAL_KIYOS[@]} Kiyo(s): ${INITIAL_KIYOS[*]}"

# Michal's Test 1 spec: stock kernel + stock uvcvideo, no quirks.
QUIRK_ACTIVE=0
if grep -q 'usbcore.quirks=1532:0e05' /proc/cmdline 2>/dev/null; then
    QUIRK_ACTIVE=1
    log "WARN: usbcore.quirks=1532:0e05:k is active — Test 1 spec wants no quirks"
    log "WARN: results will be tagged quirk_active=1 (reboot into VANILLA grub entry for clean run)"
fi

TS="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="$RESULTS_ROOT/streamloop-$TS"
mkdir -p "$RUN_DIR"
log "results -> $RUN_DIR"

{
    echo "kernel: $(uname -r)"
    echo "cmdline: $(cat /proc/cmdline)"
    echo "kiyos_initial: ${INITIAL_KIYOS[*]}"
    echo "duration_sec: $DURATION_SEC"
    echo "max_recoveries: $MAX_RECOVERIES"
    echo "quirk_active: $QUIRK_ACTIVE"
    echo
    lsusb
} > "$RUN_DIR/run-baseline.log"

# --- Persistent watchdog handoff ----------------------------------------

PERSIST_WAS_RUNNING=0
if systemctl --user is-active usb-watchdog.service >/dev/null 2>&1; then
    PERSIST_WAS_RUNNING=1
    log "stopping persistent watchdog for duration of test"
    systemctl --user stop usb-watchdog.service
fi

cleanup() {
    log "cleanup: rebinding any unbound Kiyos"
    for p in "${INITIAL_KIYOS[@]}"; do
        bind_path "$p"
    done
    if [ "$PERSIST_WAS_RUNNING" -eq 1 ]; then
        log "cleanup: restarting persistent watchdog"
        systemctl --user start usb-watchdog.service
    fi
}
trap cleanup EXIT INT TERM

# --- Per-Kiyo loop -------------------------------------------------------

ABORTED=0
for target in "${INITIAL_KIYOS[@]}"; do
    cell_dir="$RUN_DIR/kiyo-$target"
    mkdir -p "$cell_dir"
    log "=== Target: Kiyo at sysfs path $target -> $cell_dir ==="

    # Re-discover at iteration start (after a recovery, paths can shift).
    mapfile -t NOW_KIYOS < <(discover_kiyos)
    if ! printf '%s\n' "${NOW_KIYOS[@]}" | grep -qx "$target"; then
        log "WARN: target $target no longer present (post-recovery drift?). Skipping."
        echo "skipped: target absent" > "$cell_dir/result.log"
        continue
    fi

    others=()
    for o in "${NOW_KIYOS[@]}"; do
        [ "$o" = "$target" ] && continue
        others+=("$o")
        log "unbinding off-target $o"
        unbind_path "$o"
    done
    sleep 2  # let udev settle so /dev/videoN renumbers stay stable

    DEVICE="$(find_video_for_port "$target" || true)"
    if [ -z "$DEVICE" ] || [ ! -e "$DEVICE" ]; then
        log "FATAL: no /dev/video* found for $target"
        echo "skipped: no v4l device" > "$cell_dir/result.log"
        for o in "${others[@]}"; do bind_path "$o"; done
        continue
    fi
    log "target device: $DEVICE"

    log "starting test-mode watchdog (max_recoveries=$MAX_RECOVERIES)"
    WATCHDOG_MODE=test \
    WATCHDOG_RESULTS_DIR="$cell_dir" \
    WATCHDOG_MAX_RECOVERIES="$MAX_RECOVERIES" \
        bash "$WATCHDOG" > "$cell_dir/watchdog.log" 2>&1 &
    WD_PID=$!
    sleep 2

    # Run stream-loop under sudo so dmesg --since works under
    # kernel.dmesg_restrict=1. Pass DEVICE/DURATION/LOG_DIR via -E.
    log "running stream-loop.sh DEVICE=$DEVICE DURATION_SEC=$DURATION_SEC"
    SL_START=$(date +%s)
    DEVICE="$DEVICE" \
    DURATION_SEC="$DURATION_SEC" \
    LOG_DIR="$cell_dir" \
        sudo -E bash "$STREAMLOOP" > "$cell_dir/streamloop-stdout.log" 2>&1
    SL_RC=$?
    SL_ELAPSED=$(( $(date +%s) - SL_START ))
    log "stream-loop exited rc=$SL_RC after ${SL_ELAPSED}s"
    {
        echo "rc: $SL_RC"
        echo "elapsed_seconds: $SL_ELAPSED"
        echo "device: $DEVICE"
    } > "$cell_dir/streamloop.summary"

    log "waiting up to ${SETTLE_AFTER_LOOP}s for watchdog to settle"
    SECS=0
    while kill -0 "$WD_PID" 2>/dev/null && [ "$SECS" -lt "$SETTLE_AFTER_LOOP" ]; do
        sleep 2
        SECS=$((SECS + 2))
    done

    if kill -0 "$WD_PID" 2>/dev/null; then
        log "no HC death observed (watchdog still idle). Terminating it."
        kill -TERM "$WD_PID" 2>/dev/null
        wait "$WD_PID" 2>/dev/null
        echo "verdict: no_death_in_window" > "$cell_dir/summary.log"
    fi

    if grep -q '^verdict: wedged' "$cell_dir/summary.log" 2>/dev/null; then
        log "WEDGED — controller did not recover. Aborting remaining cycles."
        ABORTED=1
        break
    fi

    for o in "${others[@]}"; do
        bind_path "$o"
    done

    log "done with $target"
    sleep 5
done

# --- Roll-up summary -----------------------------------------------------

{
    echo "run: $RUN_DIR"
    echo "ts: $TS"
    echo "aborted: $ABORTED"
    echo "quirk_active: $QUIRK_ACTIVE"
    echo
    for cell in "$RUN_DIR"/kiyo-*; do
        [ -d "$cell" ] || continue
        echo "=== $(basename "$cell") ==="
        cat "$cell/streamloop.summary" 2>/dev/null
        echo "watchdog summary:"
        cat "$cell/summary.log" 2>/dev/null || echo "(no summary)"
        echo "stream-loop verdict:"
        grep -hE '^(FAIL|PASS|WARN):' "$cell"/stream-loop_*.log 2>/dev/null || echo "(no verdict in cell)"
        echo
    done
} > "$RUN_DIR/SUMMARY.log"

log "complete. SUMMARY -> $RUN_DIR/SUMMARY.log"
