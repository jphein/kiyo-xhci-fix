#!/bin/bash
# Offline tests for katana-av/obs-macro-pad: camera-scene, camera-mode and wpctl are shims; OBS is never written
# (verbs that need it run --dry-run). Pins: the map names only known verbs; one press = the stack's own verb; the
# camera-stack lock held = backed off, nothing run; a FAKE pad (uinput) is grabbed and its keys dispatched, key
# repeat and key-up ignored, a press during a running verb dropped, an unplug survived. No real input device is
# touched: keys are injected only after the daemon reports the grab, so nothing reaches the desktop.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PAD="$ROOT/katana-av/obs-macro-pad"
PY="$(head -1 "$PAD" | sed 's/^#!//')"
mkdir -p "$ROOT/tmp"
T="$(mktemp -d "$ROOT/tmp/obs-macro-pad-test.XXXXXX")"; trap 'rm -rf "$T"; kill $(jobs -p) 2>/dev/null' EXIT
fail=0
ok()  { echo "  [ok]   $1"; }
bad() { echo "  [FAIL] $1"; fail=$((fail+1)); }

SHIM="$T/shim"; mkdir -p "$SHIM"
printf '#!/bin/bash\necho "camera-scene $*" >> "$FX/log"\necho "camera-scene: program scene '"'"'$1'"'"'"\n' > "$SHIM/camera-scene"
printf '#!/bin/bash\necho "camera-mode $*" >> "$FX/log"\nsleep "${FX_MODE_SLEEP:-0}"\necho "camera-mode $1: 59 fps"\n' > "$SHIM/camera-mode"
# wpctl: set-mute flips a flag file; get-volume reports it
printf '#!/bin/bash\necho "wpctl $*" >> "$FX/log"\nif [ "$1" = set-mute ]; then case "$3" in 1) touch "$FX/muted";; 0) rm -f "$FX/muted";; toggle) [ -f "$FX/muted" ] && rm -f "$FX/muted" || touch "$FX/muted";; esac; fi\n[ "$1" = get-volume ] && { [ -f "$FX/muted" ] && echo "Volume: 1.00 [MUTED]" || echo "Volume: 1.00"; }\nexit 0\n' > "$SHIM/wpctl"
chmod +x "$SHIM"/*
export CAMERA_STACK_LOCK="$T/camera-stack.lock" OBS_MACRO_PAD_STATE="$T/state.json"

run() {   # run <fixture> <args...> -> OUT RC LOG
    local fx="$1"; shift; mkdir -p "$fx"; : > "$fx/log"
    OUT=$(PATH="$SHIM:$PATH" FX="$fx" "$PAD" "$@" 2>&1); RC=$?
    LOG="$(cat "$fx/log")"
}

echo "M1 map: the vendored map loads, names only known verbs; a bad verb is refused before any grab"
run "$T/m1" map
[ "$RC" = 0 ] && ok "exit 0" || bad "exit $RC: $OUT"
echo "$OUT" | grep -q "KEY_KP5 *mic toggle" && ok "KP5 = mic toggle" || bad "$OUT"
echo '{"device":"x","keys":{"KEY_KP1":"scene nowhere"}}' > "$T/bad.json"
OUT=$(OBS_MACRO_PAD_MAP="$T/bad.json" "$PAD" map 2>&1); RC=$?
[ "$RC" = 2 ] && echo "$OUT" | grep -q "bad map" && ok "unknown verb arg -> exit 2" || bad "exit $RC: $OUT"

echo "M2 do: each verb is the stack's own tool, never a key replay"
run "$T/m2" do scene brand
[ "$RC" = 0 ] && [ "$LOG" = "camera-scene brand" ] && ok "scene brand -> camera-scene brand" || bad "rc=$RC log=$LOG out=$OUT"
run "$T/m2" do mic toggle
echo "$LOG" | grep -q "wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle" && echo "$OUT" | grep -q "mic muted" && ok "mic toggle -> wpctl, reports muted" || bad "log=$LOG out=$OUT"
run "$T/m2" do mic unmute
echo "$OUT" | grep -q "mic live" && ok "mic unmute -> live" || bad "$OUT"
rm -f "$T/state.json"
run "$T/m2" do camera-mode toggle
echo "$LOG" | grep -q "camera-mode status" && echo "$LOG" | grep -q "camera-mode fast" && ok "camera-mode toggle: seeds from status (hdr) -> fast" || bad "log=$LOG"
run "$T/m2" do camera-mode toggle
[ "$LOG" = "camera-mode hdr" ] && ok "second toggle: remembered fast -> hdr, no re-measure" || bad "log=$LOG"
run "$T/m2" do scene sideways
[ "$RC" = 2 ] && ok "scene sideways -> exit 2" || bad "exit $RC: $OUT"
run "$T/m2" --dry-run do record toggle
[ "$RC" = 0 ] && echo "$OUT" | grep -q "would ToggleRecord" && [ -z "$LOG" ] && ok "--dry-run writes nothing" || bad "rc=$RC out=$OUT"

echo "M3 lock: held by someone else (ha's restart window) -> backed off, nothing run, exit 4"
# the holder is one process with no child (flock(1) forks: killing it leaves its child holding the fd)
"$PY" -c 'import fcntl,sys,time; f=open(sys.argv[1],"w"); fcntl.flock(f,fcntl.LOCK_EX); time.sleep(20)' "$T/camera-stack.lock" &
HOLDER=$!; sleep 0.5
run "$T/m3" do scene plain
[ "$RC" = 4 ] && echo "$OUT" | grep -q "backed off (lock held)" && [ -z "$LOG" ] && ok "scene plain backed off" || bad "rc=$RC log=$LOG out=$OUT"
run "$T/m3" do camera-mode fast
[ "$RC" = 4 ] && [ -z "$LOG" ] && ok "camera-mode fast backed off (nvpoca touch)" || bad "rc=$RC log=$LOG"
run "$T/m3" do mic mute
[ "$RC" = 0 ] && ok "mic mute needs no lock (not an OBS write)" || bad "rc=$RC out=$OUT"
run "$T/m3" do safe
[ "$RC" = 4 ] && echo "$OUT" | grep -q "scene: backed off" && echo "$OUT" | grep -q "mic live" && ok "safe: scene backed off, mic still unmuted, exit 4" || bad "rc=$RC out=$OUT"
kill $HOLDER 2>/dev/null; wait $HOLDER 2>/dev/null
run "$T/m3" do scene plain
[ "$RC" = 0 ] && ok "lock released -> scene plain runs" || bad "rc=$RC out=$OUT"

echo "M4 fake pad: grabbed, keys dispatched, repeat/up ignored, busy press dropped, unplug survived"
FX="$T/m4"; mkdir -p "$FX"; : > "$FX/log"
PATH="$SHIM:$PATH" FX="$FX" FX_MODE_SLEEP=2 "$PY" - "$PAD" "$FX" > "$FX/out" 2>&1 <<'EOF'
import os, subprocess, sys, time
import evdev
from evdev import ecodes as E
pad, fx = sys.argv[1], sys.argv[2]
keys = [E.KEY_KP0, E.KEY_KP1, E.KEY_KP5, E.KEY_KP9, E.KEY_KPDOT, E.KEY_NUMLOCK]
ui = evdev.UInput({E.EV_KEY: keys}, name="Hailuck fake pad (obs-macro-pad test)")
time.sleep(0.5)                                    # let udev settle before the daemon opens it
d = subprocess.Popen([pad, "run", "--device", ui.device.path], stdout=open(os.path.join(fx, "daemon"), "w"),
                     stderr=subprocess.STDOUT, env=dict(os.environ, FX=fx))
def lines():
    return open(os.path.join(fx, "daemon")).read().splitlines()
for _ in range(50):                                # inject ONLY after the grab: nothing reaches the desktop
    if any(l.startswith("grabbed") for l in lines()):
        break
    time.sleep(0.1)
else:
    print("no grab"); d.kill(); sys.exit(1)
def tap(code, repeat=False):
    ui.write(E.EV_KEY, code, 1); ui.syn()
    if repeat:
        ui.write(E.EV_KEY, code, 2); ui.syn()
    ui.write(E.EV_KEY, code, 0); ui.syn()
    time.sleep(0.15)
tap(E.KEY_KP1, repeat=True)                        # scene plain, once (repeat ignored)
tap(E.KEY_KP5)                                     # mic toggle
tap(E.KEY_NUMLOCK)                                 # unmapped
tap(E.KEY_KP9)                                     # camera-mode toggle: the shim sleeps 2 s
time.sleep(0.3)
tap(E.KEY_KP1)                                     # one press queues…
tap(E.KEY_KP5)                                     # …the next is dropped (busy)
time.sleep(3.5)
ui.close()                                         # unplug
time.sleep(1.5)
print("\n".join(lines()))
d.terminate(); d.wait(5)
EOF
OUT="$(cat "$FX/out")"; LOG="$(cat "$FX/log")"
echo "$OUT" | grep -q "^grabbed .*Hailuck fake pad" && ok "fake pad grabbed" || bad "no grab: $OUT"
[ "$(echo "$OUT" | grep -c "key=KEY_KP1 verb='scene plain'")" = 2 ] && ok "KP1 dispatched twice (repeat ignored, key-up ignored)" || bad "$OUT"
echo "$OUT" | grep -q "key=KEY_KP5 verb='mic toggle' rc=0 .*mic muted" && ok "KP5 -> mic toggle -> muted" || bad "$OUT"
echo "$OUT" | grep -q "key=KEY_NUMLOCK unmapped" && ok "NumLock swallowed as unmapped" || bad "$OUT"
echo "$OUT" | grep -q "dropped (busy)" && ok "a press during camera-mode dropped, not queued" || bad "$OUT"
echo "$LOG" | grep -q "camera-mode fast" && ok "camera-mode shim ran once" || bad "$LOG"
echo "$OUT" | grep -q "pad gone; waiting" && ok "unplug -> 'pad gone; waiting', daemon alive" || bad "$OUT"

echo "M5 serve: loopback HTTP = the same verbs and the same lock; busy -> 409; lock held -> 423; bad verb -> 400"
FX="$T/m5"; mkdir -p "$FX"; : > "$FX/log"
PORT=$(( 20000 + RANDOM % 20000 ))
PATH="$SHIM:$PATH" FX="$FX" FX_MODE_SLEEP=2 "$PAD" serve --bind "127.0.0.1:$PORT" --dry-run > "$FX/daemon" 2>&1 &
SRV=$!
for i in $(seq 1 30); do curl -s -o /dev/null "http://127.0.0.1:$PORT/status" && break; sleep 0.1; done
OUT=$(curl -s -w ' %{http_code}' "http://127.0.0.1:$PORT/status")
echo "$OUT" | grep -q '"dry_run": true.* 200$' && ok "GET /status -> 200 JSON" || bad "$OUT"
kill $SRV; wait $SRV 2>/dev/null
PATH="$SHIM:$PATH" FX="$FX" FX_MODE_SLEEP=2 "$PAD" serve --bind "127.0.0.1:$PORT" > "$FX/daemon" 2>&1 &
SRV=$!
for i in $(seq 1 30); do curl -s -o /dev/null -X POST "http://127.0.0.1:$PORT/do/none" && break; sleep 0.1; done
OUT=$(curl -s -w ' %{http_code}' -X POST "http://127.0.0.1:$PORT/do/scene/brand")
echo "$OUT" | grep -q '"rc": 0.* 200$' && grep -q "camera-scene brand" "$FX/log" && ok "POST /do/scene/brand -> camera-scene brand, 200" || bad "$OUT $(cat $FX/log)"
OUT=$(curl -s -w ' %{http_code}' -X POST "http://127.0.0.1:$PORT/do/scene/sideways")
echo "$OUT" | grep -q ' 400$' && ok "bad arg -> 400" || bad "$OUT"
OUT=$(curl -s -w ' %{http_code}' "http://127.0.0.1:$PORT/do/scene/plain")
echo "$OUT" | grep -q ' 404$' && ok "GET /do -> 404 (writes are POST only)" || bad "$OUT"
curl -s -o /dev/null -X POST "http://127.0.0.1:$PORT/do/camera-mode/fast" &
sleep 0.4
OUT=$(curl -s -w ' %{http_code}' -X POST "http://127.0.0.1:$PORT/do/mic/toggle")
echo "$OUT" | grep -q '"busy".* 409$' && ok "a second POST while camera-mode runs -> 409 busy" || bad "$OUT"
wait %% 2>/dev/null; sleep 2.2
"$PY" -c 'import fcntl,sys,time; f=open(sys.argv[1],"w"); fcntl.flock(f,fcntl.LOCK_EX); time.sleep(20)' "$T/camera-stack.lock" &
HOLDER=$!; sleep 0.5
OUT=$(curl -s -w ' %{http_code}' -X POST "http://127.0.0.1:$PORT/do/scene/plain")
echo "$OUT" | grep -q '"rc": 4.* 423$' && ok "lock held -> 423 Locked, nothing run" || bad "$OUT"
kill $HOLDER 2>/dev/null; wait $HOLDER 2>/dev/null
kill $SRV; wait $SRV 2>/dev/null
grep -q "http verb='scene brand' rc=0" "$FX/daemon" && ok "one journal line per HTTP verb" || bad "$(cat $FX/daemon)"

echo "M6 push: after a verb the mic/mode/camera state lands in Companion custom variables; only changes; a down Companion is logged once"
FX="$T/m6"; mkdir -p "$FX"; : > "$FX/log"
CPORT=$(( 20000 + RANDOM % 20000 )); PORT=$(( 20000 + RANDOM % 20000 ))
"$PY" - "$CPORT" "$FX/companion" > /dev/null 2>&1 <<'PYEOF' &
import sys, http.server
port, out = int(sys.argv[1]), sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        open(out, "a").write(self.path + "\n"); self.send_response(200); self.end_headers()
    def do_GET(self):                       # a restarted Companion: every variable reads back EMPTY
        self.send_response(200); self.end_headers(); self.wfile.write(b"")
http.server.HTTPServer(("127.0.0.1", port), H).serve_forever()
PYEOF
CSRV=$!
: > "$FX/companion"
PATH="$SHIM:$PATH" FX="$FX" COMPANION_URL="http://127.0.0.1:$CPORT" OBS_MACRO_PAD_PUSH_S=60 "$PAD" serve --bind "127.0.0.1:$PORT" --dry-run > "$FX/daemon" 2>&1 &
SRV=$!
for i in $(seq 1 30); do curl -s -o /dev/null "http://127.0.0.1:$PORT/status" && break; sleep 0.1; done
sleep 0.5
grep -q "pad_mic/value?value=%3F" "$FX/companion" && ok "first push sends every variable (dry-run state '?')" || bad "$(cat $FX/companion)"
n0=$(wc -l < "$FX/companion")
curl -s -o /dev/null -X POST "http://127.0.0.1:$PORT/do/none"; sleep 0.3
[ "$(wc -l < "$FX/companion")" = "$n0" ] && ok "no change -> nothing re-sent" || bad "re-sent: $(cat $FX/companion)"
kill $SRV; wait $SRV 2>/dev/null
: > "$FX/companion"
PATH="$SHIM:$PATH" FX="$FX" COMPANION_URL="http://127.0.0.1:$CPORT" OBS_MACRO_PAD_PUSH_S=0.2 OBS_MACRO_PAD_RESYNC_N=2 "$PAD" serve --bind "127.0.0.1:$PORT" --dry-run > "$FX/daemon" 2>&1 &
SRV=$!; sleep 1.5
[ "$(grep -c 'pad_mic/value' "$FX/companion")" -ge 3 ] && ok "a Companion whose variables read back empty is re-sent on the resync cycle" || bad "$(cat $FX/companion)"
kill $CSRV; wait $CSRV 2>/dev/null
kill $SRV; wait $SRV 2>/dev/null
PATH="$SHIM:$PATH" FX="$FX" COMPANION_URL="http://127.0.0.1:$CPORT" OBS_MACRO_PAD_PUSH_S=0.2 "$PAD" serve --bind "127.0.0.1:$PORT" --dry-run > "$FX/daemon" 2>&1 &
SRV=$!; sleep 1.5
[ "$(grep -c 'companion push failed' "$FX/daemon")" = 1 ] && ok "Companion down -> logged once" || bad "$(cat $FX/daemon)"
kill $SRV; wait $SRV 2>/dev/null

echo
[ "$fail" = 0 ] && echo "ALL OK" || echo "$fail FAILED"
exit $(( fail > 0 ))
