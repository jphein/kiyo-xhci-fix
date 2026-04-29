#!/bin/bash
# Sequential hammerint harness for one or more Kiyo Pros.
# Pairs Michal's hammerint.c reproducer with usb-watchdog.sh in test mode
# so we capture forensics on HC death and recover automatically.
#
# - Discovers all 1532:0e05 devices by sysfs path
# - For each: unbinds the others so libusb_open_device_with_vid_pid hits
#   the intended target, runs hammerint until HC dies / it returns / timeout,
#   waits for the watchdog's recovery cycle, then rebinds the others.
# - On a true wedge (recovery failed), aborts before testing further units.
#
# Source: hammerint.c attached to Michal Pecio's 2026-04-27 v5 2/3 reply.
# Save it as `hammerint.c` next to this script.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
WATCHDOG="$REPO_ROOT/usb-watchdog.sh"
SRC="$HERE/hammerint.c"
BIN="$HERE/hammerint"
RESULTS_ROOT="$HERE/results"

KIYO_VID="1532"
KIYO_PID="0e05"
HAMMER_TIMEOUT="${HAMMER_TIMEOUT:-120}"     # seconds per Kiyo before giving up
SETTLE_AFTER_HAMMER="${SETTLE_AFTER_HAMMER:-60}"   # max wait for watchdog post-hammer
MAX_RECOVERIES="${WATCHDOG_MAX_RECOVERIES:-1}"     # per-Kiyo cap

log() { echo "$(date -u +%H:%M:%SZ) [run-hammerint] $*"; }

bail() { log "FATAL: $*"; exit 2; }

