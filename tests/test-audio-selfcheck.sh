#!/bin/bash
# Offline tests for katana-av/audio-selfcheck against a fixture + command shims.
# Each case builds a katana-shaped PASS fixture (Scarlett plugged, 48 kHz, defaults
# on the Scarlett, OBS 720p30, /dev/video9), breaks one layer, and asserts the verdict
# AND the line that names it. Fixtures live under the repo's tmp/ (disk), never /tmp.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
mkdir -p "$ROOT/tmp"
T="$(mktemp -d "$ROOT/tmp/audio-selfcheck-test.XXXXXX")"; trap 'rm -rf "$T"' EXIT
fail=0
ok()  { echo "  [ok]   $1"; }
bad() { echo "  [FAIL] $1"; fail=$((fail+1)); }

SINK=alsa_output.usb-Focusrite_Scarlett_2i2_4th_Gen_S2A4HVU52AA44B-00.HiFi__Line1__sink
SRC=alsa_input.usb-Focusrite_Scarlett_2i2_4th_Gen_S2A4HVU52AA44B-00.HiFi__Mic1__source

# ---------- shims (found first on PATH); each reads the fixture in $FX ----------
SHIM="$T/shim"; mkdir -p "$SHIM"
cat > "$SHIM/pactl" <<'S'
#!/bin/bash
case "$*" in
  "list cards short")    cat "$FX/pactl/cards_short" 2>/dev/null ;;
  "list cards")          cat "$FX/pactl/cards" 2>/dev/null ;;
  "list short sinks")    cat "$FX/pactl/sinks" ;;
  "list short sources")  cat "$FX/pactl/sources" ;;
  "get-default-sink")    cat "$FX/pactl/default_sink" ;;
  "get-default-source")  cat "$FX/pactl/default_source" ;;
  *) exit 1 ;;
esac
S
cat > "$SHIM/pw-metadata" <<'S'
#!/bin/bash
# pw-metadata -n settings 0 <key>
k="${4:-}"; [ -f "$FX/meta/$k" ] || exit 0
echo "Found \"settings\" metadata 32"; echo "update: id:0 key:'$k' value:'$(cat "$FX/meta/$k")' type:''"
S
cat > "$SHIM/pw-top" <<'S'
#!/bin/bash
cat "$FX/pwtop"
S
cat > "$SHIM/pw-record" <<'S'
#!/bin/bash
# last argument is the output file; FX/wav decides what the "mic" delivered
out="${@: -1}"; echo "$*" >> "$FX/pwrecord.args"
case "$(cat "$FX/wav")" in
  empty)  : > "$out" ;;
  unfinalized)   # what pw-record writes when its stdout is not a tty: RIFF size 8, data size 0
          python3 -I -c 'import wave,sys,math,struct;w=wave.open(sys.argv[1],"wb");w.setnchannels(2);w.setsampwidth(2);w.setframerate(48000);w.writeframes(b"".join(struct.pack("<hh",v,v) for v in (int(3277*math.sin(i/7)) for i in range(4800))));w.close()' "$out"
          python3 -I -c 'import sys;f=open(sys.argv[1],"r+b");f.seek(4);f.write(bytes([8,0,0,0]));f.seek(40);f.write(bytes(4))' "$out" ;;
  silent) python3 -I -c 'import wave,sys;w=wave.open(sys.argv[1],"wb");w.setnchannels(2);w.setsampwidth(2);w.setframerate(48000);w.writeframes(b"\0"*4*4800);w.close()' "$out" ;;
  *)      python3 -I -c 'import wave,sys,math,struct;w=wave.open(sys.argv[1],"wb");w.setnchannels(2);w.setsampwidth(2);w.setframerate(48000);w.writeframes(b"".join(struct.pack("<hh",v,v) for v in (int(3277*math.sin(i/7)) for i in range(4800))));w.close()' "$out" ;;
esac
S
cat > "$SHIM/systemctl" <<'S'
#!/bin/bash
scope=system; [ "${1:-}" = "--user" ] && { scope=user; shift; }
verb="$1"; unit="$2"; f="$FX/units/$scope/$unit"
[ -f "$f" ] || { echo inactive; exit 1; }
read -r act en < "$f"
case "$verb" in
  is-active)  echo "$act"; [ "$act" = active ] ;;
  is-enabled) echo "$en";  [ "$en" = enabled ] ;;
  *) exit 1 ;;
