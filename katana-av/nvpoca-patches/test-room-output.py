#!/usr/bin/env python3
"""Live test for nvpoca --room-output (kiyo-xhci-fix katana-av/nvpoca-patches/0002). Run on katana with nvpoca's venv,
cwd = the patched nvpoca tree. Needs three free v4l2loopbacks: IN (fed here by ffmpeg), OUT, ROOM
(default /dev/video22, /dev/video20, /dev/video21). Never touches the live camera or /dev/video11: a second reader
of a streaming loopback gets EBUSY on S_FMT, so the input is a known clip instead.

Input: 30 frames of ffmpeg testsrc2 (1080p YUYV), looped onto IN at FEED_FPS (30: the worker keeps up;
at 60 a worker running at ~57 fps lags and the 2-buffer input loopback overruns it, tearing INPUT frames);
each frame's md5 is computed from the file.

MODE=normal  every frame read from ROOM is one of the 30 clip frames byte for byte, no frame from OUT is
MODE=fault   the room fd is a pipe whose reader is gone (EPIPE): the room output turns itself off with one log line,
             OUT keeps flowing, and the camera (IN) is opened exactly once (no stop/reopen = no Kiyo wedge)
MODE=stall   a ROOM reader starts and is then frozen (SIGSTOP): OUT keeps its rate (>= 80 % of the feed)
MODE=mjpg    MJPG input (live testsrc2, ffmpeg mjpeg into IN): ROOM is converted from the decoded frame, so it is
             checked for rate and change (>= 80 % of the feed, every frame distinct-ish), not byte equality
All modes: the worker exits 0 and opens the camera once. Exit 0 pass, 1 fail.
usage (cwd = the patched nvpoca tree, nvpoca venv python): test-room-output.py [IN OUT ROOM]; CLIP=path to reuse a clip
"""
import hashlib, json, os, pathlib, signal, subprocess, sys, threading, time

from linuxpy.video.device import BufferType, Device

IN, OUT, ROOM = (sys.argv[1:4] + ["/dev/video22", "/dev/video20", "/dev/video21"][len(sys.argv[1:4]):])
MODE = os.environ.get("MODE", "normal")
W, H, FPS, N = 1920, 1080, 60, 30
FEED = int(os.environ.get("FEED_FPS", "30"))
FRAME = W * H * 2
CLIP = pathlib.Path(os.environ.get("CLIP", "tmp/room-test-clip.yuv"))
black = bytes([16, 128]) * (W * H)
BLACK = hashlib.md5(black).hexdigest()

CLIP.parent.mkdir(parents=True, exist_ok=True)
if not CLIP.exists() or CLIP.stat().st_size != N * FRAME:
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-f", "lavfi", "-i", f"testsrc2=s={W}x{H}:r={FPS}",
                    "-frames:v", str(N), "-pix_fmt", "yuyv422", "-f", "rawvideo", str(CLIP)], check=True)
data = CLIP.read_bytes()
clip_md5 = {hashlib.md5(data[i * FRAME:(i + 1) * FRAME]).hexdigest() for i in range(N)}

FMT = "mjpg" if MODE == "mjpg" else "yuyv"
feeder = subprocess.Popen(
    ["ffmpeg", "-loglevel", "error", "-re", "-f", "lavfi", "-i", f"testsrc2=s={W}x{H}:r={FEED}", "-c:v", "mjpeg",
     "-q:v", "5", "-f", "v4l2", IN] if MODE == "mjpg" else
    ["ffmpeg", "-loglevel", "error", "-re", "-stream_loop", "-1", "-f", "rawvideo", "-pix_fmt", "yuyv422",
     "-s", f"{W}x{H}", "-r", str(FEED), "-i", str(CLIP), "-f", "v4l2", "-pix_fmt", "yuyv422", IN],
    stdin=subprocess.DEVNULL)


def hashes(dev, secs, into):
    p = subprocess.run(["ffmpeg", "-loglevel", "error", "-f", "v4l2", "-framerate", str(FPS), "-i", dev,
                        "-t", str(secs), "-f", "framemd5", "-"], capture_output=True, text=True, timeout=secs + 20)
    into[dev] = [h for h in (ln.rsplit(",", 1)[1].strip() for ln in p.stdout.splitlines()
                             if ln and not ln.startswith("#")) if h != BLACK]


