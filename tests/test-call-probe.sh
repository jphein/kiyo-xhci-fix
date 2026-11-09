#!/bin/bash
# Offline test for katana-av/call-probe's summary (no browser, no network): a stats series in
# the shape the page returns must summarise to the call's resolution, fps, freezes, packet loss
# and the share of audio the receiver had to conceal (what the far end hears as glitches).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
GATE="$HOME/Projects/realmwatch/plugins/gui-sweep/gui_sweep.py"
[ -f "$GATE" ] || { echo "  [skip] realmwatch gui_sweep.py not on this host (call-probe imports its SocksGate)"; exit 0; }
python3 -I - "$ROOT/katana-av/call-probe" <<'PY'
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("call_probe", sys.argv[1])
spec = importlib.util.spec_from_loader("call_probe", loader); m = importlib.util.module_from_spec(spec); loader.exec_module(m)
fail = 0
def check(label, cond):
    global fail
    print(("  [ok]   " if cond else "  [FAIL] ") + label); fail += 0 if cond else 1
v = lambda w, h, fps, fr, lost: {"w": w, "h": h, "fps": fps, "freezes": fr, "freeze_s": fr * 0.5, "dropped": 2, "lost": lost, "rx": 5000}
a = lambda conc, smp, lost: {"lost": lost, "rx": 3000, "concealed": conc, "samples": smp, "concealment_events": 3, "jitter": 0.012}
samples = [{"video": [v(1280, 720, 29.0, 0, 0)], "audio": [a(0, 48000, 0)]},
           {"video": [v(1920, 1080, 30.0, 1, 4)], "audio": [a(960, 480000, 2)]},
           {"video": [], "audio": []}]
s = m.summarise(samples)
check("3 samples, 2 with video", s["samples"] == 3 and s["with_video"] == 2)
check("last resolution 1920x1080, both seen", s["video"]["res_last"] == "1920x1080" and s["video"]["res_seen"] == ["1280x720", "1920x1080"])
check("fps min 29 avg 29.5", s["video"]["fps_min"] == 29.0 and s["video"]["fps_avg"] == 29.5)
check("freezes and loss from the last sample", s["video"]["freezes"] == 1 and s["video"]["lost"] == 4)
check("audio concealed 0.2 %", s["audio"]["concealed_pct"] == 0.2)
check("audio jitter 12 ms", s["audio"]["jitter_ms_last"] == 12.0)
for h in ("localhost", "10.0.6.1", "100.100.100.100", "169.254.1.1", "fd00::1", "::ffff:127.0.0.1"):
    check(f"public_only refuses {h}", m.public_only(h, 443) == ["127.0.0.1"])
check("public_only passes a public literal", m.public_only("1.1.1.1", 443) == ["1.1.1.1"])
import argparse, json as _j
src = open(sys.argv[1]).read()
check("--hd defaults to JP, takes a name, absent = off", '"--hd", nargs="?", const="JP", default=None' in src)
check("--hd re-applied every sample (inside the sample loop)", "if a.hd:\n                    hd_state = await c.evaluate(HD" in src)
check("HD sets tile view off, pins, prefers 1080, and sets receiver constraints", all(k in m.HD for k in ("SET_TILE_VIEW", "PIN_PARTICIPANT", "SET_PREFERRED_VIDEO_QUALITY", "setReceiverConstraints", "onStageSources")))
evil = 'JP"); fetch("http://127.0.0.1:8085/"); ("'
call = m.HD + "(" + _j.dumps(evil) + ")"
check("target name enters the page as one JSON string literal", call.endswith("(" + _j.dumps(evil) + ")") and _j.loads(call[len(m.HD) + 1:-1]) == evil)
check("every sample is stamped with a probe id", 's["probe"] = probe_id' in src)
check("empty series summarises without error", m.summarise([]) == {"samples": 0, "with_video": 0, "with_audio": 0})
print(); print(f"fail={fail}"); sys.exit(1 if fail else 0)
PY
