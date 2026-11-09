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
import importlib.machinery, importlib.util, sys, json
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
# --login / --admit / signal cleanup (2026-11-09)
check("--login and --admit are options", '"--login", metavar="VAULT_ITEM"' in src and '"--admit", metavar="NAME"' in src)
check("ADMIT takes the name as a JSON literal and approves via lobbyApproveAccess", "lobbyApproveAccess" in m.ADMIT and 'ADMIT + "(" + json.dumps(a.admit) + ")"' in src)
check("credentials are SET on the element handle as a call argument, never typed, never JS source", "Runtime.callFunctionOn" in src and '{"value": text}' in src and "Input.insertText" not in src and "json.dumps(text)" not in src)
check("one synchronous task checks origin, dialog and field kind before setting", all(k in m.SET_VALUE for k in ("origins.includes(location.origin)", "closest(", "wrong-field", ".set.call(this, v)")) and m.SET_VALUE.index("origins.includes") < m.SET_VALUE.index(".set.call(this, v)"))
check("credentials only for allowlisted origins: checked before the vault read and atomically at set time", m.LOGIN_ORIGINS == {"https://meet.realm.watch"} and src.index("not in LOGIN_ORIGINS") < src.index("u, p = await vault_login(item)") and '{"value": sorted(LOGIN_ORIGINS)}' in src)
check("a dead handle (navigation) aborts instead of retrying elsewhere", "handle-gone" in src and 'if st != "ok":' in src)
check("page-derived values reach output only as fixed codes", m.code("role", "moderator (isModerator)") == "moderator" and m.code("role", "S3cr3t") == "other" and m.code("hd", "hd JP S3cr3t") == "hd-on" and m.code("admit", "admitted S3cr3t") == "admit-other" and 'code("role", await c.evaluate(ROLE))' in src)
check("login runs omit page text from every output line", src.count('"[omitted: login run]" if a.login') == 2)
check("an empty --admit prefix is refused", "--admit needs a non-empty name prefix" in src)
check("signals are neutralised during cleanup and cancellation happens once", "loop.add_signal_handler(sig, lambda: None)" in src and "if not stopping:" in src)
check("SIGTERM/SIGHUP/SIGINT cancel the main task so finally cleans up", "loop.add_signal_handler(sig, on_signal)" in src and "me.cancel()" in src and "signal.SIGTERM, signal.SIGHUP" in src)
check("candidate pair records local/remote candidate types", "candidateType" in m.STATS and "relayProtocol" in m.STATS)
import os, subprocess, tempfile, io, contextlib
d = tempfile.mkdtemp()
open(os.path.join(d, "bw"), "w").write('#!/bin/sh\n[ "$2" = username ] && echo jp-fake-user || echo "S3cr3t-fake-pw"\n')
os.chmod(os.path.join(d, "bw"), 0o755)
old = os.environ["PATH"]; os.environ["PATH"] = d + ":" + old
buf = io.StringIO()
with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(buf):
    import asyncio as _a
    u, pw = _a.run(m.vault_login("any item"))
os.environ["PATH"] = old
check("vault_login reads username and password from bw", (u, pw) == ("jp-fake-user", "S3cr3t-fake-pw"))
check("vault_login prints nothing (no credential on stdout/stderr)", "S3cr3t" not in buf.getvalue() and buf.getvalue() == "")
open(os.path.join(d, "bw"), "w").write("#!/bin/sh\nexit 1\n")
os.environ["PATH"] = d + ":" + old
try:
    _a.run(m.vault_login("missing")); check("vault_login refuses an empty credential", False)
except SystemExit as e:
    check("a failing bw exits with a fixed message (no subprocess output)", str(e) == "call-probe: `bw get` failed (vault locked or item missing)")
os.environ["PATH"] = old
hostile = {"pcs": 1, "secret": "S3cr3t", "video": [{"w": 1920, "h": 1080, "fps": "S3cr3t", "codec": "S3cr3t", "extra": "S3cr3t"}],
           "audio": [{"lost": 0, "rx": 10, "note": "S3cr3t"}], "pair": {"rtt": 0.1, "local": "relay", "remote": "S3cr3t", "relay_proto": "tcp"}, "text": "S3cr3t"}
cs = m.clean_stats(hostile)
check("clean_stats drops unknown keys and non-numeric metrics (page realm is untrusted)", "S3cr3t" not in json.dumps(cs) and cs["video"][0]["w"] == 1920 and cs["video"][0]["fps"] is None)
check("candidate types are enumerated (relay kept, unknown dropped)", cs["pair"]["local"] == "relay" and cs["pair"]["remote"] is None and cs["pair"]["relay_proto"] == "tcp")
check("admit codes: bounded counts only", m.code("admit", "admitted 123456") == "admit-other" and m.code("admit", "admitted 1") == "admitted 1" and m.code("admit", "3 knocking") == "3 knocking")
check("admit counts: ASCII 1-2 digits, rebuilt from the integer", m.code("admit", "admitted " + "0" * 40 + "1") == "admit-other" and m.code("admit", "admitted \u0661") == "admit-other" and m.code("admit", "admitted 07") == "admitted 7" and m.code("admit", "admitted") == "admitted")
bad_ok = True
for junk in ({"video": 1}, {"audio": "x"}, {"pair": {"local": []}}, {"pair": {"local": {}}}, [], "s", 5, None):
    try: m.clean_stats(junk)
    except Exception: bad_ok = False
check("clean_stats survives malformed page values (wrong container / enum types)", bad_ok)
check("every sample is rebuilt by clean_stats, the page object is never serialized", "s = clean_stats(raw)" in src and "first = clean_stats(first_raw)" in src)
check("empty series summarises without error", m.summarise([]) == {"samples": 0, "with_video": 0, "with_audio": 0})
print(); print(f"fail={fail}"); sys.exit(1 if fail else 0)
PY