# Discover Kiyos: returns sysfs paths (e.g., "2-1 2-2") on stdout.
discover_kiyos() {
    local paths=()
    for d in /sys/bus/usb/devices/*/; do
        [ -f "$d/idVendor" ] || continue
        [ "$(cat "$d/idVendor" 2>/dev/null)" = "$KIYO_VID" ] || continue
        [ "$(cat "$d/idProduct" 2>/dev/null)" = "$KIYO_PID" ] || continue
        # Skip interface entries — only top-level devices have idVendor anyway,
        # but be defensive: real device names match e.g. "2-1", "1-4.2"
        local b
        b=$(basename "$d")
        case "$b" in
            *:*) continue ;;
        esac
        paths+=("$b")
    done
    printf '%s\n' "${paths[@]}"
}

unbind_path() {
    local p="$1"
    [ -d "/sys/bus/usb/devices/$p" ] || return 0
    # Skip if already unbound (no driver symlink)
    [ -L "/sys/bus/usb/devices/$p/driver" ] || return 0
    echo "$p" | sudo tee /sys/bus/usb/drivers/usb/unbind >/dev/null 2>&1
}

# Bind a USB device path AND restore its configuration. Two gotchas:
#   1. Checking only the device dir's existence isn't enough — the device
#      can stay enumerated but unbound from the usb driver, in which case
#      we need to bind it.
#   2. After bind, the kernel does NOT auto-restore bConfigurationValue to
#      its prior value. Devices come back at config 0 with no interfaces.
#      libusb_claim_interface(0) then fails with errno=113 (detach failed)
#      because there's literally no interface to claim. Force config 1.
bind_path() {
    local p="$1"
    local devdir="/sys/bus/usb/devices/$p"
    [ -d "$devdir" ] || return 0   # device unplugged — nothing to do

    # Bind if missing the driver symlink
    if [ ! -L "$devdir/driver" ]; then
        echo "$p" | sudo tee /sys/bus/usb/drivers/usb/bind >/dev/null 2>&1
        sleep 1
    fi

    # Restore configuration if device came back unconfigured
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

[ -f "$SRC" ] || bail "$SRC not found — save Michal's attachment here first"
[ -x "$WATCHDOG" ] || bail "watchdog not found at $WATCHDOG"
pkg-config --exists libusb-1.0 || bail "libusb-1.0-dev not installed"

# Build (cheap; rebuild every run so we don't fight stale binaries)
log "building hammerint"
cc $(pkg-config --cflags libusb-1.0) "$SRC" -o "$BIN" $(pkg-config --libs libusb-1.0) \
    || bail "build failed"

mapfile -t INITIAL_KIYOS < <(discover_kiyos)
if [ "${#INITIAL_KIYOS[@]}" -eq 0 ]; then
    bail "no $KIYO_VID:$KIYO_PID devices found"
fi
log "found ${#INITIAL_KIYOS[@]} Kiyo(s): ${INITIAL_KIYOS[*]}"

TS="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="$RESULTS_ROOT/test-mode-$TS"
mkdir -p "$RUN_DIR"
log "results -> $RUN_DIR"

# Snapshot kernel/quirk state so we know what was configured during the run.
{
    echo "kernel: $(uname -r)"
    echo "cmdline: $(cat /proc/cmdline)"
    echo "kiyos_initial: ${INITIAL_KIYOS[*]}"
    echo "hammer_timeout: $HAMMER_TIMEOUT"
    echo "max_recoveries: $MAX_RECOVERIES"
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

    # Unbind every other Kiyo so libusb_open_device_with_vid_pid hits ours.
    others=()
    for o in "${NOW_KIYOS[@]}"; do
        [ "$o" = "$target" ] && continue
        others+=("$o")
        log "unbinding off-target $o"
        unbind_path "$o"
    done
    sleep 1

    # Spawn test-mode watchdog backgrounded (separate process from the persistent
    # service). It exits when MAX_RECOVERIES are hit or recovery fails.
    log "starting test-mode watchdog (max_recoveries=$MAX_RECOVERIES)"
    WATCHDOG_MODE=test \
    WATCHDOG_RESULTS_DIR="$cell_dir" \
    WATCHDOG_MAX_RECOVERIES="$MAX_RECOVERIES" \
        bash "$WATCHDOG" > "$cell_dir/watchdog.log" 2>&1 &
    WD_PID=$!
    sleep 2

    # Run hammerint. It loops forever on success — timeout caps the cycle.
    log "running: sudo timeout $HAMMER_TIMEOUT $BIN $KIYO_VID $KIYO_PID 0 85"
    HM_START=$(date +%s)
    sudo timeout "$HAMMER_TIMEOUT" "$BIN" "$KIYO_VID" "$KIYO_PID" 0 85 \
        > "$cell_dir/hammerint-stdout.log" 2>&1
    HM_RC=$?
    HM_ELAPSED=$(( $(date +%s) - HM_START ))
    log "hammerint exited rc=$HM_RC after ${HM_ELAPSED}s"
    {
        echo "rc: $HM_RC"
        echo "elapsed_seconds: $HM_ELAPSED"
        # Decode common rcs
        case "$HM_RC" in
            0)   echo "interpretation: hammerint exited cleanly (unexpected)" ;;
            124) echo "interpretation: timed out (didn't kill the HC)" ;;
            2)   echo "interpretation: open_device failed (device gone)" ;;
            3)   echo "interpretation: claim_interface failed" ;;
            4)   echo "interpretation: GET_STATUS short read (HC likely dying)" ;;
            5)   echo "interpretation: submit_transfer failed" ;;
            6)   echo "interpretation: cancel_transfer failed" ;;
            7)   echo "interpretation: handle_events failed" ;;
            *)   echo "interpretation: unknown rc" ;;
        esac
    } > "$cell_dir/hammerint.summary"

    # Give the watchdog up to SETTLE_AFTER_HAMMER seconds to finish recovery.
    log "waiting up to ${SETTLE_AFTER_HAMMER}s for watchdog to settle"
    SECS=0
    while kill -0 "$WD_PID" 2>/dev/null && [ "$SECS" -lt "$SETTLE_AFTER_HAMMER" ]; do
        sleep 2
        SECS=$((SECS + 2))
    done

    if kill -0 "$WD_PID" 2>/dev/null; then
        # No HC death this cycle — watchdog never tripped, so it's still tailing.
        log "no HC death observed (watchdog still idle). Terminating it."
        kill -TERM "$WD_PID" 2>/dev/null
        wait "$WD_PID" 2>/dev/null
        echo "verdict: no_death_in_window" > "$cell_dir/summary.log"
    fi

    # If watchdog reported wedge, stop here — controller is hung.
    if grep -q '^verdict: wedged' "$cell_dir/summary.log" 2>/dev/null; then
        log "WEDGED — controller did not recover. Aborting remaining cycles."
        ABORTED=1
        break
    fi

    # Rebind anything still detached (post-recovery, paths may need it).
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
    echo
    for cell in "$RUN_DIR"/kiyo-*; do
        [ -d "$cell" ] || continue
        echo "=== $(basename "$cell") ==="
        cat "$cell/hammerint.summary" 2>/dev/null
        echo "watchdog summary:"
        cat "$cell/summary.log" 2>/dev/null || echo "(no summary)"
        echo
    done
} > "$RUN_DIR/SUMMARY.log"

log "complete. SUMMARY -> $RUN_DIR/SUMMARY.log"
