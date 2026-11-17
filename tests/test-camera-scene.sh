#!/bin/bash
# Offline tests for katana-av/camera-scene (against tests/fixtures/obsws_fake, an in-memory OBS), camera-up's --scene
# argument handling, and kando-camera-menu's scene buttons. Pins: build makes Room < Brand < Kiyo Pro (bottom->top),
# copies the person's transform from "Kiyo" onto room AND person (they must line up), never changes the program scene,
# keeps a tuned opacity and an existing brand.png on a rebuild; brand/plain switch the program scene; exits 2/3.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
mkdir -p "$ROOT/tmp"
T="$(mktemp -d "$ROOT/tmp/camera-scene-test.XXXXXX")"; trap 'rm -rf "$T"' EXIT
fail=0
ok()  { echo "  [ok]   $1"; }
bad() { echo "  [FAIL] $1"; fail=$((fail+1)); }
export OBS_FAKE_STATE="$T/obs.json" BRAND_FILE="$T/brand.png" HOME="$T/home"
mkdir -p "$HOME/.config/obs-studio/plugin_config/obs-websocket"
echo '{"server_port": 4455, "server_password": "x"}' > "$HOME/.config/obs-studio/plugin_config/obs-websocket/config.json"
cs() { PYTHONPATH="$HERE/fixtures/obsws_fake" python3 "$ROOT/katana-av/camera-scene" "$@" 2>&1; }
# q: eval of an expression written in THIS file (never external input) over the fake OBS state
q()  { python3 -c "import json,sys; s=json.load(open('$OBS_FAKE_STATE')); print(eval(sys.argv[1]))" "$1"; }
cat > "$OBS_FAKE_STATE" <<'EOF'
{"canvas": [1920, 1080], "program": "Kiyo", "calls": [],
 "inputs": {"Kiyo Pro": {"kind": "v4l2_input", "settings": {"device_id": "/dev/video11", "pixelformat": 1448695129},
                         "filters": {"Chroma Key": {"settings": {}}}},
            "Image": {"kind": "image_source", "settings": {"file": "x.jpg"}, "filters": {}}},
 "scenes": {"Kiyo": [{"id": 1, "source": "Image", "transform": {}},
                     {"id": 2, "source": "Kiyo Pro", "transform": {"positionX": -192.0, "positionY": -121.0,
                      "scaleX": 1.112, "scaleY": 1.112, "boundsType": "OBS_BOUNDS_NONE", "boundsWidth": 0.0,
                      "boundsHeight": 0.0, "width": 2135.0, "height": 1201.0, "sourceWidth": 1920.0,
                      "sourceHeight": 1080.0}}]}}
EOF
echo stand-in > "$BRAND_FILE"

echo "S1 build: scene made bottom->top Room, Brand, Kiyo Pro; program scene untouched"
OUT=$(cs build); RC=$?
[ "$RC" = 0 ] && ok "exit 0" || bad "exit $RC: $OUT"
[ "$(q '[i["source"] for i in s["scenes"]["Brand over room"]]')" = "['Room (raw camera)', 'Brand', 'Kiyo Pro']" ] \
    && ok "order" || bad "order $(q 's["scenes"].get("Brand over room")')"
[ "$(q 's["program"]')" = Kiyo ] && ! q '"set_current_program_scene" in s["calls"]' | grep -q True \
    && ok "program scene untouched" || bad "program $(q 's["program"]')"

echo "S2 room and person both carry the person's transform from Kiyo (read-only fields and zero bounds dropped)"
t_room=$(q '[i["transform"] for i in s["scenes"]["Brand over room"] if i["source"]=="Room (raw camera)"][0]')
t_per=$(q '[i["transform"] for i in s["scenes"]["Brand over room"] if i["source"]=="Kiyo Pro"][0]')
[ "$t_room" = "$t_per" ] && echo "$t_room" | grep -q "'positionX': -192.0" && echo "$t_room" | grep -q "'scaleX': 1.112" \
    && ok "aligned: $t_room" || bad "room $t_room / person $t_per"

echo "S3 room source = the person's v4l2 settings with device /dev/video12; brand file + opacity 0.55; brand stretched"
[ "$(q 's["inputs"]["Room (raw camera)"]["settings"]')" = "{'device_id': '/dev/video12', 'pixelformat': 1448695129}" ] \
    && ok "room settings" || bad "$(q 's["inputs"]["Room (raw camera)"]')"
[ "$(q 's["inputs"]["Brand"]["filters"]["Opacity"]')" = "{'kind': 'color_filter_v2', 'settings': {'opacity': 0.55}}" ] \
    && ok "opacity filter 0.55" || bad "$(q 's["inputs"]["Brand"]')"
q '[i["transform"] for i in s["scenes"]["Brand over room"] if i["source"]=="Brand"][0]' | grep -q "'boundsType': 'OBS_BOUNDS_STRETCH', 'boundsWidth': 1920, 'boundsHeight': 1080" \
    && ok "brand fills 1920x1080" || bad "brand transform"
[ "$(cat "$BRAND_FILE")" = stand-in ] && ok "existing brand.png kept" || bad "brand.png overwritten"

