#!/bin/bash
# Offline tests for katana-av/audio-watchdog.sh against pactl/pw-metadata shims.
# What changed on 2026-11-08 is what is pinned here: a state line is logged once
# per change (not every 2 s), the log rotates, every call app's mic is moved to
# Mic 1 (mic-keeper's job), and a stream reading a monitor is never moved.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
mkdir -p "$ROOT/tmp"
T="$(mktemp -d "$ROOT/tmp/audio-watchdog-test.XXXXXX")"; trap 'rm -rf "$T"' EXIT
fail=0
ok()  { echo "  [ok]   $1"; }
bad() { echo "  [FAIL] $1"; fail=$((fail+1)); }

SINK=alsa_output.usb-Focusrite_Scarlett_2i2_4th_Gen_S2A4HVU52AA44B-00.HiFi__Line1__sink
SRC=alsa_input.usb-Focusrite_Scarlett_2i2_4th_Gen_S2A4HVU52AA44B-00.HiFi__Mic1__source

SHIM="$T/shim"; mkdir -p "$SHIM"
cat > "$SHIM/pactl" <<'S'
#!/bin/bash
case "$*" in
  "list cards short")                    cat "$FX/cards_short" 2>/dev/null ;;
  "list cards")                          cat "$FX/cards" 2>/dev/null ;;
  "list sinks short"|"list short sinks") cat "$FX/sinks" ;;
  "list sources short"|"list short sources") cat "$FX/sources" ;;
  "get-default-sink")                    cat "$FX/default_sink" ;;
  "get-default-source")                  cat "$FX/default_source" ;;
  "list sink-inputs")                    cat "$FX/sink_inputs" 2>/dev/null ;;
  "list source-outputs")                 cat "$FX/source_outputs" 2>/dev/null ;;
  set-*|move-*|suspend-*)                echo "$*" >> "$FX/actions" ;;
  *) exit 1 ;;
