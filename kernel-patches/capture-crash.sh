#!/bin/bash
# Run this over SSH before triggering the crash.
# Captures dmesg continuously to a timestamped log file.
LOGDIR="$(dirname "$0")/crash-evidence"
LOGFILE="$LOGDIR/crash-$(uname -r)-$(date +%Y%m%d-%H%M%S).log"

echo "Capturing dmesg to: $LOGFILE"
echo "Kernel: $(uname -r)"
echo "Press Ctrl+C to stop."
echo ""

# Dump existing dmesg first, then follow
dmesg -T > "$LOGFILE"
dmesg -T --follow >> "$LOGFILE"
