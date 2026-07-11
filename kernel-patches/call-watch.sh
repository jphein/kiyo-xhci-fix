#!/bin/bash
# call-watch.sh — detect video call start/end and manage usbmon capture
#
# Watches the Kiyo's V4L2 nodes via fuser. On a transition to "held," starts
# a usbmon capture on the Kiyo's bus. On transition to "released," stops
# the capture and either:
#   - preserves it under kernel-patches/crash-evidence/auto-captures/
#     (compressed) if any kernel failure marker fired during the call
#   - deletes it if the call ran clean (v8.1 held; capture is just noise) —
#     after extracting the reconfiguration counts (COMMITs/SET_INTERFACEs
#     survived), the exposure denominator for the two-phase-lock model
#
# Nodes and bus are resolved from sysfs each poll, NOT hardcoded: after a
# USB2 fallback the camera moves to bus 1 and its nodes shift (2026-07-10:
# /dev/video0 didn't exist, camera was video1/video2 — the old hardcoded
# poll went blind). Link-state transitions (SS/USB2/absent) are emitted as
# events for the same reason.
#
# Run under a Claude Monitor or as the call-watch user service: every state
# transition emits a line to stdout (→ journald), so the orchestrator gets
# per-event notifications.
#
# Stop with Ctrl-C / SIGTERM; cleanup runs via trap.

set -u

POLL_S=3
KIYO_VID=1532
KIYO_PID=0e05
AUTO_DIR="/home/jp/Projects/kiyo-xhci-fix/kernel-patches/crash-evidence/auto-captures"

mkdir -p "$AUTO_DIR"
sudo -n modprobe usbmon 2>/dev/null

kiyo_port() {
    # Current sysfs port of the Kiyo (e.g. "2-3" at SS, "1-3" after USB2
    # fallback), empty if absent.
    local d
    for d in /sys/bus/usb/devices/*/; do
        [ "$(cat "$d/idVendor"  2>/dev/null)" = "$KIYO_VID" ] && \
        [ "$(cat "$d/idProduct" 2>/dev/null)" = "$KIYO_PID" ] && { basename "$d"; return 0; }
    done
    return 1
}

kiyo_video_nodes() {
    # /dev/video* nodes belonging to the Kiyo, wherever it enumerated.
    local port="$1" v
    [ -z "$port" ] && return
    for v in /sys/bus/usb/devices/"$port"/*/video4linux/video*; do
        [ -e "$v" ] && echo "/dev/$(basename "$v")"
    done
}

state_describe() {
    # Returns "ACTIVE: <comm-list>" or "IDLE"
    local nodes pids
    nodes=$(kiyo_video_nodes "$1")
    [ -z "$nodes" ] && { echo "IDLE"; return; }
    # fuser: PIDs on stdout, filenames on stderr — safe to aggregate nodes
    pids=$(fuser $nodes 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -u)
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
LAST_LINK="unknown"
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
    # grep -c already prints "0" on no-match (and exits 1); use `|| true` to
    # swallow that exit without appending a second "0" (which produced a
    # "0\n0" crash_count and an "integer expression expected" error).
    crash_count=$(sudo -n dmesg --since "$CALL_START_LOCAL" 2>/dev/null \
        | grep -cE "timeout: still [0-9]+ active urbs|Failed to set UVC commit control|HC died|host controller not responding|Abort failed to stop" \
        || true)

    if [ "$crash_count" -gt 0 ]; then
        local ts final
        ts=$(date -u +%Y%m%dT%H%M%SZ)
        final="$AUTO_DIR/CRASH-${ts}-${crash_count}events.txt"
        mv "$CAPTURE_FILE" "$final"
        gzip -9 "$final"
        echo "[$(date +%H:%M:%S)] CALL END — ${crash_count} CRASH EVENT(S) detected — preserved: $(basename ${final}.gz) (${human_size} raw)"
        echo "[$(date +%H:%M:%S)] dmesg failure tail:"
        sudo -n dmesg --since "$CALL_START_LOCAL" 2>/dev/null \
            | grep -E "timeout: still [0-9]+ active urbs|Failed to set UVC commit control|HC died|host controller not responding|Abort failed to stop|Found UVC 1.00 device Razer" \
            | tail -8 | sed "s/^/    /"
    else
        # Reconfiguration counts before deleting — how many two-phase-lock
        # opportunities this call survived (usbmon text: SET_CUR wValue
        # 0x0200 = VS_COMMIT_CONTROL; bRequest 0x0b = SET_INTERFACE).
        local commits setintfs
        commits=$(LC_ALL=C grep -c 's 21 01 0200' "$CAPTURE_FILE" 2>/dev/null || true)
        setintfs=$(LC_ALL=C grep -c 's 01 0b ' "$CAPTURE_FILE" 2>/dev/null || true)
        rm -f "$CAPTURE_FILE"
        echo "[$(date +%H:%M:%S)] CALL END — CLEAN (${human_size} captured; survived ${commits:-?} COMMITs, ${setintfs:-?} SET_INTERFACEs; deleted) — v8.1 held under real-world load"
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

echo "[$(date +%H:%M:%S)] call-watch started — polling Kiyo video nodes every ${POLL_S}s"

while true; do
    PORT=$(kiyo_port || true)

    # Link-state transitions (2026-07-10: camera stranded at USB2 for hours
    # with nothing alerting; a stale SS-cycle can do that and only a physical
    # replug restores SuperSpeed — no VBUS switching on this board)
    if [ -z "$PORT" ]; then
        LINK="ABSENT"
    elif [ "$(cat "/sys/bus/usb/devices/$PORT/speed" 2>/dev/null)" = "5000" ]; then
        LINK="SS"
    else
        LINK="USB2"
    fi
    if [ "$LINK" != "$LAST_LINK" ]; then
        case "$LINK" in
            SS)     echo "[$(date +%H:%M:%S)] LINK — Kiyo at $PORT SuperSpeed (5000)" ;;
            USB2)   echo "[$(date +%H:%M:%S)] LINK WARN — Kiyo at USB2 ($PORT, speed=$(cat "/sys/bus/usb/devices/$PORT/speed" 2>/dev/null)) — bandwidth-limited; physical replug to restore SuperSpeed" ;;
            ABSENT) echo "[$(date +%H:%M:%S)] LINK WARN — Kiyo absent from all USB ports" ;;
        esac
        LAST_LINK="$LINK"
    fi

    state=$(state_describe "$PORT")

    if [[ "$state" == ACTIVE:* ]] && [[ "$LAST_STATE" != ACTIVE:* ]]; then
        # Call start — capture on whichever bus the camera is on NOW
        comms=${state#ACTIVE:}
        BUS="${PORT%%-*}"
        CALL_START_LOCAL=$(date '+%Y-%m-%d %H:%M:%S')
        TS=$(date -u +%Y%m%dT%H%M%SZ)
        CAPTURE_FILE="/tmp/auto-usbmon-${TS}.txt"
        sudo -n dd if=/sys/kernel/debug/usb/usbmon/${BUS}u of="$CAPTURE_FILE" bs=4K 2>/dev/null &
        CAPTURE_PID=$!
        # Give dd a moment to actually start writing
        sleep 0.3
        if kill -0 "$CAPTURE_PID" 2>/dev/null; then
            echo "[$(date +%H:%M:%S)] CALL START — holder=${comms} — capturing bus ${BUS} → $(basename $CAPTURE_FILE) (pid $CAPTURE_PID)"
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
