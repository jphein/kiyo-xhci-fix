"""Control for test-room-output.py: ffmpeg writes the clip into a loopback, ffmpeg reads md5s back, no nvpoca.
Torn frames here mean the loopback (writer overrunning a reader), not nvpoca."""
import hashlib, subprocess, sys, time

DEV = sys.argv[1] if len(sys.argv) > 1 else "/dev/video22"
W, H, N = 1920, 1080, 30
F = W * H * 2
d = open("tmp/room-test-clip.yuv", "rb").read()
clip = {hashlib.md5(d[i * F:(i + 1) * F]).hexdigest() for i in range(N)}
for run in range(3):
    f = subprocess.Popen(["ffmpeg", "-loglevel", "error", "-re", "-stream_loop", "-1", "-f", "rawvideo",
                          "-pix_fmt", "yuyv422", "-s", f"{W}x{H}", "-r", "60", "-i", "tmp/room-test-clip.yuv",
                          "-f", "v4l2", "-pix_fmt", "yuyv422", DEV], stdin=subprocess.DEVNULL)
    try:
        time.sleep(2)
        p = subprocess.run(["ffmpeg", "-loglevel", "error", "-f", "v4l2", "-framerate", "60", "-i", DEV, "-t", "4", "-f", "framemd5", "-"],
                           capture_output=True, text=True, timeout=30)
    finally:
        f.kill()   # never leave the infinite feeder holding the loopback
        f.wait()
    h = [ln.rsplit(",", 1)[1].strip() for ln in p.stdout.splitlines() if ln and not ln.startswith("#")]
    print(f"control (no nvpoca) {DEV}: {sum(x in clip for x in h)}/{len(h)} frames are clip frames")