lines, stalled, got = [], None, {}
try:
    time.sleep(2)
    with Device(OUT) as out, Device(ROOM) as room:
        for d in (out, room):
            d.set_format(BufferType.VIDEO_OUTPUT, W, H, "YUYV")
            d.set_fps(BufferType.VIDEO_OUTPUT, FPS)
            os.write(d.fileno(), black)
        room_fd = room.fileno()
        if MODE == "fault":
            r, room_fd = os.pipe()
            os.close(r)   # nobody will ever read: every write gets EPIPE
        w = subprocess.Popen(
            [sys.executable, "-m", "nvpoca.worker", "--input", IN, "--input-format", FMT, "--output", OUT,
             "--room-output", ROOM, "--size", f"{W}x{H}", "--fps", str(FPS), "--variant", "resnet50",
             "--ratio", "0.375", "--mode", "blur", "--out-fd", str(out.fileno()), "--room-fd", str(room_fd)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
            pass_fds=(out.fileno(), room_fd))
        threading.Thread(target=lambda: lines.extend(w.stdout), daemon=True).start()
        w.stdin.write(json.dumps({"settings": {"enabled": True, "mode": "blur", "blur": 16, "smooth": 0.15,
                                               "light": 0, "bg": ""}}) + "\n")
        w.stdin.write(json.dumps({"stream": True}) + "\n")
        w.stdin.flush()
        t0 = time.monotonic()
        while time.monotonic() - t0 < 60 and not any("fps=" in ln for ln in lines):
            time.sleep(0.5)
        if MODE == "stall":
            stalled = subprocess.Popen(["ffmpeg", "-loglevel", "error", "-f", "v4l2", "-i", ROOM, "-f", "null", "-"],
                                       stdin=subprocess.DEVNULL)
            time.sleep(1.5)
            stalled.send_signal(signal.SIGSTOP)
        time.sleep(2)
        devs = (ROOM, OUT) if MODE in ("normal", "mjpg") else (OUT,)
        ts = [threading.Thread(target=hashes, args=(d, 4, got)) for d in devs]
        [t.start() for t in ts]
        [t.join() for t in ts]
        try:
            w.stdin.write(json.dumps({"stream": False}) + "\n")
            w.stdin.close()
        except BrokenPipeError:
            pass   # the worker already died: the verdict below reports it
        w.wait(timeout=30)
finally:
    feeder.kill()
    if stalled:
        stalled.send_signal(signal.SIGCONT)
        stalled.kill()

rm, ef = got.get(ROOM, []), got.get(OUT, [])
opens = sum("camera " in ln and " open," in ln for ln in lines)
disabled = [ln.strip() for ln in lines if "room output disabled" in ln]
fps_lines = [ln.strip() for ln in lines if ln.startswith("fps=")]
print(f"MODE={MODE} feed {FEED} fps · effect frames in 4 s {len(ef)} · camera opens {opens} · worker exit {w.returncode}")
print("worker:", fps_lines[-1] if fps_lines else "(no fps line)")
ok = w.returncode == 0 and opens == 1 and len(ef) >= 0.8 * 4 * FEED and not set(ef) & clip_md5
if MODE == "mjpg":
    ok = ok and not set(ef) & set(got.get(ROOM, []))   # the effect is not the room
if MODE == "normal":
    in_clip = sum(h in clip_md5 for h in rm)
    print(f"room frames that are clip frames byte for byte: {in_clip}/{len(rm)} ({len(set(rm))} distinct)")
    ok = ok and len(rm) >= 0.8 * 4 * FEED and in_clip == len(rm) and len(set(rm)) >= 20 and not disabled
elif MODE == "fault":
    print("room:", disabled[:1] or "(never disabled)")
    ok = ok and len(disabled) == 1
elif MODE == "mjpg":
    print(f"room frames {len(rm)} ({len(set(rm))} distinct) from MJPG input")
    ok = ok and len(rm) >= 0.8 * 4 * FEED and len(set(rm)) >= 0.8 * len(rm) and not disabled
elif MODE == "stall":
    print("room disabled lines:", len(disabled))
    ok = ok and not disabled
print("PASS" if ok else "FAIL")
if not ok:
    print("--- worker log ---")
    print("".join(lines[-25:]))
sys.exit(0 if ok else 1)
