#!/bin/bash
# call-watch.sh — detect video call start/end and manage usbmon capture
#
# Watches /dev/video0 holder via fuser. On a transition to "held," starts
# a usbmon capture on the Kiyo's bus. On transition to "released," stops
# the capture and either:
#   - preserves it under kernel-patches/crash-evidence/auto-captures/
#     (compressed) if any kernel failure marker fired during the call
#   - deletes it if the call ran clean (v8.1 held; capture is just noise)
#
# Run from inside a Claude Monitor: every state transition emits a line
# to stdout, so the orchestrator gets per-event notifications.
#
# Stop with Ctrl-C / SIGTERM; cleanup runs via trap.

set -u

POLL_S=3
KIYO_BUS=2
AUTO_DIR="/home/jp/Projects/kiyo-xhci-fix/kernel-patches/crash-evidence/auto-captures"

mkdir -p "$AUTO_DIR"
sudo -n modprobe usbmon 2>/dev/null

state_describe() {
    # Returns "ACTIVE: <comm-list>" or "IDLE"
    local pids
    pids=$(fuser /dev/video0 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -u)
    if [ -z "$pids" ]; then
        echo "IDLE"
        return
    fi
    local comms
    comms=$(for p in $pids; do
                ps -p "$p" -o comm= 2>/dev/null
            done | sort -u | tr '\n' ',' | sed 's/,$//')
    echo "ACTIVE:$comms"
}

LAST_STATE="IDLE"
CAPTURE_PID=""
CAPTURE_FILE=""
CALL_START_LOCAL=""

stop_and_classify() {
    [ -z "$CAPTURE_PID" ] && return

    # Stop the capture
    sudo -n kill "$CAPTURE_PID" 2>/dev/null
    sleep 0.5

    # Take ownership so we can move/rename
    sudo -n chown jp:jp "$CAPTURE_FILE" 2>/dev/null

    local raw_size human_size crash_count
    raw_size=$(stat -c %s "$CAPTURE_FILE" 2>/dev/null || echo "0")
    human_size=$(numfmt --to=iec --suffix=B "$raw_size" 2>/dev/null || echo "${raw_size}B")

    # Did anything bad fire in dmesg during the call window?
    crash_count=$(sudo -n dmesg --since "$CALL_START_LOCAL" 2>/dev/null \
        | grep -cE "Failed to set UVC commit control|HC died|host controller not responding|Abort failed to stop" \
        || echo 0)

    if [ "$crash_count" -gt 0 ]; then
        local ts final
        ts=$(date -u +%Y%m%dT%H%M%SZ)
        final="$AUTO_DIR/CRASH-${ts}-${crash_count}events.txt"
        mv "$CAPTURE_FILE" "$final"
        gzip -9 "$final"
        echo "[$(date +%H:%M:%S)] CALL END — ${crash_count} CRASH EVENT(S) detected — preserved: $(basename ${final}.gz) (${human_size} raw)"
        echo "[$(date +%H:%M:%S)] dmesg failure tail:"
        sudo -n dmesg --since "$CALL_START_LOCAL" 2>/dev/null \
            | grep -E "Failed to set UVC commit control|HC died|host controller not responding|Abort failed to stop|Found UVC 1.00 device Razer" \
            | tail -8 | sed "s/^/    /"
    else
        rm -f "$CAPTURE_FILE"
        echo "[$(date +%H:%M:%S)] CALL END — CLEAN (${human_size} captured, deleted) — v8.1 held under real-world load"
    fi

    CAPTURE_PID=""
    CAPTURE_FILE=""
    CALL_START_LOCAL=""
}

cleanup_on_exit() {
    [ -n "$CAPTURE_PID" ] && stop_and_classify
    exit 0
}
trap cleanup_on_exit TERM INT EXIT

echo "[$(date +%H:%M:%S)] call-watch started — polling /dev/video0 every ${POLL_S}s"

while true; do
    state=$(state_describe)

    if [[ "$state" == ACTIVE:* ]] && [[ "$LAST_STATE" != ACTIVE:* ]]; then
        # Call start
        comms=${state#ACTIVE:}
        CALL_START_LOCAL=$(date '+%Y-%m-%d %H:%M:%S')
        TS=$(date -u +%Y%m%dT%H%M%SZ)
        CAPTURE_FILE="/tmp/auto-usbmon-${TS}.txt"
        sudo -n dd if=/sys/kernel/debug/usb/usbmon/${KIYO_BUS}u of="$CAPTURE_FILE" bs=4K 2>/dev/null &
        CAPTURE_PID=$!
        # Give dd a moment to actually start writing
        sleep 0.3
        if kill -0 "$CAPTURE_PID" 2>/dev/null; then
            echo "[$(date +%H:%M:%S)] CALL START — holder=${comms} — capturing bus ${KIYO_BUS} → $(basename $CAPTURE_FILE) (pid $CAPTURE_PID)"
        else
            echo "[$(date +%H:%M:%S)] CALL START — holder=${comms} — WARN capture failed to start"
            CAPTURE_PID=""
            CAPTURE_FILE=""
        fi
    elif [[ "$state" == "IDLE" ]] && [[ "$LAST_STATE" == ACTIVE:* ]]; then
        stop_and_classify
    fi

    LAST_STATE="$state"
    sleep "$POLL_S"
done
