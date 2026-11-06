#!/bin/bash
# Offline tests for kiyo-protocol: fixture sysfs + shims for journalctl, v4l2-ctl,
# systemctl, uname, hostname, and fake stress/selfcheck scripts. PROTOCOL_FAST=1
# makes minutes seconds, so the whole suite runs in a few seconds.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
mkdir -p "$ROOT/tmp"
T="$(mktemp -d "$ROOT/tmp/protocol-test.XXXXXX")"; trap 'rm -rf "$T"' EXIT
fail=0
ok()  { echo "  [ok]   $1"; }
bad() { echo "  [FAIL] $1"; fail=$((fail+1)); }

SHIM="$T/shim"; mkdir -p "$SHIM"
cat > "$SHIM/journalctl" <<'S'
#!/bin/bash
# -k → canned kernel lines from $FX_JOURNAL; anything else → empty
case " $* " in *" -k "*) [ -f "$FX_JOURNAL" ] && cat "$FX_JOURNAL" ;; esac
exit 0
S
cat > "$SHIM/v4l2-ctl" <<'S'
#!/bin/bash
[ "${FX_GRAB_FAIL:-0}" = 1 ] && exit 1
exit 0
S
cat > "$SHIM/systemctl" <<'S'
#!/bin/bash
echo active
S
cat > "$SHIM/uname" <<'S'
#!/bin/bash
[ "${1:-}" = "-r" ] && { echo 7.0.0-38-generic; exit 0; }; exec /usr/bin/uname "$@"
S
cat > "$SHIM/hostname" <<'S'
#!/bin/bash
echo fixturehost
S
chmod +x "$SHIM"/*
FAKE="$T/fake"; mkdir -p "$FAKE"
cat > "$FAKE/stream-loop.sh" <<'S'
#!/bin/bash
echo "fake stream-loop DEVICE=$DEVICE DURATION_SEC=$DURATION_SEC LOG_DIR=$LOG_DIR"; echo ran >> "$LOG_DIR/stream-loop.ran"
S
cat > "$FAKE/probe-cycle.sh" <<'S'
#!/bin/bash
echo "fake probe-cycle DEV=$DEV CYCLES=$CYCLES INTERVAL_MS=$INTERVAL_MS"; sleep 1
S
cat > "$FAKE/selfcheck-pass" <<'S'
#!/bin/bash
echo "PASS  dkms-running-kernel x"; echo; echo "RESULT: PASS (1 passed, 0 warnings)"
S
cat > "$FAKE/selfcheck-fail" <<'S'
#!/bin/bash
echo "FAIL  unit[call-watch]        inactive, enabled — systemctl --user enable --now call-watch"; echo; echo "RESULT: FAIL (1 failed, 0 warnings, 0 passed)"; exit 1
S
chmod +x "$FAKE"/*

build_fixture() {   # katana-shaped, Kiyo at 2-1.4, all good
    local fx="$1" sys="$1/sys" dev
    mkdir -p "$sys/module/uvcvideo" "$sys/module/usbcore/parameters" "$sys/bus/usb/devices" "$fx/proc" "$fx/results"
    echo E2EBD0A2BE4DB9E11A6893D > "$sys/module/uvcvideo/srcversion"; echo > "$sys/module/usbcore/parameters/quirks"
    echo "BOOT_IMAGE=/boot/vmlinuz-7.0.0-38-generic ro" > "$fx/proc/cmdline"
    dev="$sys/bus/usb/devices/2-1.4"; mkdir -p "$dev/power" "$dev/2-1.4:1.0/video4linux/video0" "$dev/2-1.4:1.1/video4linux/video1"
    echo 1532 > "$dev/idVendor"; echo 0e05 > "$dev/idProduct"; echo 5000 > "$dev/speed"; echo 0x410 > "$dev/quirks"
    : > "$fx/journal.log"
}
run_p() {   # run_p <fixture> <selfcheck> [args...]
    local fx="$1" sc="$2"; shift 2
    OUT=$(PATH="$SHIM:$PATH" FX_JOURNAL="$fx/journal.log" FX_GRAB_FAIL="${FX_GRAB_FAIL:-0}" KIYO_SYSFS="$fx/sys" SELFCHECK_PROC="$fx/proc" \
          KIYO_PROJECT_DIR="$fx" PROTOCOL_RESULTS_DIR="$fx/results" PROTOCOL_STREAMLOOP="$FAKE/stream-loop.sh" PROTOCOL_PROBECYCLE="$FAKE/probe-cycle.sh" \
          PROTOCOL_SELFCHECK="$FAKE/$sc" PROTOCOL_FAST=1 "$ROOT/kiyo-protocol" "$@" 2>&1); RC=$?
    REPORT=$(ls "$fx"/results/*.md 2>/dev/null | head -1)
}
expect_rc()   { [ "$RC" -eq "$1" ] && ok "$2 → exit $RC" || { bad "$2 → exit $RC (want $1)"; echo "$OUT" | sed 's/^/        /'; }; }
expect_rep()  { [ -n "$REPORT" ] && grep -qE "$1" "$REPORT" && ok "report: $1" || { bad "report missing: $1"; [ -n "$REPORT" ] && sed 's/^/        /' "$REPORT"; }; }

echo "T1 clean run, call and suspend skipped"
fx="$T/t1"; build_fixture "$fx"; run_p "$fx" selfcheck-pass --go --stress-min 2 --skip-call --skip-suspend
expect_rc 0 "clean"; expect_rep '^\| enumeration \| PASS \| speed=5000 quirks=0x410 lpm=absent nodes=video0,video1'; expect_rep '^\| stack \| PASS \|'; expect_rep '^\| stress \| PASS \| 2 min, 0 kernel markers, 0 watchdog events, 30-frame grab ok'; expect_rep '^\| call \| SKIPPED \|'; expect_rep '^\| suspend \| SKIPPED \|'; expect_rep 'RESULT: PASS'
ls "$fx"/results/*/stream-loop.ran >/dev/null 2>&1 && ok "stream-loop was invoked with the run dir" || bad "stream-loop not invoked"
grep -q 'fake probe-cycle DEV=/dev/video0 CYCLES=1000000 INTERVAL_MS=250' "$fx"/results/*/probe-commit.out && ok "probe-cycle got the streaming node and pacing" || bad "probe-cycle args wrong"
grep -q 'uvcvideo srcversion: E2EBD0A2BE4DB9E11A6893D' "$REPORT" && ok "provenance stamped" || bad "provenance missing"

echo "T2 kernel marker during stress → stress FAIL"
fx="$T/t2"; build_fixture "$fx"; echo "Nov 06 13:00:00 katana kernel: xhci_hcd 0000:00:14.0: HC died; cleaning up" > "$fx/journal.log"; run_p "$fx" selfcheck-pass --go --stress-min 2 --skip-call --skip-suspend
expect_rc 1 "HC died"; expect_rep '^\| stress \| FAIL \| kernel markers=1'; expect_rep 'RESULT: FAIL'
grep -q 'HC died' "$fx"/results/*/kernel-markers.log && ok "marker line preserved in the run dir" || bad "kernel-markers.log missing the line"