echo "S4 rebuild after JP tuned the opacity to 0.7: keeps 0.7, makes nothing new, order unchanged"
python3 -c "import json; p='$OBS_FAKE_STATE'; s=json.load(open(p)); s['inputs']['Brand']['filters']['Opacity']['settings']['opacity']=0.7; json.dump(s,open(p,'w'))"
OUT=$(cs build); RC=$?
[ "$RC" = 0 ] && echo "$OUT" | grep -q "made nothing new" && ok "idempotent" || bad "exit $RC: $OUT"
[ "$(q 's["inputs"]["Brand"]["filters"]["Opacity"]["settings"]["opacity"]')" = 0.7 ] && ok "tuned opacity kept" || bad "opacity reset"
[ "$(q 'len(s["scenes"]["Brand over room"])')" = 3 ] && ok "no duplicate items" || bad "items $(q 'len(s["scenes"]["Brand over room"])')"

echo "S5 brand / plain switch the program scene and say so; status reads opacity"
OUT=$(cs brand); [ $? = 0 ] && [ "$(q 's["program"]')" = "Brand over room" ] && echo "$OUT" | grep -q "program scene 'Brand over room'" \
    && ok "brand" || bad "brand: $OUT"
OUT=$(cs plain); [ $? = 0 ] && [ "$(q 's["program"]')" = Kiyo ] && ok "plain" || bad "plain: $OUT"
OUT=$(cs status); echo "$OUT" | grep -q "brand opacity 0.70" && ok "status: $OUT" || bad "status: $OUT"

echo "S6 usage -> 2; OBS down -> 3"
cs bogus >/dev/null; [ $? = 2 ] && ok "usage 2" || bad "usage"
python3 -c "import json; p='$OBS_FAKE_STATE'; s=json.load(open(p)); s['down']=True; json.dump(s,open(p,'w'))"
OUT=$(cs status); [ $? = 3 ] && echo "$OUT" | grep -q "OBS not answering" && ok "down 3" || bad "down: $OUT"

echo "S7 camera-up argument handling (nothing runs on a usage error)"
for args in "--scene" "--scene fancy" "--bogus"; do
    OUT=$(bash "$ROOT/katana-av/camera-up" $args 2>&1); RC=$?
    [ "$RC" = 2 ] && echo "$OUT" | grep -q "usage: camera-up" && ok "'$args' -> 2" || bad "'$args' -> $RC: $OUT"
done

OUT=$(bash "$ROOT/katana-av/camera-up" --scene "" 2>&1); RC=$?
[ "$RC" = 2 ] && ok "--scene \"\" -> 2 (an empty value is not \"no scene\")" || bad "empty scene -> $RC: $OUT"

echo "S8 kando-camera-menu: Camera submenu gets the two scene buttons, other menus untouched"
echo '{"menus": [{"root": {"name": "Main", "children": [{"type": "button", "name": "Other"}]}}]}' > "$T/menus.json"
KANDO_MENUS="$T/menus.json" python3 "$ROOT/katana-av/kando-camera-menu" >/dev/null || bad "kando run"
names=$(python3 -c "import json; m=json.load(open('$T/menus.json')); r=m['menus'][0]['root']['children']; print([c['name'] for c in r], [c['name'] for c in r[1]['children']])")
[ "$names" = "['Other', 'Camera'] ['60 fps (no HDR)', 'HDR (30 fps)', 'Which mode?', 'Brand over room', 'Plain background']" ] \
    && ok "buttons" || bad "$names"
grep -q "camera-scene brand 2>&1" "$T/menus.json" && grep -q "camera-scene plain 2>&1" "$T/menus.json" \
    && ok "buttons run camera-scene brand|plain" || bad "commands"

echo "S9 a missing obs-websocket config is 'OBS not answering' (exit 3), not a traceback"
mv "$HOME/.config/obs-studio/plugin_config/obs-websocket/config.json" "$T/ws.json"
OUT=$(cs status); RC=$?
[ "$RC" = 3 ] && echo "$OUT" | grep -q "OBS not answering" && ! echo "$OUT" | grep -q Traceback && ok "exit 3" || bad "exit $RC: $OUT"
mv "$T/ws.json" "$HOME/.config/obs-studio/plugin_config/obs-websocket/config.json"

echo "S10 first build with no brand.png writes a placeholder PNG (real ffmpeg) and still builds"
python3 -c "import json; p='$OBS_FAKE_STATE'; s=json.load(open(p)); s['down']=False; s['scenes'].pop('Brand over room'); [s['inputs'].pop(k) for k in ('Room (raw camera)','Brand')]; json.dump(s,open(p,'w'))"
rm -f "$BRAND_FILE"
OUT=$(cs build); RC=$?
[ "$RC" = 0 ] && echo "$OUT" | grep -q "placeholder brand.png" && ok "built with placeholder" || bad "exit $RC: $OUT"
[ "$(head -c 8 "$BRAND_FILE" | od -An -tx1 | tr -d ' ')" = 89504e470d0a1a0a ] && ok "brand.png is a PNG" || bad "not a PNG"

[ "$fail" = 0 ] && echo "ok: camera-scene tests pass" || echo "FAILED: $fail"
exit "$fail"