esac
S
cat > "$SHIM/modinfo" <<'S'
#!/bin/bash
[ "$1" = "-F" ] && [ "$2" = "srcversion" ] && [ "$3" = "v4l2loopback" ] && { cat "$FX/modinfo_v4l2loopback"; exit 0; }
exit 1
S
cat > "$SHIM/lsusb" <<'S'
#!/bin/bash
cat "$FX/lsusb"
S
cat > "$SHIM/notify-send" <<'S'
#!/bin/bash
echo "notify-send $*" >> "$FX/notify.log"
S
cat > "$SHIM/logger" <<'S'
#!/bin/bash
cat >/dev/null
S
chmod +x "$SHIM"/*

# ---------- fixture builder: katana with the Scarlett, everything PASS ----------
build_fixture() {   # build_fixture <dir>
    local fx="$1"
    mkdir -p "$fx/pactl" "$fx/meta" "$fx/units/user" "$fx/sys/class/video4linux/video9" "$fx/sys/module/v4l2loopback" \
             "$fx/obs/basic/profiles/Kiyo-Call" "$fx/wd" "$fx/run" "$fx/project"
    for u in pipewire pipewire-pulse wireplumber audio-watchdog; do echo "active enabled" > "$fx/units/user/$u"; done
    echo "inactive disabled" > "$fx/units/user/obs-vcam"
    echo 48000 > "$fx/meta/clock.rate"; echo "[ 48000 ]" > "$fx/meta/clock.allowed-rates"; echo 0 > "$fx/meta/clock.force-rate"
    printf '50\talsa_card.pci-0000_00_1f.3\talsa\n61\talsa_card.usb-Focusrite_Scarlett_2i2_4th_Gen_S2A4HVU52AA44B-00\talsa\n' > "$fx/pactl/cards_short"
    cat > "$fx/pactl/cards" <<C
Card #50
	Name: alsa_card.pci-0000_00_1f.3
	Active Profile: output:iec958-stereo+input:analog-stereo
Card #61
	Name: alsa_card.usb-Focusrite_Scarlett_2i2_4th_Gen_S2A4HVU52AA44B-00
	Active Profile: HiFi (Line1, Line2, Mic1, Mic2)
C
    printf '57\talsa_output.pci-0000_00_1f.3.iec958-stereo\tPipeWire\ts32le 2ch 48000Hz\tSUSPENDED\n70\t%s\tPipeWire\ts32le 2ch 48000Hz\tRUNNING\n' "$SINK" > "$fx/pactl/sinks"
    printf '70\t%s.monitor\tPipeWire\ts32le 2ch 48000Hz\tRUNNING\n71\t%s\tPipeWire\ts32le 2ch 48000Hz\tSUSPENDED\n' "$SINK" "$SRC" > "$fx/pactl/sources"
    echo "$SINK" > "$fx/pactl/default_sink"; echo "$SRC" > "$fx/pactl/default_source"
    cat > "$fx/pwtop" <<P
S   ID  QUANT   RATE    WAIT    BUSY   W/Q   B/Q  ERR FORMAT           NAME
R   70   1024  48000  12.0us  20.0us  0.00  0.00    0 S32LE 2 48000    $SINK
S   ID  QUANT   RATE    WAIT    BUSY   W/Q   B/Q  ERR FORMAT           NAME
R   70   1024  48000  12.0us  20.0us  0.00  0.00    0 S32LE 2 48000    $SINK
S   71      0      0    ---     ---   ---   ---     0                  $SRC
P
    echo tone > "$fx/wav"
    echo "Bus 001 Device 008: ID 1235:8219 Focusrite-Novation Scarlett 2i2 4th Gen" > "$fx/lsusb"
    echo "OBS Virtual Camera" > "$fx/sys/class/video4linux/video9/name"
    echo 7B773B9EB594AD896DAD368 > "$fx/sys/module/v4l2loopback/srcversion"; echo 7B773B9EB594AD896DAD368 > "$fx/modinfo_v4l2loopback"
    printf '[General]\nName=Kiyo-Call\n\n[Video]\nBaseCX=1280\nBaseCY=720\nOutputCX=1280\nOutputCY=720\nFPSCommon=30\n' > "$fx/obs/basic/profiles/Kiyo-Call/basic.ini"
    printf '2026-11-08 13:00:00 start interval=2 dry=0\n' > "$fx/wd/log"
}

run_sc() {   # run_sc <fixture> [args]  -> $OUT, $RC
    local fx="$1"; shift
    OUT=$(PATH="$SHIM:$PATH" FX="$fx" AUDIO_SYSFS="$fx/sys" AUDIO_OBS_DIR="$fx/obs" AUDIO_WD_STATE="$fx/wd" \
          AUDIO_RUNTIME="$fx/run" SELFCHECK_HOST=fixturehost KIYO_PROJECT_DIR="$fx/project" \
          "$ROOT/katana-av/audio-selfcheck" "$@" 2>&1); RC=$?
}
expect_rc()   { [ "$RC" -eq "$1" ] && ok "$2 → exit $RC" || { bad "$2 → exit $RC (want $1)"; echo "$OUT" | sed 's/^/        /'; }; }
expect_line() { echo "$OUT" | grep -qE "$1" && ok "line: $1" || { bad "missing line: $1"; echo "$OUT" | sed 's/^/        /'; }; }

echo "A1 all green (Scarlett plugged, 48 kHz, defaults, OBS 720p30, vcam)"
fx="$T/a1"; build_fixture "$fx"; run_sc "$fx"
expect_rc 0 "PASS tree"; expect_line '^RESULT: PASS'; expect_line '^PASS  mic-delivers.*peak -20\.0 dBFS'
expect_line '^PASS  rate\[headphones\].*48000Hz'; expect_line '^PASS  obs-profile.*1280x720 @ 30'; expect_line '^PASS  v4l2loopback'
[ -z "$(ls -A "$fx/run")" ] && ok "probe file cleaned up" || bad "probe file left in runtime dir"
grep -q -- "--target $SRC" "$fx/pwrecord.args" && ok "probe reads Mic1 by name" || bad "probe target wrong: $(cat "$fx/pwrecord.args")"

echo "A2 Scarlett not on this host → WARN, device checks skipped, still PASS"
fx="$T/a2"; build_fixture "$fx"; sed -i '/Scarlett/d' "$fx/pactl/cards_short"; : > "$fx/lsusb"; run_sc "$fx"
expect_rc 0 "absent"; expect_line '^WARN  scarlett-present.*not plugged into fixturehost'
echo "$OUT" | grep -q 'mic-delivers' && bad "probe ran without a Scarlett" || ok "no probe without a Scarlett"

echo "A3 Scarlett on USB but no card (snd-usb-audio / WirePlumber lost it)"
fx="$T/a3"; build_fixture "$fx"; sed -i '/Scarlett/d' "$fx/pactl/cards_short"; run_sc "$fx"
expect_rc 1 "usb no card"; expect_line '^FAIL  scarlett-present.*on USB \(1235:8219'

echo "A4 the 10-31 chop: Scarlett at 44.1 kHz"
fx="$T/a4"; build_fixture "$fx"; sed -i "s/^\(70\t$SINK\t.*\)48000Hz/\144100Hz/" "$fx/pactl/sinks"; run_sc "$fx"
expect_rc 1 "44.1k"; expect_line '^FAIL  rate\[headphones\].*44100Hz'

echo "A5 default source flipped to the S/PDIF monitor"
fx="$T/a5"; build_fixture "$fx"; echo alsa_output.pci-0000_00_1f.3.iec958-stereo.monitor > "$fx/pactl/default_source"; run_sc "$fx"
expect_rc 1 "default flip"; expect_line '^FAIL  mic .*iec958-stereo.monitor, not Scarlett Mic1'

echo "A6 wrong profile"
fx="$T/a6"; build_fixture "$fx"; sed -i 's/Active Profile: HiFi.*/Active Profile: off/' "$fx/pactl/cards"; run_sc "$fx"
expect_rc 1 "profile"; expect_line "^FAIL  scarlett-profile.*'off'"

