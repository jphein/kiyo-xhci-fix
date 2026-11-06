#!/bin/bash
# install-stack.sh --dry-run must name every piece and touch nothing.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0
out=$("$ROOT/install-stack.sh" --dry-run 2>&1) || { echo "  [FAIL] dry-run exited non-zero"; fail=1; }
for want in 99-razer-kiyo-pro.rules usb-watchdog-sudoers usb-watchdog.service call-watch.service scarlett-storm-guard.service install-selfcheck.sh "enable --now usb-watchdog.service"; do
    echo "$out" | grep -q -- "$want" && echo "  [ok]   mentions $want" || { echo "  [FAIL] missing $want"; fail=1; }
done
echo "$out" | grep -qE '^\+ ' && { echo "  [FAIL] dry-run executed something"; fail=1; } || echo "  [ok]   nothing executed"
echo "fail=$fail"; [ "$fail" -eq 0 ]
