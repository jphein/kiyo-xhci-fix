#!/bin/bash
# scarlett-storm-guard.sh — auto-kill PipeWire/ALSA URB retry storms
#
# Born 2026-08-19: twice today the Focusrite Scarlett 2i2 (usb 1-6) entered a
# no-backoff retry storm — PipeWire's ALSA layer looping snd_pcm_start against
# a wedged endpoint, hitting the kernel as "cannot submit urb 0, error -2:
# endpoint not enabled" at ~188 lines/sec. Consequences observed:
#   - 11:57 storm: evicted the entire ~3600-line dmesg ring every ~20s
#     (blinding dmesg-based tooling; call-watch/pre-call since moved to journald)
#   - 13:50 storm (triggered by the Kiyo camera being UNPLUGGED — its audio
#     function vanishing wedged PipeWire): escalated to real xHCI bandwidth
#     rejections on the port (-28, "Not enough bandwidth for altsetting"),
#     PipeWire SIGKILLed, gnome-shell segfault, whole Wayland session lost.
#
# The one intervention proven to stop a storm instantly (11:57, live) is
# suspending the Scarlett's PipeWire nodes: pactl suspend-sink/-source.
# Suspend closes the ALSA device, which tears down the retry loop and frees
# the wedged endpoint's stale bandwidth allocation; PipeWire re-opens the
# device cleanly on next use, so a brief suspend is non-destructive.
#
# Strategy:
#   storm detected (>= THRESHOLD kernel URB-error lines within WINDOW seconds
#   from the Scarlett's port) -> suspend all Scarlett sinks+sources ->
#   wait -> unsuspend (device usable again).
#   If a SECOND storm fires within RELAPSE_SEC, suspend and STAY suspended
#   (log loudly + desktop notification); manual `pactl suspend-sink <s> 0`
#   or a service restart re-arms.
#
# Follows the 05-30 usb-watchdog lesson: never block forever on a silent
# journal feed — persistent FD via process substitution + read -t health poll.
set -u

THRESHOLD=${STORM_THRESHOLD:-40}     # lines...
WINDOW=${STORM_WINDOW:-2}            # ...within this many seconds = storm
SETTLE=${STORM_SETTLE:-5}            # suspend duration before re-enable
RELAPSE_SEC=${STORM_RELAPSE:-120}    # 2nd storm within this = stay suspended
MATCH='cannot submit urb'

log() { echo "[$(date '+%H:%M:%S')] $1"; }

# Resolve the Scarlett's USB port fresh each time (it can re-enumerate).
scarlett_port() {
    local d
    for d in /sys/bus/usb/devices/[0-9]*-[0-9]*/; do
        case "$(cat "$d/product" 2>/dev/null)" in
            *Scarlett*) basename "$d"; return 0 ;;
        esac
    done
    return 1
}

scarlett_nodes() {
    # sinks and sources, monitors excluded (suspending the sink covers them)
    pactl list short sinks 2>/dev/null | awk '/[Ss]carlett/ && $2 !~ /\.monitor$/ {print "sink " $2}'
    pactl list short sources 2>/dev/null | awk '/[Ss]carlett/ && $2 !~ /\.monitor$/ {print "source " $2}'
}

set_suspend() {  # $1 = 1|0
    local kind name any=0
    while read -r kind name; do
        [ -z "$name" ] && continue
        pactl "suspend-$kind" "$name" "$1" 2>/dev/null && any=1
    done < <(scarlett_nodes)
    return $((1 - any))
}

notify() {
    notify-send -u critical "Scarlett storm guard" "$1" 2>/dev/null || true
}

log "armed: threshold ${THRESHOLD} lines/${WINDOW}s, settle ${SETTLE}s, relapse window ${RELAPSE_SEC}s"

LAST_STORM=0
LATCHED=0

while :; do
    # Persistent journal feed; --since now avoids replaying old storms.
    exec 3< <(journalctl -kf -o cat --since now 2>/dev/null | grep --line-buffered "$MATCH")

    count=0
    bucket_start=$SECONDS
    while :; do
        read -r -t 15 -u 3 line
        rc=$?
        if [ $rc -eq 0 ]; then
            now=$SECONDS
            if (( now - bucket_start > WINDOW )); then
                count=0; bucket_start=$now
            fi
            (( count++ ))
            if (( count >= THRESHOLD )); then
                port=$(scarlett_port || echo "?")
                # Only act if the storm is actually the Scarlett's port —
                # a different device storming is logged, not suppressed.
                if [ "$port" != "?" ] && ! echo "$line" | grep -q "usb $port"; then
                    log "storm on a NON-Scarlett device ($line) — not intervening"
                    count=0; continue
                fi
                if (( LAST_STORM > 0 && SECONDS - LAST_STORM < RELAPSE_SEC )); then
                    log "RELAPSE storm on $port — suspending Scarlett and STAYING suspended (unsuspend manually or restart this service)"
                    set_suspend 1 && LATCHED=1
                    notify "Second URB storm in ${RELAPSE_SEC}s — Scarlett suspended until you re-enable it."
                    LAST_STORM=$SECONDS
                else
                    log "STORM on $port (${count} lines/${WINDOW}s) — suspending Scarlett nodes for ${SETTLE}s"
                    if set_suspend 1; then
                        sleep "$SETTLE"
                        set_suspend 0
                        log "storm cut; Scarlett re-enabled"
                        notify "URB storm auto-stopped (suspended ${SETTLE}s, re-enabled)."
                    else
                        log "WARN: no Scarlett pactl nodes found / pactl failed — is PipeWire up?"
                    fi
                    LAST_STORM=$SECONDS
                fi
                count=0; bucket_start=$SECONDS
            fi
        elif [ $rc -gt 128 ]; then
            # timeout — quiet feed is normal, keep waiting (healthy idle poll)
            continue
        else
            # EOF — journalctl died; respawn the feed (05-30 deadlock lesson:
            # never assume the feed is immortal)
            break
        fi
    done
    exec 3<&-
    log "journal feed lost — respawning in 5s"
    sleep 5
done
