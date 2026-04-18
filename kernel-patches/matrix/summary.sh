#!/bin/bash
# Render results/summary.tsv as a markdown table, suitable for pasting
# into the v8 cover letter or a mailing-list reply.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUMMARY="$SCRIPT_DIR/results/summary.tsv"

if [ ! -s "$SUMMARY" ]; then
    echo "No results yet at $SUMMARY"
    exit 1
fi

declare -A CELL_NAME=(
    [1]="stock 6.17"
    [2]="stock + Michal-xhci"
    [3]="stock + NO_LPM"
    [4]="stock + NO_LPM + CTRL_THROTTLE"
    [5]="stock + NO_LPM + CTRL_THROTTLE + Michal-xhci"
)

for workload in spam-only spam-stream; do
    echo
    echo "### Workload: \`$workload\`"
    echo
    printf "| %-45s | %-8s | %-15s | %s\n" "Config" "Pass/N" "Fail reasons" "Notes"
    printf "|%s|%s|%s|%s\n" \
        "$(printf '%.0s-' {1..47})" \
        "$(printf '%.0s-' {1..10})" \
        "$(printf '%.0s-' {1..17})" \
        "$(printf '%.0s-' {1..40})"

    for cell in 1 2 3 4 5; do
        TOTAL=$(awk -v c="$cell" -v w="$workload" -F'\t' \
            '$1==c && $2==w {n++} END{print n+0}' "$SUMMARY")
        PASS=$(awk -v c="$cell" -v w="$workload" -F'\t' \
            '$1==c && $2==w && $4=="PASS" {n++} END{print n+0}' "$SUMMARY")
        FAILS=$(awk -v c="$cell" -v w="$workload" -F'\t' \
            '$1==c && $2==w && $4=="FAIL" {print $5}' "$SUMMARY" \
            | sort | uniq -c | awk '{print $1"x "$2}' | paste -sd', ')
        [ -z "$FAILS" ] && FAILS="—"
        WARNS=$(awk -v c="$cell" -v w="$workload" -F'\t' \
            '$1==c && $2==w && $4=="WARN" {n++} END{print n+0}' "$SUMMARY")
        NOTES=""
        [ "$WARNS" -gt 0 ] && NOTES="${WARNS}x warn"
        printf "| %-45s | %3d/%-4d | %-15s | %s\n" \
            "${CELL_NAME[$cell]}" "$PASS" "$TOTAL" "$FAILS" "$NOTES"
    done
done

echo
echo "### Raw log: \`$SUMMARY\`"
echo
echo "Reps total: $(wc -l < "$SUMMARY")"
