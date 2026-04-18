#!/bin/bash
# Queue processor — pops next rep from queue.txt, runs it, reboots if
# runner asks. Intended to be invoked by systemd on boot AND by hand.
#
# Queue format: one line per rep, tab-separated:
#   <cell>\t<workload>\t<rep>
# Consumed lines are removed; on success moved to done.txt.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="$SCRIPT_DIR/results"
QUEUE="$RESULTS_DIR/queue.txt"
DONE="$RESULTS_DIR/done.txt"
LOG="$RESULTS_DIR/queue.log"
PAUSE_FLAG="/tmp/kiyo-matrix-pause"
REBOOT_DELAY=15  # seconds before auto-reboot, so SSH user can Ctrl-C

log() { echo "[$(date -Iseconds)] $*" | tee -a "$LOG"; }

if [ -f "$PAUSE_FLAG" ]; then
    log "Pause flag present ($PAUSE_FLAG) — exiting"
    exit 0
fi

if [ ! -s "$QUEUE" ]; then
    log "Queue empty — nothing to do"
    exit 0
fi

# Pop first line
LINE=$(head -n1 "$QUEUE")
CELL=$(echo "$LINE" | cut -f1)
WORKLOAD=$(echo "$LINE" | cut -f2)
REP=$(echo "$LINE" | cut -f3)

log "Processing: cell=$CELL workload=$WORKLOAD rep=$REP"

# Wait a moment for system to settle post-boot
sleep 10

# Run it
bash "$SCRIPT_DIR/runner.sh" "$CELL" "$WORKLOAD" "$REP"
RC=$?

log "Runner exit: $RC"

# Always move line out of queue (success, fail, skip — all proceed)
tail -n +2 "$QUEUE" > "${QUEUE}.tmp" && mv "${QUEUE}.tmp" "$QUEUE"
echo -e "${LINE}\t$(date -Iseconds)\texit${RC}" >> "$DONE"

# Decide next step
if [ "$RC" -eq 100 ]; then
    log "Runner requested reboot (HC died) — rebooting in ${REBOOT_DELAY}s"
    log "  touch $PAUSE_FLAG to halt the queue"
    sync
    sleep "$REBOOT_DELAY"
    [ -f "$PAUSE_FLAG" ] && { log "Paused"; exit 0; }
    sudo systemctl reboot
    exit 0
fi

# Soft completion — continue with next rep immediately (same boot)
if [ -s "$QUEUE" ]; then
    log "Continuing to next rep (same boot)"
    exec bash "$SCRIPT_DIR/queue.sh"
else
    log "Queue drained — matrix complete"
    log "Run: bash $SCRIPT_DIR/summary.sh  to see results"
fi