echo "A7 Mic 1 open but delivering nothing (the 10-31 stall)"
fx="$T/a7"; build_fixture "$fx"; echo empty > "$fx/wav"; run_sc "$fx"
expect_rc 1 "stall"; expect_line '^FAIL  mic-delivers.*returned 0 bytes'

echo "A7a WAV header left unfinalized (pw-record, stdout not a tty) → samples still counted"
fx="$T/a7a"; build_fixture "$fx"; echo unfinalized > "$fx/wav"; run_sc "$fx"
expect_rc 0 "unfinalized header"; expect_line '^PASS  mic-delivers.*peak -20\.0 dBFS'

echo "A7b Mic 1 digital silence → WARN (gain knob), not FAIL"
fx="$T/a7b"; build_fixture "$fx"; echo silent > "$fx/wav"; run_sc "$fx"
expect_rc 0 "silence"; expect_line '^WARN  mic-delivers.*digital silence'

echo "A7c --no-probe never opens the mic"
fx="$T/a7c"; build_fixture "$fx"; run_sc "$fx" --no-probe
expect_rc 0 "no-probe"; [ -e "$fx/pwrecord.args" ] && bad "pw-record ran with --no-probe" || ok "pw-record not called"

echo "A8 clock forced to 44.1 kHz / allowed-rates widened"
fx="$T/a8"; build_fixture "$fx"; echo 44100 > "$fx/meta/clock.force-rate"; run_sc "$fx"
expect_rc 1 "force-rate"; expect_line '^FAIL  clock.*force-rate=44100'
fx="$T/a8b"; build_fixture "$fx"; echo "[ 44100 48000 ]" > "$fx/meta/clock.allowed-rates"; run_sc "$fx"
expect_rc 0 "allowed widened"; expect_line '^WARN  clock.*allowed-rates=\[ 44100 48000 \]'

