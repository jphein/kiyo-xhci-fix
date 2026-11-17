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
# journalctl: once the number of starts reaches FX_FRAMES_AT (default 1), six per-second lines at FX_FPS (default 59)
printf '#!/bin/bash\nn=$(wc -l < "$FX/starts" 2>/dev/null || echo 0)\n[ "$n" -ge "${FX_FRAMES_AT:-1}" ] && for v in ${FX_FPS_SEQ:-$(for i in $(seq 1 ${FX_LINES:-6}); do echo ${FX_FPS:-59}; done)}; do echo "fps=$v drop=0 ms: capture=5"; done\nexit 0\n' > "$SHIM/journalctl"
printf '#!/bin/bash\n[ -f "$FX/holder" ] && printf " %%s" $(cat "$FX/holder")\nexit 0\n' > "$SHIM/fuser"
printf '#!/bin/bash\nif [ "${4:-}" = "${FX_CALL_PID:-none}" ]; then echo "chrome --type=renderer"; elif [ "${4:-}" = "${FX_OBS_PID:-none}" ]; then echo "/usr/bin/obs --collection Kiyo-Call --startvirtualcam"; else echo "python -m nvpoca --input /dev/video0"; fi\n' > "$SHIM/ps"
# busctl: Enabled reads FX_EN_BEFORE until the first start, then FX_EN_AFTER (a restart resets it); set-property logged
printf '#!/bin/bash\nif [ "$2" = get-property ]; then n=$(wc -l < "$FX/starts" 2>/dev/null || echo 0); v=$([ "$n" -ge 1 ] && echo "${FX_EN_AFTER:-}" || echo "${FX_EN_BEFORE:-}"); [ -n "$v" ] && echo "b $v"; elif [ "$2" = set-property ]; then echo "busctl set Enabled $8" >> "$FX/log"; fi\nexit 0\n' > "$SHIM/busctl"
# ffmpeg must not be needed any more (the proof is nvpoca's rate): a call to it fails the run loudly
printf '#!/bin/bash\necho "ffmpeg called" >> "$FX/log"\nexit 1\n' > "$SHIM/ffmpeg"
printf '#!/bin/bash\nexit 0\n' > "$SHIM/sleep"
printf '#!/bin/bash\necho "kiyo-hdr $*" >> "$FX/log"\n[ -n "${KIYO_HDR_FAIL:-}" ] && { echo "OSError: [Errno 5] Input/output error" >&2; exit 1; }\nexit 0\n' > "$T/kiyo-hdr"
printf '#!/bin/bash\necho "reset" >> "$FX/log"\nexit 0\n' > "$T/reset"
chmod +x "$SHIM"/* "$T/kiyo-hdr" "$T/reset"

run() {   # run <fixture> <args...> -> OUT RC LOG
    local fx="$1"; shift; mkdir -p "$fx"; : > "$fx/log"
    OUT=$(PATH="$SHIM:$PATH" FX="$fx" KIYO_HDR="$T/kiyo-hdr" KIYO_RESET="$T/reset" WAIT_S=3 \
          "$ROOT/katana-av/camera-mode" "$@" 2>&1); RC=$?
    LOG="$(cat "$fx/log")"
}

echo "M1 fast: stop -> kiyo-hdr off -> start, nvpoca at 59 fps -> proven, exit 0"
FX_FPS=59 run "$T/m1" fast
[ "$RC" = 0 ] && ok "exit 0" || bad "exit $RC: $OUT"
want=$'systemctl --user stop nvpoca.service\nkiyo-hdr off --yes\nsystemctl --user start nvpoca.service'
[ "$LOG" = "$want" ] && ok "order stop, kiyo-hdr off, start" || bad "order: $LOG"
echo "$OUT" | grep -q "^camera-mode fast: 59 fps (nvpoca capture rate, median of 6 s) · HDR off · proven" && ok "one proof line" || bad "$OUT"

echo "M2 hdr: kiyo-hdr on, nvpoca at 30 -> proven"
FX_FPS=30 run "$T/m2" hdr
[ "$RC" = 0 ] && echo "$LOG" | grep -q "kiyo-hdr on --yes" && ok "exit 0, HDR on sent" || bad "exit $RC: $LOG"

echo "M3 fast but the camera still gives 30 -> exit 1, says so"
FX_FPS=30 run "$T/m3" fast
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
FX_FPS=59 FX_FRAMES_AT=0 run "$T/m9" status
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

echo "M13 OBS reading video11 is NOT a call: switches without --force (2026-11-17 14:55 refusal)"
mkdir -p "$T/m13"; echo 5150 > "$T/m13/holder"
FX_OBS_PID=5150 run "$T/m13" fast
[ "$RC" = 0 ] && echo "$LOG" | grep -q "kiyo-hdr off --yes" && ok "switched with OBS holding video11" || bad "exit $RC: $OUT"

echo "M14 background removal OFF before, the restart turns it ON -> set back OFF and said so"
FX_EN_BEFORE=false FX_EN_AFTER=true run "$T/m14" fast
[ "$RC" = 0 ] && echo "$LOG" | grep -q "^busctl set Enabled false$" && echo "$OUT" | grep -q "background removal kept off" \
    && ok "removal restored off" || bad "exit $RC: $LOG / $OUT"

echo "M15 removal ON before and after -> nothing set; daemon not answering -> nothing set"
FX_EN_BEFORE=true FX_EN_AFTER=true run "$T/m15" fast
! echo "$LOG" | grep -q busctl && ok "no set when unchanged" || bad "$LOG"
FX_EN_AFTER=true run "$T/m15b" fast
! echo "$LOG" | grep -q busctl && ok "no set when the 'before' read failed" || bad "$LOG"

echo "M16 the proof never reads a video node (ffmpeg not called), status included"
for m in m1 m2 m9 m13 m14; do grep -q "ffmpeg called" "$T/$m/log" && bad "$m called ffmpeg"; done; ok "no ffmpeg reads"

echo "M17 too few fresh samples never prove a mode: 0, 1 and 3 lines (a camera that stopped mid-window) -> exit 1"
for k in 1 3; do   # 0 lines in fast/hdr = no frames at all: the wedge path (M8), exit 3
    FX_LINES=$k run "$T/m17-$k" fast
    [ "$RC" = 1 ] && echo "$OUT" | grep -q "median of $k s" && ok "$k samples -> not proven" || bad "$k samples: exit $RC: $OUT"
done
for k in 0 1; do
    FX_LINES=$k FX_FRAMES_AT=0 run "$T/m17s-$k" status
    [ "$RC" = 1 ] && echo "$OUT" | grep -q "only $k of 6 samples" && ok "status with $k samples -> no steady frames" || bad "$OUT"
done

echo "M18 true median on an even count: 49 49 49 51 51 51 -> 50 (fast threshold 50 -> proven)"
FX_FPS_SEQ="49 49 49 51 51 51" run "$T/m18" fast
[ "$RC" = 0 ] && echo "$OUT" | grep -q "fast: 50 fps" && ok "median 50" || bad "exit $RC: $OUT"

echo "M19 removal restored on FAILURE exits after the restart too (kiyo-hdr fails; no frames after the reset)"
FX_EN_BEFORE=false FX_EN_AFTER=true KIYO_HDR_FAIL=1 run "$T/m19a" fast
[ "$RC" = 3 ] && echo "$LOG" | grep -q "^busctl set Enabled false$" && ok "restored after kiyo-hdr failure" || bad "exit $RC: $LOG"
FX_EN_BEFORE=false FX_EN_AFTER=true FX_FRAMES_AT=99 run "$T/m19b" hdr
[ "$RC" = 3 ] && echo "$LOG" | grep -q "^busctl set Enabled false$" && ok "restored after no-frames exit" || bad "exit $RC: $LOG"
[ "$(grep -c 'busctl set' "$T/m14/log")" = 1 ] && ok "success path sets it once (trap is idempotent)" || bad "m14 sets: $(grep -c 'busctl set' "$T/m14/log")"

[ "$fail" = 0 ] && echo "ok: camera-mode tests pass" || echo "FAILED: $fail"
exit "$fail"
