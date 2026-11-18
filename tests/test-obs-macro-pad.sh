#!/bin/bash
# Offline tests for katana-av/obs-macro-pad: camera-scene, camera-mode and wpctl are shims; OBS is never written
# (verbs that need it run --dry-run). Pins: the map names only known verbs; one press = the stack's own verb; the
# camera-stack lock held = backed off, nothing run; a FAKE pad (uinput) is grabbed and its keys dispatched, key
# repeat and key-up ignored, a press during a running verb dropped (never run later), an unplug survived without a
# leaked thread, SIGTERM finishes the running verb before the pad is released, a stranger under the pad's by-id name
# is refused (exit 2), and only <name>[-ifNN]-event-* is matched (an empty prefix is refused before any grab). No real
# input device is touched: keys are injected only after the daemon reports the grab, so nothing reaches the desktop.
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
# systemd-run: the serve unit's escape for camera-mode; the shim logs the wrapper and execs what follows "--"
printf '#!/bin/bash\nargs=("$@"); while [ "$1" != "--" ]; do shift; done; shift; echo "systemd-run ${args[*]%% -- *}" >> "$FX/log"; exec "$@"\n' > "$SHIM/systemd-run"
chmod +x "$SHIM"/*
# the vendored map, never JP's ~/.config copy (the test must not depend on his edits)
export CAMERA_STACK_LOCK="$T/camera-stack.lock" OBS_MACRO_PAD_STATE="$T/state.json" OBS_MACRO_PAD_MAP="$ROOT/katana-av/obs-macro-pad.json"
# the HTTP token: a 0600 file, as install.sh makes it
( umask 077; head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$T/token" ); TOK="$(cat "$T/token")"
export OBS_MACRO_PAD_TOKEN_FILE="$T/token"
AUTH=(-H "Authorization: Bearer $TOK")

run() {   # run <fixture> <args...> -> OUT RC LOG
    local fx="$1"; shift; mkdir -p "$fx"; : > "$fx/log"
    OUT=$(PATH="$SHIM:$PATH" FX="$fx" "$PAD" "$@" 2>&1); RC=$?
    LOG="$(cat "$fx/log")"
}

echo "M1 map: the vendored map loads, names only known verbs; a bad verb is refused before any grab"
run "$T/m1" map
[ "$RC" = 0 ] && ok "exit 0" || bad "exit $RC: $OUT"
echo "$OUT" | grep -q "KEY_KP5 *mic toggle" && ok "KP5 = mic toggle" || bad "$OUT"
echo '{"device":"x","vendor":"258e","product":"000f","keys":{"KEY_KP1":"scene nowhere"}}' > "$T/bad.json"
OUT=$(OBS_MACRO_PAD_MAP="$T/bad.json" "$PAD" map 2>&1); RC=$?
[ "$RC" = 2 ] && echo "$OUT" | grep -q "bad map" && ok "unknown verb arg -> exit 2" || bad "exit $RC: $OUT"
# fail closed on the device: an empty or wildcard prefix would glob every /dev/input/by-id device (keyboard, mouse)
for dev in '""' '"*"' '"usb-*"' 'null'; do
    echo '{"device":'"$dev"',"vendor":"258e","product":"000f","keys":{"KEY_KP1":"scene plain"}}' > "$T/bad.json"
    OUT=$(OBS_MACRO_PAD_MAP="$T/bad.json" "$PAD" map 2>&1); RC=$?
    [ "$RC" = 2 ] && echo "$OUT" | grep -q "bad map: device" && ok "device $dev -> refused, exit 2" || bad "device $dev: exit $RC: $OUT"
done
echo '{"device":"usb-X","product":"000f","keys":{"KEY_KP1":"scene plain"}}' > "$T/bad.json"
OUT=$(OBS_MACRO_PAD_MAP="$T/bad.json" "$PAD" map 2>&1); RC=$?
[ "$RC" = 2 ] && echo "$OUT" | grep -q "bad map: vendor" && ok "no vendor id -> refused, exit 2" || bad "exit $RC: $OUT"
echo '{"device":"usb-X","vendor":"258e","product":"0x0f","keys":{"KEY_KP1":"scene plain"}}' > "$T/bad.json"
OUT=$(OBS_MACRO_PAD_MAP="$T/bad.json" "$PAD" map 2>&1); RC=$?
[ "$RC" = 2 ] && echo "$OUT" | grep -q "bad map: product" && ok "malformed product id -> refused, exit 2" || bad "exit $RC: $OUT"
"$PAD" map | grep -q "usb 258e:000f" && ok "map prints the pad's usb id" || bad "$("$PAD" map)"

echo "M1b find: only <name>[-ifNN]-event-* under the by-id dir is the pad; a longer name or another device never matches"
BYID="$T/byid"; mkdir -p "$BYID"
for l in usb-X-event-kbd usb-X-if01-event-kbd usb-X-event-if01 usb-X-hidraw usb-Xtra-event-kbd usb-X-if01-hidraw usb-Other-event-mouse usb-Keyboard-event-kbd; do ln -s /dev/null "$BYID/$l"; done
echo '{"device":"usb-X","vendor":"258e","product":"000f","keys":{"KEY_KP1":"scene plain"}}' > "$T/find.json"
OUT=$(OBS_MACRO_PAD_BY_ID="$BYID" OBS_MACRO_PAD_MAP="$T/find.json" "$PAD" find 2>&1); RC=$?
[ "$RC" = 0 ] && [ "$(echo "$OUT" | wc -l)" = 3 ] && echo "$OUT" | grep -q "usb-X-event-kbd" && echo "$OUT" | grep -q "usb-X-if01-event-kbd" && echo "$OUT" | grep -q "usb-X-event-if01" && ok "usb-X -> exactly its 3 event interfaces" || bad "rc=$RC: $OUT"
echo "$OUT" | grep -q "Xtra\|Other\|Keyboard\|hidraw" && bad "a stranger matched: $OUT" || ok "usb-Xtra, usb-Other, usb-Keyboard, hidraw nodes never match"
echo '{"device":"usb-Nope","vendor":"258e","product":"000f","keys":{"KEY_KP1":"scene plain"}}' > "$T/find.json"
OUT=$(OBS_MACRO_PAD_BY_ID="$BYID" OBS_MACRO_PAD_MAP="$T/find.json" "$PAD" find 2>&1); RC=$?
[ "$RC" = 1 ] && [ -z "$OUT" ] && ok "unknown pad -> nothing, exit 1" || bad "rc=$RC: $OUT"

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

run "$T/m2" do camera-mode fast
echo "$LOG" | grep -q "^camera-mode fast" && ! echo "$LOG" | grep -q "systemd-run" && ok "camera-mode runs directly without OBS_MACRO_PAD_ESCAPE" || bad "$LOG"
OBS_MACRO_PAD_ESCAPE=systemd-run run "$T/m2" do camera-mode hdr
echo "$LOG" | grep -q "^systemd-run --user --quiet --wait --pipe --collect --property=RuntimeMaxSec=170" && echo "$LOG" | grep -q "^camera-mode hdr" && [ "$RC" = 0 ] && ok "OBS_MACRO_PAD_ESCAPE=systemd-run: camera-mode runs as a transient user unit (RuntimeMaxSec=170), exit code kept" || bad "rc=$RC $LOG"
OBS_MACRO_PAD_ESCAPE=systemd-run run "$T/m2" do scene plain
echo "$LOG" | grep -q "systemd-run" && bad "scene escaped the sandbox: $LOG" || ok "only camera-mode escapes; camera-scene stays in the sandbox"

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

echo "M4 fake pad: grabbed via by-id, keys dispatched, repeat/up ignored, busy presses dropped (nothing queued), unplug survived without a leaked thread, SIGTERM finishes the running verb, a stranger refused"
FX="$T/m4"; mkdir -p "$FX/byid"; : > "$FX/log"; rm -f "$T/state.json"
jq '.device = "fake-pad"' "$ROOT/katana-av/obs-macro-pad.json" > "$FX/map.json"
PATH="$SHIM:$PATH" FX="$FX" FX_MODE_SLEEP=2 OBS_MACRO_PAD_MAP="$FX/map.json" OBS_MACRO_PAD_BY_ID="$FX/byid" "$PY" - "$PAD" "$FX" > "$FX/out" 2>&1 <<'EOF'
import os, subprocess, sys, time
import evdev
from evdev import ecodes as E
pad, fx = sys.argv[1], sys.argv[2]
keys = [E.KEY_KP0, E.KEY_KP1, E.KEY_KP5, E.KEY_KP9, E.KEY_KPDOT, E.KEY_NUMLOCK]
link = os.path.join(fx, "byid", "fake-pad-event-kbd")      # what udev would make for the real pad
def plug(vendor=0x258e, product=0x000f):
    ui = evdev.UInput({E.EV_KEY: keys}, name="Hailuck fake pad (obs-macro-pad test)", vendor=vendor, product=product)
    time.sleep(0.5)                                    # let udev settle before the daemon opens it
    os.symlink(ui.device.path, link)
    return ui
def unplug(ui):
    ui.close(); os.unlink(link)
def start(outname):
    return subprocess.Popen([pad, "run"], stdout=open(os.path.join(fx, outname), "w"), stderr=subprocess.STDOUT,
                            env=dict(os.environ, FX=fx))
def lines(outname="daemon"):
    return open(os.path.join(fx, outname)).read().splitlines()
def wait_grabs(n):
    for _ in range(80):                                # inject ONLY after the grab: nothing reaches the desktop
        if sum(l.startswith("grabbed") for l in lines()) >= n:
            return True
        time.sleep(0.1)
    return False
def threads(pid):
    return int(next(l for l in open(f"/proc/{pid}/status") if l.startswith("Threads:")).split()[1])
ui = plug()
d = start("daemon")
if not wait_grabs(1):
    print("no grab"); d.kill(); sys.exit(1)
t_first = threads(d.pid)
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
tap(E.KEY_KP1)                                     # dropped (busy): NOT queued for later
tap(E.KEY_KP5)                                     # dropped (busy)
time.sleep(3.5)
unplug(ui)                                         # unplug (udev drops the by-id link)
time.sleep(1.5)
ui = plug()                                        # re-plug: a fresh worker, the old one joined
if not wait_grabs(2):
    print("no re-grab"); d.kill(); sys.exit(1)
time.sleep(0.5)
print(f"threads first={t_first} replug={threads(d.pid)}")
tap(E.KEY_KP9)                                     # camera-mode again (2 s)…
time.sleep(0.3)
t0 = time.monotonic()
d.terminate()                                      # …SIGTERM while it runs: the verb finishes, then the pad is released
time.sleep(0.6)
def grabbed():                                     # a second grab fails with EBUSY while the daemon holds it
    import errno
    x = evdev.InputDevice(ui.device.path)
    try:
        x.grab(); x.ungrab(); return False
    except OSError as e:
        if e.errno != errno.EBUSY:
            raise
        return True
    finally:
        x.close()
print(f"grabbed during stop={grabbed()}")
rc = d.wait(15)
print(f"stop rc={rc} after {time.monotonic() - t0:.1f}s grabbed after exit={grabbed()}")
unplug(ui)
ui = plug(vendor=0x1234)                           # a stranger under the pad's by-id name
d2 = start("daemon2")
try:
    rc2 = d2.wait(5)
except subprocess.TimeoutExpired:
    d2.kill(); rc2 = "timeout"
print(f"stranger rc={rc2}")
unplug(ui)
print("\n".join(lines()))
print("--- daemon2")
print("\n".join(lines("daemon2")))
EOF
OUT="$(cat "$FX/out")"; LOG="$(cat "$FX/log")"
[ "$(echo "$OUT" | grep -c "^grabbed .*Hailuck fake pad.* 258e:000f")" = 2 ] && ok "fake pad grabbed through by-id, twice (plug, re-plug), usb id logged" || bad "no grab: $OUT"
[ "$(echo "$OUT" | grep -c "key=KEY_KP1 verb='scene plain' rc=")" = 1 ] && ok "KP1 dispatched once (repeat ignored, key-up ignored, the busy press never ran)" || bad "$OUT"
echo "$OUT" | grep -q "key=KEY_KP5 verb='mic toggle' rc=0 .*mic muted" && ok "KP5 -> mic toggle -> muted" || bad "$OUT"
echo "$OUT" | grep -q "key=KEY_NUMLOCK unmapped" && ok "NumLock swallowed as unmapped" || bad "$OUT"
[ "$(echo "$OUT" | grep -c "dropped (busy)")" = 2 ] && ok "both presses during camera-mode dropped, nothing queued" || bad "$OUT"
[ "$(echo "$OUT" | grep -c "key=KEY_KP5 verb='mic toggle' rc=")" = 1 ] && ok "the dropped mic press never ran later" || bad "$OUT"
[ "$(echo "$LOG" | grep -c "^camera-mode \(fast\|hdr\)$")" = 2 ] && ok "camera-mode shim ran once per accepted KP9 (fast, then hdr), never for a dropped press" || bad "$LOG"
echo "$OUT" | grep -q "pad gone; waiting" && ok "unplug -> 'pad gone; waiting', daemon alive" || bad "$OUT"
echo "$OUT" | grep -qE "^threads first=([0-9]+) replug=\1$" && ok "re-plug leaks no worker thread ($(echo "$OUT" | grep '^threads'))" || bad "$(echo "$OUT" | grep '^threads')"
echo "$OUT" | grep -q "finishing the running verb before release" && echo "$OUT" | grep -q "key=KEY_KP9 verb='camera-mode toggle' rc=0 .*camera-mode hdr" && ok "SIGTERM mid-verb: the verb finished (camera-mode hdr rc=0) with the pad still grabbed, then released" || bad "$OUT"
echo "$OUT" | grep -qE "^stop rc=0 after (1\.[4-9]|[2-9]\.[0-9]|1[0-4]\.[0-9])s" && echo "$OUT" | grep -q "^stopped (pad released)" && ok "then exit 0 ($(echo "$OUT" | grep -o '^stop rc=0 after [0-9.]*s'))" || bad "$(echo "$OUT" | grep '^stop rc')"
echo "$OUT" | grep -q "^grabbed during stop=True" && echo "$OUT" | grep -q "grabbed after exit=False" && ok "the pad stays grabbed while the verb finishes (EBUSY for a second grab), free after exit" || bad "$(echo "$OUT" | grep 'grabbed ')"
echo "$OUT" | grep -q "^stranger rc=2" && echo "$OUT" | grep -q "^refusing .*usb id 1234:000f is not the pad's 258e:000f" && ok "a stranger under the pad's by-id name: refused, exit 2" || bad "$OUT"
[ "$(sed -n '/^--- daemon2/,$p' "$FX/out" | grep -c '^grabbed')" = 0 ] && ok "the stranger was never grabbed" || bad "$OUT"

echo "M5 serve: loopback only, token required, no browser Origin, loopback Host, no body; the same verbs and the same lock; busy -> 409; lock held -> 423; bad verb -> 400; 8 workers"
FX="$T/m5"; mkdir -p "$FX"; : > "$FX/log"
PORT=$(( 20000 + RANDOM % 20000 ))
for b in "0.0.0.0:$PORT" "10.0.8.5:$PORT" "[::]:$PORT" "katana:$PORT"; do
    OUT=$(PATH="$SHIM:$PATH" FX="$FX" timeout 5 "$PAD" serve --bind "$b" --dry-run 2>&1); RC=$?
    [ "$RC" = 2 ] && echo "$OUT" | grep -qF "refusing to bind $b: loopback only" && ok "bind $b -> refused, exit 2, nothing listens" || bad "bind $b: rc=$RC $OUT"
done
chmod 0644 "$T/token"
OUT=$(PATH="$SHIM:$PATH" FX="$FX" timeout 5 "$PAD" serve --bind "127.0.0.1:$PORT" --dry-run 2>&1); RC=$?
[ "$RC" = 2 ] && echo "$OUT" | grep -q "refusing to serve: .*must be 0600, is 0644" && ok "token file 0644 -> refused, exit 2" || bad "rc=$RC $OUT"
chmod 0600 "$T/token"
OUT=$(PATH="$SHIM:$PATH" FX="$FX" OBS_MACRO_PAD_TOKEN_FILE="$T/no-such-token" timeout 5 "$PAD" serve --bind "127.0.0.1:$PORT" --dry-run 2>&1); RC=$?
[ "$RC" = 2 ] && echo "$OUT" | grep -q "refusing to serve: no token file" && ok "no token file -> refused, exit 2" || bad "rc=$RC $OUT"
PATH="$SHIM:$PATH" FX="$FX" FX_MODE_SLEEP=2 "$PAD" serve --bind "127.0.0.1:$PORT" --dry-run > "$FX/daemon" 2>&1 &
SRV=$!
for i in $(seq 1 30); do curl -s -o /dev/null "http://127.0.0.1:$PORT/status" && break; sleep 0.1; done
grep -q "^serving on http://127.0.0.1:$PORT (loopback, token from" "$FX/daemon" && ok "serves on 127.0.0.1 and says where the token came from" || bad "$(cat $FX/daemon)"
OUT=$(curl -s -w ' %{http_code}' "http://127.0.0.1:$PORT/status")
echo "$OUT" | grep -q '"token required.* 401$' && ok "GET /status without a token -> 401" || bad "$OUT"
OUT=$(curl -s -w ' %{http_code}' -H "Authorization: Bearer not-the-token-not-the-token-xx" "http://127.0.0.1:$PORT/status")
echo "$OUT" | grep -q ' 401$' && ok "wrong token -> 401" || bad "$OUT"
OUT=$(curl -s -w ' %{http_code}' "${AUTH[@]}" "http://127.0.0.1:$PORT/status")
echo "$OUT" | grep -q '"dry_run": true.* 200$' && ok "GET /status with the token -> 200 JSON" || bad "$OUT"
OUT=$(curl -s -w ' %{http_code}' -u "pad:$TOK" "http://127.0.0.1:$PORT/status")
echo "$OUT" | grep -q '"dry_run": true.* 200$' && ok "Basic auth with the token as password (Companion's connection auth) -> 200" || bad "$OUT"
OUT=$(curl -s -w ' %{http_code}' -u "pad:nope" "http://127.0.0.1:$PORT/status")
echo "$OUT" | grep -q ' 401$' && ok "Basic auth with a wrong password -> 401" || bad "$OUT"
OUT=$(curl -s -w ' %{http_code}' "${AUTH[@]}" -H "Origin: http://evil.example" -X POST "http://127.0.0.1:$PORT/do/none")
echo "$OUT" | grep -q '"browser origin refused".* 403$' && ok "a browser Origin (even with the token) -> 403" || bad "$OUT"
OUT=$(curl -s -w ' %{http_code}' "${AUTH[@]}" -H "Origin: http://127.0.0.1:$PORT" -X POST "http://127.0.0.1:$PORT/do/none")
echo "$OUT" | grep -q ' 403$' && ok "a same-origin Origin too: no page drives the stack" || bad "$OUT"
OUT=$(curl -s -w ' %{http_code}' "${AUTH[@]}" -H "Host: katana.lan:$PORT" -X POST "http://127.0.0.1:$PORT/do/none")
echo "$OUT" | grep -q '"host must be loopback".* 403$' && ok "Host: katana.lan (DNS rebinding) -> 403" || bad "$OUT"
OUT=$(curl -s -w ' %{http_code}' "${AUTH[@]}" -H "Host: localhost:$PORT" -X POST "http://127.0.0.1:$PORT/do/none")
echo "$OUT" | grep -q ' 200$' && ok "Host: localhost -> ok" || bad "$OUT"
OUT=$(curl -s -w ' %{http_code}' "${AUTH[@]}" -X POST -H "Content-Type: application/json" -d '{}' "http://127.0.0.1:$PORT/do/none")
echo "$OUT" | grep -q '"verb": "none".* 200$' && ok "Companion's POST body '{}' is read and dropped -> 200" || bad "$OUT"
OUT=$(curl -s -w ' %{http_code}' "${AUTH[@]}" -X POST -d '{"verb":"safe"}' "http://127.0.0.1:$PORT/do/none")
echo "$OUT" | grep -q '"verb": "none".* 200$' && ok "a body naming another verb changes nothing (the path is the verb)" || bad "$OUT"
OUT=$(curl -s -w ' %{http_code}' "${AUTH[@]}" -X POST -d "$(head -c 257 /dev/zero | tr '\0' x)" "http://127.0.0.1:$PORT/do/none")
echo "$OUT" | grep -q '"body too large.* 413$' && ok "a 257-byte body -> 413" || bad "$OUT"
OUT=$(curl -s -w ' %{http_code}' "${AUTH[@]}" -X POST -H "Transfer-Encoding: chunked" -d 'x' "http://127.0.0.1:$PORT/do/none")
echo "$OUT" | grep -q ' 400$' && ok "a chunked POST -> 400" || bad "$OUT"
OUT=$(curl -s -w ' %{http_code}' -H "authorization: bearer $TOK" -X POST "http://127.0.0.1:$PORT/do/none")
echo "$OUT" | grep -q ' 200$' && ok "scheme is case-insensitive: 'bearer' -> 200" || bad "$OUT"
OUT=$(curl -s -w ' %{http_code}' -H "Authorization: BASIC $(printf 'pad:%s' "$TOK" | base64 -w0)" -X POST "http://127.0.0.1:$PORT/do/none")
echo "$OUT" | grep -q ' 200$' && ok "'BASIC' -> 200" || bad "$OUT"
kill $SRV; wait $SRV 2>/dev/null
PATH="$SHIM:$PATH" FX="$FX" FX_MODE_SLEEP=2 "$PAD" serve --bind "127.0.0.1:$PORT" > "$FX/daemon" 2>&1 &
SRV=$!
for i in $(seq 1 30); do curl -s -o /dev/null "${AUTH[@]}" -X POST "http://127.0.0.1:$PORT/do/none" && break; sleep 0.1; done
OUT=$(curl -s -w ' %{http_code}' "${AUTH[@]}" -X POST "http://127.0.0.1:$PORT/do/scene/brand")
echo "$OUT" | grep -q '"rc": 0.* 200$' && grep -q "camera-scene brand" "$FX/log" && ok "POST /do/scene/brand -> camera-scene brand, 200" || bad "$OUT $(cat $FX/log)"
OUT=$(curl -s -w ' %{http_code}' "${AUTH[@]}" -X POST "http://127.0.0.1:$PORT/do/scene/sideways")
echo "$OUT" | grep -q ' 400$' && ok "bad arg -> 400" || bad "$OUT"
: > "$FX/log"
for p in '/do/scene/plain;id' '/do/scene/plain/extra' '/do/scene%20plain' '/do/scene/..%2Fplain' '/do/mic/toggle?x=$(id)' '/do/safe/' '/do/SCENE/plain' '/do/scene/plain%00'; do
    OUT=$(curl -s -g -w ' %{http_code}' "${AUTH[@]}" -X POST "http://127.0.0.1:$PORT$p")
    case "$p" in /do/safe/) echo "$OUT" | grep -q ' 200$' && ok "trailing slash: $p -> 200" || bad "$p: $OUT";;
                 '/do/mic/toggle?x=$(id)') echo "$OUT" | grep -q ' 200$' && ok "query string ignored: $p -> 200" || bad "$p: $OUT";;
                 *) echo "$OUT" | grep -q ' 404$' && ok "metacharacters / extra arg / case: $p -> 404" || bad "$p: $OUT";; esac
done
grep -q "id\|extra\|%" "$FX/log" && bad "a metacharacter path reached a tool: $(cat $FX/log)" || ok "nothing but the allow-listed verbs reached a tool"
OUT=$(curl -s -w ' %{http_code}' "${AUTH[@]}" "http://127.0.0.1:$PORT/do/scene/plain")
echo "$OUT" | grep -q ' 404$' && ok "GET /do -> 404 (writes are POST only)" || bad "$OUT"
# raw requests against the shim-backed server: malformed framing and duplicate security headers are refused
# (400/401/403) and NOTHING runs; the positive control just above (scene brand logged) shows the log would see it
: > "$FX/log"
raw() {   # raw <description> <expected code> <request lines…>
    local desc="$1" want="$2"; shift 2
    local got
    got=$("$PY" - "$PORT" "$@" <<'PYEOF'
import socket, sys
port, lines = int(sys.argv[1]), sys.argv[2:]
s = socket.create_connection(("127.0.0.1", port)); s.settimeout(5)
s.sendall(("\r\n".join(lines) + "\r\n\r\n").encode("latin-1", "surrogateescape"))   # latin-1: a raw 0xb2 byte (argv surrogate) reaches the parser as-is
data = b""
try:
    while True:
        chunk = s.recv(4096)
        if not chunk:
            break
        data += chunk
except (TimeoutError, ConnectionResetError):
    pass
print(data.split(b"\r\n")[0].decode(errors="replace"))
PYEOF
)
    echo "$got" | grep -q "^HTTP/1.0 $want " && ok "$desc -> $want" || bad "$desc: got '$got'"
}
raw "Content-Length: abc"        400 "POST /do/scene/plain HTTP/1.0" "Host: 127.0.0.1" "Authorization: Bearer $TOK" "Content-Length: abc"
raw "Content-Length: -1"         400 "POST /do/scene/plain HTTP/1.0" "Host: 127.0.0.1" "Authorization: Bearer $TOK" "Content-Length: -1"
raw "Content-Length twice"       400 "POST /do/scene/plain HTTP/1.0" "Host: 127.0.0.1" "Authorization: Bearer $TOK" "Content-Length: 0" "Content-Length: 0"
raw "Transfer-Encoding: (empty)" 400 "POST /do/scene/plain HTTP/1.0" "Host: 127.0.0.1" "Authorization: Bearer $TOK" "Transfer-Encoding:"
raw "Content-Length: 0 (plain)"  200 "POST /do/none HTTP/1.0" "Host: 127.0.0.1" "Authorization: Bearer $TOK" "Content-Length: 0"
raw "Content-Length: 300"        413 "POST /do/scene/plain HTTP/1.0" "Host: 127.0.0.1" "Authorization: Bearer $TOK" "Content-Length: 300"
raw "Content-Length: ² (0xb2)"    400 "POST /do/scene/plain HTTP/1.0" "Host: 127.0.0.1" "Authorization: Bearer $TOK" "Content-Length: $(printf '\xb2')"
raw "Content-Length: 5000 digits" 413 "POST /do/scene/plain HTTP/1.0" "Host: 127.0.0.1" "Authorization: Bearer $TOK" "Content-Length: $(head -c 5000 /dev/zero | tr '\0' 9)"
raw "Content-Length: 0000000002 (leading zeros)" 200 "POST /do/none HTTP/1.0" "Host: 127.0.0.1" "Authorization: Bearer $TOK" "Content-Length: 0000000002" "" "{}"
raw "Host twice"                 403 "POST /do/scene/plain HTTP/1.0" "Host: 127.0.0.1" "Host: 127.0.0.1" "Authorization: Bearer $TOK"
raw "Host: [::1]evil.example"    403 "POST /do/scene/plain HTTP/1.0" "Host: [::1]evil.example" "Authorization: Bearer $TOK"
raw "Host: 127.0.0.1:x"          403 "POST /do/scene/plain HTTP/1.0" "Host: 127.0.0.1:x" "Authorization: Bearer $TOK"
raw "Host: [::1]:$PORT"          200 "POST /do/none HTTP/1.0" "Host: [::1]:$PORT" "Authorization: Bearer $TOK"
raw "Authorization twice"        401 "POST /do/scene/plain HTTP/1.0" "Host: 127.0.0.1" "Authorization: Bearer $TOK" "Authorization: Bearer $TOK"
raw "no Host at all"             403 "POST /do/scene/plain HTTP/1.0" "Authorization: Bearer $TOK"
grep -qE "camera-scene|camera-mode|set-mute" "$FX/log" && bad "a refused request ran a tool: $(cat $FX/log)" || ok "none of the refused requests ran a tool (the log holds only the status reads behind the two admitted /do/none)"
curl -s -o /dev/null "${AUTH[@]}" -X POST "http://127.0.0.1:$PORT/do/camera-mode/fast" &
sleep 0.4
OUT=$(curl -s -w ' %{http_code}' "${AUTH[@]}" -X POST "http://127.0.0.1:$PORT/do/mic/toggle")
echo "$OUT" | grep -q '"busy".* 409$' && ok "a second POST while camera-mode runs -> 409 busy" || bad "$OUT"
wait %% 2>/dev/null; sleep 2.2
"$PY" -c 'import fcntl,sys,time; f=open(sys.argv[1],"w"); fcntl.flock(f,fcntl.LOCK_EX); time.sleep(20)' "$T/camera-stack.lock" &
HOLDER=$!; sleep 0.5
OUT=$(curl -s -w ' %{http_code}' "${AUTH[@]}" -X POST "http://127.0.0.1:$PORT/do/scene/plain")
echo "$OUT" | grep -q '"rc": 4.* 423$' && ok "lock held -> 423 Locked, nothing run" || bad "$OUT"
kill $HOLDER 2>/dev/null; wait $HOLDER 2>/dev/null
# bounded workers + stalled clients: 8 connections that never send a request hold the 8 workers; the 9th is
# answered 503 at once; after the 10 s socket timeout the stalled ones are dropped and a real request works again
OUT=$("$PY" - "$PORT" "$TOK" <<'PYEOF'
import socket, sys, time, urllib.request, urllib.error
port, tok = int(sys.argv[1]), sys.argv[2]
idle = [socket.create_connection(("127.0.0.1", port)) for _ in range(8)]
time.sleep(0.3)
s = socket.create_connection(("127.0.0.1", port))
s.settimeout(3)
try:
    print("ninth:", s.recv(64).split(b"\r\n")[0].decode())
except TimeoutError:
    print("ninth: no answer")
s.close()
for i in idle:
    i.close()
time.sleep(0.5)
req = urllib.request.Request(f"http://127.0.0.1:{port}/do/none", method="POST", headers={"Authorization": f"Bearer {tok}"})
print("after:", urllib.request.urlopen(req, timeout=5).status)
PYEOF
)
echo "$OUT" | grep -q "^ninth: HTTP/1.0 503" && ok "8 stalled connections hold the workers, the 9th gets 503 at once" || bad "$OUT"
echo "$OUT" | grep -q "^after: 200" && ok "workers freed when the stalled clients go" || bad "$OUT"
OUT=$("$PY" - "$PORT" <<'PYEOF'
import socket, sys, time
port = int(sys.argv[1])
s = socket.create_connection(("127.0.0.1", port)); s.sendall(b"POST /do/none HTTP/1.0\r\nAuthorization: Bearer ")   # …and stalls
t0 = time.time()
try:
    data = s.recv(64)
except (ConnectionResetError, TimeoutError):
    data = b""
print(f"stalled client dropped after {time.time() - t0:.0f}s, got {data[:20]!r}")
PYEOF
)
echo "$OUT" | grep -qE "dropped after (1[0-3]|9)s" && ok "a client stalling mid-headers is dropped at the socket timeout ($(echo "$OUT" | grep -o 'after [0-9]*s'))" || bad "$OUT"
OUT=$("$PY" - "$PORT" "$TOK" <<'PYEOF'
import socket, sys, time, urllib.request
port, tok = int(sys.argv[1]), sys.argv[2]
import select
s = socket.create_connection(("127.0.0.1", port)); s.setblocking(False)
t0 = time.time(); sent = 0
try:
    while time.time() - t0 < 30:                         # bytes, never a newline, for far longer than the deadline
        s.sendall(b"x"); sent += 1
        if select.select([s], [], [], 0.5)[0] and s.recv(1) == b"":   # FIN from the server = dropped
            break
except (BrokenPipeError, ConnectionResetError):
    pass
print(f"trickling client dropped after {time.time() - t0:.0f}s, {sent} bytes")
req = urllib.request.Request(f"http://127.0.0.1:{port}/do/none", method="POST", headers={"Authorization": f"Bearer {tok}"})
print("after trickle:", urllib.request.urlopen(req, timeout=5).status)
PYEOF
)
echo "$OUT" | grep -qE "dropped after (9|1[0-3])s, (1[5-9]|2[0-9]) bytes" && ok "a client trickling bytes with no newline is dropped at the absolute 10 s deadline ($(echo "$OUT" | grep -o 'after [0-9]*s, [0-9]* bytes'))" || bad "$OUT"
echo "$OUT" | grep -q "^after trickle: 200" && ok "its worker is back" || bad "$OUT"
# an authenticated head that never ends (no blank line): the deadline's EOF must not complete it into a verb
: > "$FX/log"
OUT=$("$PY" - "$PORT" "$TOK" <<'PYEOF'
import socket, sys, time
port, tok = int(sys.argv[1]), sys.argv[2]
s = socket.create_connection(("127.0.0.1", port)); s.settimeout(14)
s.sendall(f"POST /do/scene/plain HTTP/1.0\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {tok}\r\n".encode())   # …and stalls
t0 = time.time()
try:
    data = s.recv(200)
except (TimeoutError, ConnectionResetError):
    data = b"(reset)"
print(f"unterminated head: after {time.time() - t0:.0f}s got {data[:40]!r}")
PYEOF
)
echo "$OUT" | grep -qE "^unterminated head: after (9|1[0-3])s got b''" && ok "an authenticated head with no final blank line is dropped at the deadline with no answer" || bad "$OUT"
sleep 0.5
grep -q "camera-scene plain" "$FX/log" && bad "the deadline's EOF completed the head into a verb: $(cat $FX/log)" || ok "and it never ran (no camera-scene plain in the shim log)"
# a complete, authenticated head whose declared body never arrives: dropped at the deadline, the verb never runs
: > "$FX/log"
OUT=$("$PY" - "$PORT" "$TOK" <<'PYEOF'
import socket, sys, time
port, tok = int(sys.argv[1]), sys.argv[2]
s = socket.create_connection(("127.0.0.1", port)); s.settimeout(14)
s.sendall(f"POST /do/scene/plain HTTP/1.0\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {tok}\r\nContent-Length: 10\r\n\r\n{{\"a\"".encode())   # 4 of 10 bytes, then stalls
t0 = time.time()
try:
    data = s.recv(200)
except (TimeoutError, ConnectionResetError):
    data = b"(reset)"
print(f"short body: after {time.time() - t0:.0f}s got {data[:40]!r}")
PYEOF
)
echo "$OUT" | grep -qE "^short body: after (9|1[0-3])s got b''" && ok "a body that stalls short of its Content-Length is dropped at the deadline with no answer" || bad "$OUT"
sleep 0.5
grep -q "camera-scene plain" "$FX/log" && bad "a short body ran the verb: $(cat $FX/log)" || ok "and its verb never ran"
kill $SRV; wait $SRV 2>/dev/null
# admission is after the body: a complete body + a verb that outlives a (here 1 s) deadline is never shut down
PATH="$SHIM:$PATH" FX="$FX" FX_MODE_SLEEP=2 OBS_MACRO_PAD_HTTP_TIMEOUT=1 "$PAD" serve --bind "127.0.0.1:$PORT" > "$FX/daemon-1s" 2>&1 &
SRV=$!
for i in $(seq 1 30); do curl -s -o /dev/null "${AUTH[@]}" -X POST "http://127.0.0.1:$PORT/do/none" && break; sleep 0.1; done
OUT=$(curl -s -w ' %{http_code}' "${AUTH[@]}" -X POST -d '{}' "http://127.0.0.1:$PORT/do/camera-mode/fast")
echo "$OUT" | grep -q '"rc": 0.* 200$' && echo "$OUT" | grep -qE '"ms": (19|2[0-9])[0-9][0-9]' && ok "body '{}' + a 2 s verb under a 1 s deadline: admitted, ran to the end, 200" || bad "$OUT"
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
for i in $(seq 1 30); do curl -s -o /dev/null "${AUTH[@]}" "http://127.0.0.1:$PORT/status" && break; sleep 0.1; done
sleep 0.5
grep -q "pad_mic/value?value=%3F" "$FX/companion" && ok "first push sends every variable (dry-run state '?')" || bad "$(cat $FX/companion)"
n0=$(wc -l < "$FX/companion")
OUT=$(curl -s -w ' %{http_code}' "${AUTH[@]}" -X POST "http://127.0.0.1:$PORT/do/none"); sleep 0.3
echo "$OUT" | grep -q ' 200$' && [ "$(wc -l < "$FX/companion")" = "$n0" ] && ok "no change -> nothing re-sent" || bad "re-sent: $(cat $FX/companion)"
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