echo "A9 xruns on the Scarlett nodes → WARN"
fx="$T/a9"; build_fixture "$fx"; sed -i '$ s/    0                  /    7                  /' "$fx/pwtop"; run_sc "$fx"
expect_rc 0 "xruns"; expect_line '^WARN  xruns.*ERR=7'

echo "A10 audio-watchdog inactive"
fx="$T/a10"; build_fixture "$fx"; echo "failed enabled" > "$fx/units/user/audio-watchdog"; run_sc "$fx"
expect_rc 1 "watchdog down"; expect_line '^FAIL  unit\[audio-watchdog\].*failed, enabled'

echo "A11 OBS profile drifted to 1080p60, and missing"
fx="$T/a11"; build_fixture "$fx"; sed -i 's/OutputCX=1280/OutputCX=1920/; s/OutputCY=720/OutputCY=1080/; s/FPSCommon=30/FPSCommon=60/' "$fx/obs/basic/profiles/Kiyo-Call/basic.ini"; run_sc "$fx"
expect_rc 1 "obs 1080p60"; expect_line '^FAIL  obs-profile.*1920x1080 @ 60'
fx="$T/a11b"; build_fixture "$fx"; rm -r "$fx/obs/basic/profiles/Kiyo-Call"; run_sc "$fx"
expect_rc 1 "obs missing"; expect_line '^FAIL  obs-profile.*missing'

echo "A12 virtual camera: wrong node, stale module"
fx="$T/a12"; build_fixture "$fx"; echo scrcpy > "$fx/sys/class/video4linux/video9/name"; run_sc "$fx"
expect_rc 1 "vcam label"; expect_line "^FAIL  vcam-node.*'scrcpy'"
fx="$T/a12b"; build_fixture "$fx"; echo OLDSRCVERSION > "$fx/sys/module/v4l2loopback/srcversion"; run_sc "$fx"
expect_rc 1 "stale v4l2loopback"; expect_line '^FAIL  v4l2loopback.*OLDSRCVERSION != on disk 7B773B9E'

echo "A13 watchdog log over 20 MB → WARN"
fx="$T/a13"; build_fixture "$fx"; truncate -s 25M "$fx/wd/log"; run_sc "$fx" --no-probe
expect_rc 0 "big log"; expect_line '^WARN  watchdog-log.*25 MB'

echo "A14 --log: history, FAIL file, one notification per changed FAIL set"
fx="$T/a14"; build_fixture "$fx"; echo empty > "$fx/wav"; run_sc "$fx" --log
expect_rc 1 "--log FAIL"
L="$fx/project/scratch/selfcheck"
grep -q 'RESULT: FAIL' "$L/fixturehost-audio.log" 2>/dev/null && ok "history line" || bad "history line missing"
[ -f "$L/fixturehost-audio-last.txt" ] && ok "last.txt" || bad "last.txt missing"
ls "$L"/FAIL-fixturehost-audio-*.txt >/dev/null 2>&1 && ok "FAIL file" || bad "FAIL file missing"
run_sc "$fx" --log
[ "$(grep -c '^notify-send' "$fx/notify.log" 2>/dev/null)" = "1" ] && ok "unchanged FAIL set notified once" || bad "notify count $(grep -c '^notify-send' "$fx/notify.log" 2>/dev/null)"
echo alsa_output.pci-0000_00_1f.3.iec958-stereo > "$fx/pactl/default_sink"; run_sc "$fx" --log
[ "$(grep -c '^notify-send' "$fx/notify.log" 2>/dev/null)" = "2" ] && ok "changed FAIL set notifies again" || bad "changed set not notified"
fx="$T/a14b"; build_fixture "$fx"; run_sc "$fx" --log
expect_rc 0 "--log PASS"; [ -e "$fx/notify.log" ] && bad "notified on PASS" || ok "no notification on PASS"

echo "A15 usage"
run_sc "$T/a1" --bogus; expect_rc 2 "bad flag"

echo; echo "fail=$fail"
[ "$fail" -eq 0 ]
