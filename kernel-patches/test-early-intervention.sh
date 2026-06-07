#!/bin/bash
# Offline test for usb-watchdog.sh Level 0 (early intervention) classification.
#
# The watchdog's main loop can't be unit-tested without real USB crashes, but its
# line-classification is pure bash string matching. This test mirrors the case
# patterns and feeds REAL kernel-log lines (from the 2026-06-06 crash) to prove:
#   1. "Failed to set UVC commit control : -32" now triggers early intervention
#      (the old "*uvcvideo*error -32*" branch never matched this string).
#   2. "timeout: still 12 active urbs on EP #82" triggers early intervention.
#   3. Hard "HC died" / "not responding" still classify as FATAL (full recovery).
#   4. Benign enumeration lines do nothing.
#   5. The legacy "uvcvideo ... error -71/-32" format still hits its own branch.
#
# A drift guard at the end asserts the patterns/handler actually exist in
# usb-watchdog.sh, so this test fails loudly if the real script is edited out of
# sync with this mirror.
set -uo pipefail

WATCHDOG="$(dirname "$0")/../usb-watchdog.sh"

# classify() mirrors the ORDER and PATTERNS of the watchdog's case statement.
# Keep in sync with usb-watchdog.sh. Returns a label on stdout.
classify() {
    local line="$1"
    case "$line" in
        *"HC died"*|*"Host System Error"*|*"host system error"*)
            echo "fatal" ;;
        *"xHCI host not responding"*|*"xhci_hcd"*"not responding to stop"*)
            echo "fatal" ;;
        *"timeout"*"active urbs on EP"*)
            echo "early:urbs" ;;
        *"Failed to set UVC commit control"*)
            echo "early:commit" ;;
        *"Cannot set alt interface"*"ret = -19"*|*"usb_set_interface failed"*"-19"*)
            echo "softwarn:-19" ;;
        *"device descriptor read"*"error -110"*|*"device not accepting address"*"error -110"*)
            echo "softwarn:-110" ;;
        *"uvcvideo"*"error -71"*|*"uvcvideo"*"error -32"*)
            echo "softwarn:uvc" ;;
        *"USB disconnect"*"0000:00:14.0"*)
            echo "softwarn:massdisc" ;;
        *)
            echo "none" ;;
    esac
}

PASS=0; FAIL=0
check() {
    local desc="$1" line="$2" want="$3" got
    got="$(classify "$line")"
    if [ "$got" = "$want" ]; then
        printf 'PASS  %-42s -> %s\n' "$desc" "$got"; PASS=$((PASS+1))
    else
        printf 'FAIL  %-42s -> got "%s" want "%s"\n   line: %s\n' "$desc" "$got" "$want" "$line"; FAIL=$((FAIL+1))
    fi
}

echo "=== Level 0 classification (real 2026-06-06 crash lines) ==="
# The actual lines from crash-evidence/2026-06-06-v8.1-resume-crash/
check "EP#82 stuck-URB timeout (earliest)" \
    "usb 2-3: timeout: still 12 active urbs on EP #82" "early:urbs"
check "UVC commit stall -32 (the missed one)" \
    "uvcvideo 2-3:1.1: Failed to set UVC commit control : -32 (exp. 26)." "early:commit"
check "UVC commit stall -110 (standalone)" \
    "uvcvideo 2-3:1.1: Failed to set UVC commit control : -110 (exp. 26)." "early:commit"
check "HC died -> full recovery" \
    "xhci_hcd 0000:00:14.0: HC died; cleaning up" "fatal"
check "stop-endpoint not responding -> full recovery" \
    "xhci_hcd 0000:00:14.0: xHCI host not responding to stop endpoint command" "fatal"

echo ""
echo "=== Regression guards ==="
check "benign SuperSpeed enumeration is ignored" \
    "usb 2-4: new SuperSpeed USB device number 5 using xhci_hcd" "none"
check "legacy uvcvideo 'error -71' format still works" \
    "uvcvideo 1-6:1.1: usb_submit_urb error -71" "softwarn:uvc"
check "mass disconnect on our controller" \
    "usb 1-1: USB disconnect 0000:00:14.0" "softwarn:massdisc"
# The whole point of the fix: the commit-control line must NOT be silently
# swallowed by the old uvc branch (it would have been "none" before the fix,
# since it contains neither "error -32" nor "error -71").
check "commit-control line is NOT classified as legacy uvc" \
    "uvcvideo 2-3:1.1: Failed to set UVC commit control : -32 (exp. 26)." "early:commit"

echo ""
echo "=== Drift guard: patterns/handler present in usb-watchdog.sh ==="
drift=0
for needle in 'active urbs on EP' 'Failed to set UVC commit control' 'early_intervene()' 'EARLY_ENABLED'; do
    if grep -qF "$needle" "$WATCHDOG"; then
        printf 'PASS  source contains: %s\n' "$needle"; PASS=$((PASS+1))
    else
        printf 'FAIL  source MISSING:  %s  (test mirror is out of sync!)\n' "$needle"; FAIL=$((FAIL+1)); drift=1
    fi
done

echo ""
echo "=== Result: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
