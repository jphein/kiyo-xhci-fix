#!/bin/bash
# Offline tests for katana-av/mic-measure: a pw-record shim writes a synthetic
# capture (with the zero-filled start-up buffer a resuming source really hands
# over), and the verdict must separate start-up silence from a mid-call dropout.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
mkdir -p "$ROOT/tmp"
T="$(mktemp -d "$ROOT/tmp/mic-measure-test.XXXXXX")"; trap 'rm -rf "$T"' EXIT
fail=0
ok()  { echo "  [ok]   $1"; }
bad() { echo "  [FAIL] $1"; fail=$((fail+1)); }

SHIM="$T/shim"; mkdir -p "$SHIM" "$T/run"
cat > "$SHIM/pactl" <<'S'
#!/bin/bash
printf '71\talsa_input.usb-Focusrite_Scarlett_2i2_4th_Gen_X-00.HiFi__Mic1__source\tPipeWire\ts32le 2ch 48000Hz\tRUNNING\n'
S
cat > "$SHIM/pw-top" <<'S'
#!/bin/bash
e=0; [ -f "$FX_ERR" ] && e=$(cat "$FX_ERR")
printf 'S   ID  QUANT   RATE    WAIT    BUSY   W/Q   B/Q  ERR FORMAT           NAME \nS   ID  QUANT   RATE    WAIT    BUSY   W/Q   B/Q  ERR FORMAT           NAME \nR   71   4096  48000  62.0us   1.0us  0.00  0.00    %s S32LE 2 48000 alsa_input.usb-Focusrite_Scarlett_2i2_4th_Gen_X-00.HiFi__Mic1__source\n' "$e"
S
cat > "$SHIM/pw-record" <<'S'
#!/bin/bash
# write FX_SECS seconds of a -30 dBFS tone: 85 ms zero start-up, optional gap, then
# sleep so the wall clock matches what was "delivered" (FX_SHORT seconds fewer)
out="${@: -1}"
python3 -I - "$out" <<'PY'
import os, sys, wave, math, struct
secs = float(os.environ.get("FX_SECS", "2")); gap = os.environ.get("FX_GAP") == "1"
n = int(secs * 48000) - int(float(os.environ.get("FX_SHORT", "0")) * 48000)
w = wave.open(sys.argv[1], "wb"); w.setnchannels(2); w.setsampwidth(2); w.setframerate(48000)
fr = []
for i in range(n):
    v = 0 if i < 4080 else int(1036 * math.sin(i / 9)) or 1
    if gap and 48000 <= i < 48000 + 480: v = 0          # a 10 ms hole one second in
    fr.append(struct.pack("<hh", v, v))
w.writeframes(b"".join(fr)); w.close()
PY
[ -n "${FX_BUMP_ERR:-}" ] && echo 3 > "$FX_ERR"
sleep "${FX_SECS:-2}"
S
chmod +x "$SHIM"/*

run_mm() { OUT=$(PATH="$SHIM:$PATH" XDG_RUNTIME_DIR="$T/run" FX_ERR="$T/err.$1" "$ROOT/katana-av/mic-measure" 2 2>&1); RC=$?; }

echo "M1 clean capture with the real start-up zeros → PASS"
FX_SECS=2 run_mm m1
[ "$RC" = 0 ] && ok "exit 0" || bad "exit $RC"; echo "$OUT" | sed 's/^/        /' | grep -E "RESULT|dropouts"
echo "$OUT" | grep -q "dropouts    0 run.*start-up silence 85 ms" && ok "start-up silence reported apart" || bad "start-up not separated"

echo "M2 a 10 ms hole inside the signal → FAIL"
FX_SECS=2 FX_GAP=1 run_mm m2
[ "$RC" = 1 ] && ok "exit 1" || bad "exit $RC"
echo "$OUT" | grep -q "dropouts    1 run" && ok "one dropout counted" || bad "$(echo "$OUT" | grep dropouts)"

echo "M3 capture delivers 0.5 s less than the wall clock (a stall) → FAIL"
FX_SECS=2 FX_SHORT=0.5 run_mm m3
[ "$RC" = 1 ] && ok "exit 1" || bad "exit $RC"
echo "$OUT" | grep -qE "shortfall [0-9]+ \((4[0-9]{2}|5[0-9]{2}) ms\)" && ok "shortfall ~500 ms" || bad "$(echo "$OUT" | grep frames)"

echo "M4 new xruns during the capture → FAIL"
FX_SECS=2 FX_BUMP_ERR=1 run_mm m4
[ "$RC" = 1 ] && ok "exit 1" || bad "exit $RC"
echo "$OUT" | grep -q "ERR on Scarlett nodes 0 -> 3 (+3)" && ok "+3 xruns" || bad "$(echo "$OUT" | grep xruns)"

echo "M5 the audio file is removed afterwards; bad usage → 2"
[ -z "$(ls -A "$T/run")" ] && ok "no capture left in the runtime dir" || bad "left: $(ls "$T/run")"
OUT=$(PATH="$SHIM:$PATH" "$ROOT/katana-av/mic-measure" abc 2>&1); [ $? = 2 ] && ok "usage exit 2" || bad "usage"

echo; echo "fail=$fail"
[ "$fail" -eq 0 ]
