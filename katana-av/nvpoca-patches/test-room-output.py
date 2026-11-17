#!/usr/bin/env python3
"""Live test for nvpoca --room-output (kiyo-xhci-fix katana-av/nvpoca-patches/0002). Run on katana with nvpoca's venv,
cwd = the patched nvpoca tree. Needs three free v4l2loopbacks: IN (fed here by ffmpeg), OUT, ROOM
(default /dev/video22, /dev/video20, /dev/video21). Never touches the live camera or /dev/video11: a second reader
of a streaming loopback gets EBUSY on S_FMT, so the input is a known clip instead.

Input: 30 frames of ffmpeg testsrc2 (1080p YUYV), looped onto IN at FEED_FPS (30: the worker keeps up;
at 60 a worker running at ~57 fps lags and the 2-buffer input loopback overruns it, tearing INPUT frames); each frame's md5 is computed from the file.
Proof: every frame read from ROOM is one of those 30 (byte for byte: the room is the input, untouched), and no frame
from OUT is (mode blur 16 changes every frame). Exit 0 pass, 1 fail.
"""
import hashlib, json, os, pathlib, subprocess, sys, threading, time

from linuxpy.video.device import BufferType, Device

# usage (cwd = the patched nvpoca tree, nvpoca venv python): test-room-output.py [IN OUT ROOM]; CLIP=path to reuse a clip
IN, OUT, ROOM = (sys.argv[1:4] + ["/dev/video22", "/dev/video20", "/dev/video21"][len(sys.argv[1:4]):])
W, H, FPS, N = 1920, 1080, 60, 30
FRAME = W * H * 2
CLIP = pathlib.Path(os.environ.get("CLIP", "tmp/room-test-clip.yuv"))
black = bytes([16, 128]) * (W * H)

CLIP.parent.mkdir(parents=True, exist_ok=True)
if not CLIP.exists() or CLIP.stat().st_size != N * FRAME:
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-f", "lavfi", "-i", f"testsrc2=s={W}x{H}:r={FPS}",
                    "-frames:v", str(N), "-pix_fmt", "yuyv422", "-f", "rawvideo", str(CLIP)], check=True)
data = CLIP.read_bytes()
clip_md5 = {hashlib.md5(data[i * FRAME:(i + 1) * FRAME]).hexdigest() for i in range(N)}

feeder = subprocess.Popen(["ffmpeg", "-loglevel", "error", "-re", "-stream_loop", "-1", "-f", "rawvideo",
                           "-pix_fmt", "yuyv422", "-s", f"{W}x{H}", "-r", os.environ.get("FEED_FPS", "30"), "-i", str(CLIP),
                           "-f", "v4l2", "-pix_fmt", "yuyv422", IN], stdin=subprocess.DEVNULL)


def hashes(dev, secs, into):
    p = subprocess.run(["ffmpeg", "-loglevel", "error", "-f", "v4l2", "-i", dev, "-t", str(secs), "-f", "framemd5", "-"],
                       capture_output=True, text=True, timeout=secs + 20)
    into[dev] = [ln.rsplit(",", 1)[1].strip() for ln in p.stdout.splitlines() if ln and not ln.startswith("#")]


lines = []
try:
    time.sleep(2)
    with Device(OUT) as out, Device(ROOM) as room:
        for d in (out, room):
            d.set_format(BufferType.VIDEO_OUTPUT, W, H, "YUYV")
            d.set_fps(BufferType.VIDEO_OUTPUT, FPS)
            os.write(d.fileno(), black)
        w = subprocess.Popen(
            [sys.executable, "-m", "nvpoca.worker", "--input", IN, "--input-format", "yuyv", "--output", OUT,
             "--room-output", ROOM, "--size", f"{W}x{H}", "--fps", str(FPS), "--variant", "resnet50",
             "--ratio", "0.375", "--mode", "blur", "--out-fd", str(out.fileno()), "--room-fd", str(room.fileno())],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
            pass_fds=(out.fileno(), room.fileno()))
        threading.Thread(target=lambda: lines.extend(w.stdout), daemon=True).start()
        w.stdin.write(json.dumps({"settings": {"enabled": True, "mode": "blur", "blur": 16, "smooth": 0.15,
                                               "light": 0, "bg": ""}}) + "\n")
        w.stdin.write(json.dumps({"stream": True}) + "\n")
        w.stdin.flush()
        t0 = time.monotonic()
        while time.monotonic() - t0 < 60 and not any("fps=" in ln for ln in lines):
            time.sleep(0.5)
        time.sleep(2)
        got = {}
        ts = [threading.Thread(target=hashes, args=(d, 4, got)) for d in (ROOM, OUT)]
        [t.start() for t in ts]
        [t.join() for t in ts]
        w.stdin.write(json.dumps({"stream": False}) + "\n")
        w.stdin.close()
        w.wait(timeout=30)
finally:
    feeder.kill()

BLACK = hashlib.md5(black).hexdigest()   # the frame written up front, before the first worker frame
rm, ef = [h for h in got.get(ROOM, []) if h != BLACK], [h for h in got.get(OUT, []) if h != BLACK]
print(f"black frames dropped: room {got.get(ROOM, []).count(BLACK)}, effect {got.get(OUT, []).count(BLACK)}")
fps_lines = [ln.strip() for ln in lines if "fps=" in ln]
in_clip = sum(h in clip_md5 for h in rm)
print(f"frames read in 4 s: room {len(rm)} ({len(set(rm))} distinct), effect {len(ef)} ({len(set(ef))} distinct)")
print(f"room frames that are clip frames byte for byte: {in_clip}/{len(rm)} · effect frames that are: "
      f"{sum(h in clip_md5 for h in ef)}/{len(ef)}")
print("worker:", fps_lines[-1] if fps_lines else "(no fps line)", "| exit", w.returncode)
ok = len(rm) >= 60 and in_clip == len(rm) and len(set(rm)) >= 20 and len(ef) >= 60 and not set(ef) & clip_md5
print("PASS" if ok else "FAIL")
if not ok:
    print("--- worker log ---")
    print("".join(lines[-25:]))
sys.exit(0 if ok else 1)