esac
S
cat > "$SHIM/pw-metadata" <<'S'
#!/bin/bash
k="${4:-}"
if [ $# -ge 5 ]; then echo "$5" > "$FX/meta.$k"; exit 0; fi
[ -f "$FX/meta.$k" ] && echo "update: id:0 key:'$k' value:'$(cat "$FX/meta.$k")' type:''"
exit 0
S
printf '#!/bin/bash\nexit 0\n' > "$SHIM/pw-top"
printf '#!/bin/bash\necho "notify $*" >> "$FX/notify"\n' > "$SHIM/notify-send"
printf '#!/bin/bash\nexit 1\n' > "$SHIM/sudo"
chmod +x "$SHIM"/*

build() {   # build <dir> : Scarlett present, settings already correct, nothing to do
    local fx="$1"; mkdir -p "$fx/state"
    printf '61\talsa_card.usb-Focusrite_Scarlett_2i2_4th_Gen_S2A4HVU52AA44B-00\talsa\n' > "$fx/cards_short"
    printf 'Card #61\n\tName: alsa_card.usb-Focusrite_Scarlett_2i2_4th_Gen_S2A4HVU52AA44B-00\n\tActive Profile: HiFi (Line1, Line2, Mic1, Mic2)\n' > "$fx/cards"
    printf '70\t%s\tPipeWire\ts32le 2ch 48000Hz\tRUNNING\n' "$SINK" > "$fx/sinks"
    printf '57\talsa_output.pci-0000_00_1f.3.iec958-stereo.monitor\tPipeWire\ts32le 2ch 48000Hz\tIDLE\n71\t%s\tPipeWire\ts32le 2ch 48000Hz\tRUNNING\n80\talsa_input.usb-Razer_Inc_Razer_Kiyo_Pro-02.iec958-stereo\tPipeWire\ts16le 2ch 48000Hz\tIDLE\n' "$SRC" > "$fx/sources"
    echo "$SINK" > "$fx/default_sink"; echo "$SRC" > "$fx/default_source"
    echo 48000 > "$fx/meta.clock.force-rate"; echo 4096 > "$fx/meta.clock.force-quantum"
}
outputs() {  # outputs <dir> "<id> <source-id> <app name>"...
    local fx="$1"; shift; : > "$fx/source_outputs"
    for o in "$@"; do
        read -r id s app <<< "$o"
        printf 'Source Output #%s\n\tDriver: PipeWire\n\tSource: %s\n\tProperties:\n\t\tapplication.name = "%s"\n\n' "$id" "$s" "$app" >> "$fx/source_outputs"
    done
}
run_wd() {   # run_wd <dir> <passes>
    local fx="$1" n="$2"
    PATH="$SHIM:$PATH" FX="$fx" AUDIO_WD_STATE="$fx/state" INTERVAL=0 MAX_PASSES="$n" LOG_MAX="${LOG_MAX:-5242880}" \
        timeout 30 "$ROOT/katana-av/audio-watchdog.sh" >/dev/null 2>&1
}
count() { grep -c -- "$2" "$1" 2>/dev/null || true; }

echo "W1 no Scarlett for 5 passes → one state line, not five"
fx="$T/w1"; build "$fx"; : > "$fx/cards_short"; run_wd "$fx" 5
[ "$(count "$fx/state/log" 'no Scarlett card')" = 1 ] && ok "logged once" || bad "logged $(count "$fx/state/log" 'no Scarlett card') times"
[ ! -s "$fx/actions" ] && ok "no actions without a Scarlett" || bad "acted: $(cat "$fx/actions")"

echo "W2 Scarlett present and correct for 5 passes → one 'present' line, no ACT"
fx="$T/w2"; build "$fx"; run_wd "$fx" 5
[ "$(count "$fx/state/log" 'Scarlett present')" = 1 ] && ok "present logged once" || bad "present logged $(count "$fx/state/log" 'Scarlett present') times"
[ "$(count "$fx/state/log" ' ACT ')" = 0 ] && ok "no ACT" || bad "unexpected ACT: $(grep ' ACT ' "$fx/state/log")"

echo "W3 Brave's mic on the Kiyo → moved to Mic 1 (mic-keeper's job)"
fx="$T/w3"; build "$fx"; outputs "$fx" "301 80 Brave"; run_wd "$fx" 1
grep -q "^move-source-output 301 71$" "$fx/actions" && ok "Brave #301 moved to 71" || bad "actions: $(cat "$fx/actions" 2>/dev/null)"
grep -q "ACT move brave mic #301 80 -> 71" "$fx/state/log" && ok "ACT logged with the app" || bad "log: $(grep ACT "$fx/state/log")"

echo "W4 a call app reading a monitor (screen-share audio) is left alone"
fx="$T/w4"; build "$fx"; outputs "$fx" "302 57 Google Chrome"; run_wd "$fx" 1
[ ! -s "$fx/actions" ] && ok "monitor stream not moved" || bad "moved: $(cat "$fx/actions")"

echo "W5 a non-call app (OBS) on another source is left alone; Signal is moved"
fx="$T/w5"; build "$fx"; outputs "$fx" "303 80 OBS" "304 80 ringrtc"; run_wd "$fx" 1
grep -q "^move-source-output 303" "$fx/actions" && bad "OBS moved" || ok "OBS not moved"
grep -q "^move-source-output 304 71$" "$fx/actions" && ok "Signal (ringrtc) moved" || bad "Signal not moved: $(cat "$fx/actions" 2>/dev/null)"

echo "W6 a stream already on Mic 1 is not touched"
fx="$T/w6"; build "$fx"; outputs "$fx" "305 71 Zoom"; run_wd "$fx" 1
[ ! -s "$fx/actions" ] && ok "no move" || bad "moved: $(cat "$fx/actions")"

echo "W7 log above LOG_MAX rotates to log.1 at start"
fx="$T/w7"; build "$fx"; head -c 2000 /dev/zero | tr '\0' 'x' > "$fx/state/log"; LOG_MAX=1000 run_wd "$fx" 1
[ -f "$fx/state/log.1" ] && [ "$(stat -c %s "$fx/state/log.1")" -eq 2000 ] && ok "rotated (log.1 = 2000 bytes)" || bad "not rotated"
[ "$(stat -c %s "$fx/state/log")" -lt 1000 ] && ok "fresh log small" || bad "fresh log $(stat -c %s "$fx/state/log") bytes"

echo "W8 default source flipped + rate unforced → corrected"
fx="$T/w8"; build "$fx"; echo alsa_input.usb-Razer_Inc_Razer_Kiyo_Pro-02.iec958-stereo > "$fx/default_source"; rm "$fx/meta.clock.force-rate"; run_wd "$fx" 1
grep -q "^set-default-source 71$" "$fx/actions" && ok "default source restored" || bad "actions: $(cat "$fx/actions" 2>/dev/null)"
[ "$(cat "$fx/meta.clock.force-rate")" = 48000 ] && ok "force-rate 48000" || bad "force-rate $(cat "$fx/meta.clock.force-rate")"

echo "W9 sustained I/O pressure during a call → logged, never a desktop toast (2026-11-09 false alarm)"
fx="$T/w9"; build "$fx"; outputs "$fx" "305 71 Zoom"
printf 'some avg10=60.00 avg60=60.00 avg300=60.00 total=1\nfull avg10=55.00 avg60=55.00 avg300=55.00 total=1\n' > "$fx/psi"
PSI_IO="$fx/psi" run_wd "$fx" 4
grep -q "IO pressure full=55 during call" "$fx/state/log" && ok "pressure logged" || bad "pressure not logged: $(tail -3 "$fx/state/log")"
grep -q "I/O pressure" "$fx/notify" 2>/dev/null && bad "toasted: $(cat "$fx/notify")" || ok "no toast"

echo; echo "fail=$fail"
[ "$fail" -eq 0 ]
