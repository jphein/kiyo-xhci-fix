#!/bin/bash
# Offline tests for katana-av/cam-measure: a v4l2-ctl shim writes "<" frame markers to STDERR
# (as the real one does) at a set rate, a fixture sysfs holds the Kiyo, and journalctl/fuser
# are shims. Pins: steady rate counted, a stall told apart from a slow start, kernel markers
# fail the run, a held camera is never opened, no camera is a usage-class exit.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
mkdir -p "$ROOT/tmp"
T="$(mktemp -d "$ROOT/tmp/cam-measure-test.XXXXXX")"; trap 'rm -rf "$T"' EXIT
fail=0
ok()  { echo "  [ok]   $1"; }
bad() { echo "  [FAIL] $1"; fail=$((fail+1)); }

SHIM="$T/shim"; mkdir -p "$SHIM" "$T/run"
cat > "$SHIM/v4l2-ctl" <<'S'
#!/usr/bin/env python3
# frames to STDERR, one "<" each, FX_RATE per second; stop after FX_STOP frames and hang (a stall)
import os, sys, time
want = int(next(a.split("=", 1)[1] for a in sys.argv if a.startswith("--stream-count=")))
rate, stop = float(os.environ.get("FX_RATE", "60")), int(os.environ.get("FX_STOP", "0") or 0)
time.sleep(float(os.environ.get("FX_START", "0.2")))
for i in range(want):
    if stop and i == stop:
        time.sleep(3600)
    sys.stderr.write("<"); sys.stderr.flush()
    time.sleep(1 / rate)
S
printf '#!/bin/bash\n[ -f "$FX/journal" ] && cat "$FX/journal"\nexit 0\n' > "$SHIM/journalctl"
printf '#!/bin/bash\n[ -f "$FX/holder" ] && printf " %%s" "$(cat "$FX/holder")"\nexit 0\n' > "$SHIM/fuser"
chmod +x "$SHIM"/*

build() {   # build <dir>: a Kiyo at 2-1 with video0
    local fx="$1" d="$1/sys/bus/usb/devices/2-1"
    mkdir -p "$d/2-1:1.0/video4linux/video0" "$1/sys/module/uvcvideo"
    echo 1532 > "$d/idVendor"; echo 0e05 > "$d/idProduct"; echo 5000 > "$d/speed"; echo 0x410 > "$d/quirks"
    echo E2EBD0A2BE4DB9E11A6893D > "$1/sys/module/uvcvideo/srcversion"
}
run_cm() {   # run_cm <fixture> [args] -> OUT RC
    local fx="$1"; shift
    OUT=$(PATH="$SHIM:$PATH" FX="$fx" CAM_SYSFS="$fx/sys" XDG_RUNTIME_DIR="$T/run" "$ROOT/katana-av/cam-measure" "$@" 2>&1); RC=$?
}

echo "C1 steady 30 fps for 2 s at a 30 fps request → PASS, rate and timeline reported"
fx="$T/c1"; build "$fx"; FX_RATE=30 run_cm "$fx" 2 64x48@30 MJPG
[ "$RC" = 0 ] && ok "exit 0" || { bad "exit $RC"; echo "$OUT" | sed 's/^/        /'; }
echo "$OUT" | grep -qE "^frames      60 / 60" && ok "60/60 frames" || bad "$(echo "$OUT" | grep '^frames')"
echo "$OUT" | grep -qE "steady (2[89]|30|31)\.[0-9]+ fps" && ok "steady ~30 fps" || bad "$(echo "$OUT" | grep '^timeline')"

echo "C2 stall after 20 frames (no kernel marker) → FAIL with the gap visible"
fx="$T/c2"; build "$fx"; FX_RATE=30 FX_STOP=20 run_cm "$fx" 2 64x48@30 MJPG
[ "$RC" = 1 ] && ok "exit 1" || bad "exit $RC"
echo "$OUT" | grep -qE "^frames      20 / 60" && ok "20/60 frames" || bad "$(echo "$OUT" | grep '^frames')"
echo "$OUT" | grep -qE "last frame 1[0-9]\.[0-9]+ s before the end" && ok "stall shows as a long tail" || bad "$(echo "$OUT" | grep '^timeline')"

echo "C3 slow start (3 s to the first frame) is reported as such"
fx="$T/c3"; build "$fx"; FX_RATE=30 FX_START=3 run_cm "$fx" 2 64x48@30 MJPG
echo "$OUT" | grep -qE "first frame after 3\.[0-9]+ s" && ok "first-frame latency ~3 s" || bad "$(echo "$OUT" | grep '^timeline')"

echo "C4 a commit-control timeout in the kernel log fails the run"
fx="$T/c4"; build "$fx"; echo "uvcvideo 2-1:1.1: Failed to set UVC commit control : -110 (exp. 26)." > "$fx/journal"; FX_RATE=30 run_cm "$fx" 1 64x48@30 MJPG
[ "$RC" = 1 ] && ok "exit 1" || bad "exit $RC"
echo "$OUT" | grep -q "markers     1:" && ok "marker listed" || bad "$(echo "$OUT" | grep '^markers')"

echo "C5 camera held by another app → never opened (exit 2); no Kiyo → exit 2; bad usage → 2"
fx="$T/c5"; build "$fx"; echo 4242 > "$fx/holder"; run_cm "$fx" 1 64x48@30
[ "$RC" = 2 ] && echo "$OUT" | grep -q "held by pid" && ok "held camera refused" || bad "exit $RC: $OUT"
fx="$T/c5b"; mkdir -p "$fx/sys/bus/usb/devices"; run_cm "$fx" 1
[ "$RC" = 2 ] && ok "no Kiyo → 2" || bad "exit $RC"
run_cm "$T/c1" abc; [ "$RC" = 2 ] && ok "usage → 2" || bad "usage exit $RC"

echo; echo "fail=$fail"
[ "$fail" -eq 0 ]