echo "T2b precursor marker counts too"
fx="$T/t2b"; build_fixture "$fx"; echo "kernel: uvcvideo 2-1.4:1.1: Failed to set UVC commit control : -110 (exp. 26)." > "$fx/journal.log"; run_p "$fx" selfcheck-pass --go --stress-min 2 --skip-call --skip-suspend
expect_rc 1 "commit stall"; expect_rep '^\| stress \| FAIL \| kernel markers=1'

echo "T3 refuses without --go"
fx="$T/t3"; build_fixture "$fx"; run_p "$fx" selfcheck-pass --stress-min 2 --skip-call --skip-suspend
expect_rc 2 "no --go"; [ -z "$REPORT" ] && ok "no report written" || bad "report written despite refusal"

echo "T4 no Kiyo → nothing to test"
fx="$T/t4"; build_fixture "$fx"; rm -r "$fx/sys/bus/usb/devices/2-1.4"; run_p "$fx" selfcheck-pass --go --skip-call --skip-suspend
expect_rc 2 "no camera"

echo "T5 self-check FAIL → stack FAIL, the rest still runs"
fx="$T/t5"; build_fixture "$fx"; run_p "$fx" selfcheck-fail --go --stress-min 2 --skip-call --skip-suspend
expect_rc 1 "selfcheck fail"; expect_rep '^\| stack \| FAIL \| unit\[call-watch\]'; expect_rep '^\| stress \| PASS \|'

echo "T6 final frame grab fails → stress FAIL"
fx="$T/t6"; build_fixture "$fx"; FX_GRAB_FAIL=1 run_p "$fx" selfcheck-pass --go --stress-min 2 --skip-call --skip-suspend
expect_rc 1 "grab fail"; expect_rep '^\| stress \| FAIL \| .*grab=FAILED'

echo "T7 camera at USB2 → enumeration FAIL"
fx="$T/t7"; build_fixture "$fx"; echo 480 > "$fx/sys/bus/usb/devices/2-1.4/speed"; run_p "$fx" selfcheck-pass --go --stress-min 2 --skip-call --skip-suspend
expect_rc 1 "usb2"; expect_rep '^\| enumeration \| FAIL \| speed=480'

echo; echo "fail=$fail"
[ "$fail" -eq 0 ]
