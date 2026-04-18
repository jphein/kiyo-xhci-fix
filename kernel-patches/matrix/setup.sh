#!/bin/bash
# Generate queue.txt from a per-cell rep count. Call after bootstrap.sh.
# Default: 5 reps per (cell, workload) = 50 runs total.
#
# Usage: setup.sh [reps_per_cell]

set -eu

REPS="${1:-5}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="$SCRIPT_DIR/results"
QUEUE="$RESULTS_DIR/queue.txt"

mkdir -p "$RESULTS_DIR"

# Order: all reps for cell 1 first, then 2, etc. Within a cell, spam-only
# before spam-stream (cheaper to recover if something breaks early).
#
# This order also matches typical boot-config grouping:
#   cells 1, 3, 4 = stock kernel       (change NO_LPM/module between)
#   cells 2, 5    = Michal kernel      (change NO_LPM/module between)
#
# You may want to hand-edit queue.txt to group by boot config to minimise
# reboots, e.g. run cell 1 (5 reps), then cell 3 (needs NO_LPM reboot),
# then cell 4 (swap DKMS in place, no reboot), then boot Michal kernel,
# then cell 2 (5 reps), then cell 5.
: > "$QUEUE"
for cell in 1 2 3 4 5; do
    for workload in spam-only spam-stream; do
        for rep in $(seq 1 "$REPS"); do
            printf '%s\t%s\t%s\n' "$cell" "$workload" "$rep" >> "$QUEUE"
        done
    done
done

echo "Wrote $(wc -l < "$QUEUE") reps to $QUEUE"
echo
echo "Next steps:"
echo "  1. Reorder $QUEUE to group by boot config if you want fewer reboots."
echo "  2. Boot into the kernel/cmdline matching the first cell in queue."
echo "  3. If using the systemd unit: sudo systemctl enable --now matrix-queue.service"
echo "     Else, run by hand: bash $SCRIPT_DIR/queue.sh"
echo "  4. When queue drains, run: bash $SCRIPT_DIR/summary.sh"
