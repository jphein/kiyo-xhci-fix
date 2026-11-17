#!/bin/bash
# Offline tests for katana-av/camera-mode: systemctl, journalctl, fuser, ps, ffmpeg, kiyo-hdr and the reset are
# shims. Pins: the order stop -> kiyo-hdr -> start (HDR sent mid-stream does nothing, 2026-11-17), the proof by
# distinct fps, a call refuses, a wedge soft-resets and RE-APPLIES the mode, no frames after a reset = exit 3.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
mkdir -p "$ROOT/tmp"
T="$(mktemp -d "$ROOT/tmp/camera-mode-test.XXXXXX")"; trap 'rm -rf "$T"' EXIT
fail=0
ok()  { echo "  [ok]   $1"; }
bad() { echo "  [FAIL] $1"; fail=$((fail+1)); }

SHIM="$T/shim"; mkdir -p "$SHIM"
# systemctl: log, count starts
printf '#!/bin/bash\necho "systemctl $*" >> "$FX/log"\n[ "$2" = start ] && echo x >> "$FX/starts"\nexit 0\n' > "$SHIM/systemctl"
# journalctl: frames flow once the number of starts reaches FX_FRAMES_AT (default 1)
printf '#!/bin/bash\nn=$(wc -l < "$FX/starts" 2>/dev/null || echo 0)\n[ "$n" -ge "${FX_FRAMES_AT:-1}" ] && echo "fps=59 drop=0"\nexit 0\n' > "$SHIM/journalctl"
printf '#!/bin/bash\n[ -f "$FX/holder" ] && printf " %%s" $(cat "$FX/holder")\nexit 0\n' > "$SHIM/fuser"
printf '#!/bin/bash\n[ "${4:-}" = "${FX_CALL_PID:-none}" ] && echo "chrome --type=renderer" || echo "python -m nvpoca --input /dev/video0"\n' > "$SHIM/ps"
# ffmpeg: FX_DISTINCT distinct frame hashes (plus duplicates) in framemd5 shape
printf '#!/bin/bash\necho "#format: frame checksums"\nfor i in $(seq 1 "${FX_DISTINCT:-358}"); do echo "0, $i, $i, 1, 4147200, hash$i"; echo "0, $i, $i, 1, 4147200, hash$i"; done\n' > "$SHIM/ffmpeg"
printf '#!/bin/bash\nexit 0\n' > "$SHIM/sleep"
printf '#!/bin/bash\necho "kiyo-hdr $*" >> "$FX/log"\nexit 0\n' > "$T/kiyo-hdr"
printf '#!/bin/bash\necho "reset" >> "$FX/log"\nexit 0\n' > "$T/reset"
chmod +x "$SHIM"/* "$T/kiyo-hdr" "$T/reset"

run() {   # run <fixture> <args...> -> OUT RC LOG
    local fx="$1"; shift; mkdir -p "$fx"; : > "$fx/log"
    OUT=$(PATH="$SHIM:$PATH" FX="$fx" KIYO_HDR="$T/kiyo-hdr" KIYO_RESET="$T/reset" WAIT_S=3 \
          "$ROOT/katana-av/camera-mode" "$@" 2>&1); RC=$?
    LOG="$(cat "$fx/log")"
}

echo "M1 fast: stop -> kiyo-hdr off -> start, 358 distinct / 6 s -> proven, exit 0"
FX_DISTINCT=358 run "$T/m1" fast
[ "$RC" = 0 ] && ok "exit 0" || bad "exit $RC: $OUT"
want=$'systemctl --user stop nvpoca.service\nkiyo-hdr off --yes\nsystemctl --user start nvpoca.service'
[ "$LOG" = "$want" ] && ok "order stop, kiyo-hdr off, start" || bad "order: $LOG"
echo "$OUT" | grep -q "^camera-mode fast: 59 fps (358 distinct frames / 6 s" && ok "one proof line" || bad "$OUT"

echo "M2 hdr: kiyo-hdr on, 175 distinct -> 29 fps proven"
FX_DISTINCT=175 run "$T/m2" hdr
[ "$RC" = 0 ] && echo "$LOG" | grep -q "kiyo-hdr on --yes" && ok "exit 0, HDR on sent" || bad "exit $RC: $LOG"

echo "M3 fast but the camera still gives 30 -> exit 1, says so"
FX_DISTINCT=180 run "$T/m3" fast
[ "$RC" = 1 ] && echo "$OUT" | grep -q "NOT what the mode should give" && ok "exit 1, not proven" || bad "exit $RC: $OUT"

echo "M4 a call holds the camera -> refused, nothing touched"
mkdir -p "$T/m4"; echo 4242 > "$T/m4/holder"
FX_CALL_PID=4242 run "$T/m4" fast
[ "$RC" = 2 ] && [ -z "$LOG" ] && ok "exit 2, no systemctl / kiyo-hdr" || bad "exit $RC: $LOG"

echo "M5 nvpoca itself holding the camera is not a call"
mkdir -p "$T/m5"; echo 77 > "$T/m5/holder"
run "$T/m5" fast
[ "$RC" = 0 ] && ok "exit 0" || bad "exit $RC: $OUT"

echo "M6 --force switches during a call"
mkdir -p "$T/m6"; echo 4242 > "$T/m6/holder"
FX_CALL_PID=4242 run "$T/m6" fast --force
[ "$RC" = 0 ] && ok "exit 0 with --force" || bad "exit $RC: $OUT"

echo "M7 wedge: no frames after the first start -> soft reset, HDR off RE-SENT (the reset restores HDR on), recovered"
FX_FRAMES_AT=2 run "$T/m7" fast
[ "$RC" = 0 ] && ok "exit 0" || bad "exit $RC: $OUT"
[ "$(echo "$LOG" | grep -c 'kiyo-hdr off --yes')" = 2 ] && echo "$LOG" | grep -q '^reset$' && ok "reset, then off sent again" || bad "$LOG"
echo "$OUT" | grep -q "recovered from a wedge" && ok "says it recovered" || bad "$OUT"

echo "M8 no frames even after the reset -> exit 3, replug"
FX_FRAMES_AT=99 run "$T/m8" hdr
[ "$RC" = 3 ] && echo "$OUT" | grep -q "re-plug" && ok "exit 3, replug" || bad "exit $RC: $OUT"

echo "M9 status changes nothing"
FX_DISTINCT=356 run "$T/m9" status
[ "$RC" = 0 ] && [ -z "$LOG" ] && echo "$OUT" | grep -q "= fast (HDR off)" && ok "status reads fast, no writes" || bad "exit $RC: $LOG / $OUT"

echo "M10 bad usage -> exit 2"
run "$T/m10" turbo
[ "$RC" = 2 ] && ok "exit 2" || bad "exit $RC"

echo "M11 run through the ~/.local/bin SYMLINK with no KIYO_HDR/KIYO_RESET: finds kiyo-hdr and ../reset-camera.sh next to"
echo "    the REAL file (2026-11-17: unresolved, it looked in ~/.local/bin and failed 'kiyo-hdr off failed')"
R="$T/repo"; mkdir -p "$R/katana-av" "$T/bin" "$T/m11"; : > "$T/m11/log"
cp "$ROOT/katana-av/camera-mode" "$R/katana-av/camera-mode"
cp "$T/kiyo-hdr" "$R/katana-av/kiyo-hdr"; cp "$T/reset" "$R/reset-camera.sh"
ln -sfn "$R/katana-av/camera-mode" "$T/bin/camera-mode"
OUT=$(PATH="$SHIM:$PATH" FX="$T/m11" FX_FRAMES_AT=2 WAIT_S=3 "$T/bin/camera-mode" fast 2>&1); RC=$?
LOG="$(cat "$T/m11/log")"
[ "$RC" = 0 ] && ok "exit 0 via the symlink" || bad "exit $RC: $OUT"
[ "$(echo "$LOG" | grep -c 'kiyo-hdr off --yes')" = 2 ] && echo "$LOG" | grep -q '^reset$' \
    && ok "the real kiyo-hdr and reset-camera.sh ran" || bad "$LOG"

echo "M12 kiyo-hdr fails -> exit 3, the message carries ITS error, nvpoca started again"
# stdout prints LAST: the message must hold stderr's last line only, never stdout
printf '#!/bin/bash\necho "Traceback (most recent call last):" >&2\necho "OSError: [Errno 32] Broken pipe" >&2\necho "kiyo-hdr: camera 2-1 dev /dev/video0 unit 6"\nexit 1\n' > "$T/kiyo-hdr-bad"
chmod +x "$T/kiyo-hdr-bad"; mkdir -p "$T/m12"; : > "$T/m12/log"
OUT=$(PATH="$SHIM:$PATH" FX="$T/m12" KIYO_HDR="$T/kiyo-hdr-bad" KIYO_RESET="$T/reset" WAIT_S=3 \
      "$ROOT/katana-av/camera-mode" fast 2>&1); RC=$?
LOG="$(cat "$T/m12/log")"
[ "$RC" = 3 ] && ok "exit 3" || bad "exit $RC: $OUT"
[ "$OUT" = "camera-mode: kiyo-hdr off failed: OSError: [Errno 32] Broken pipe" ] && ok "names the cause" || bad "$OUT"
[ "$(echo "$LOG" | tail -1)" = "systemctl --user start nvpoca.service" ] && ok "nvpoca restarted" || bad "$LOG"

[ "$fail" = 0 ] && echo "ok: camera-mode tests pass" || echo "FAILED: $fail"
exit "$fail"
