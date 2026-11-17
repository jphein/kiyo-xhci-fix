#!/usr/bin/env python3
"""Offline-ish test of nvpoca's supervisor open_room() (kiyo-xhci-fix nvpoca-patches/0002). Run with nvpoca's venv,
cwd = the patched nvpoca tree; optional argv[1] = a free v4l2loopback for the positive case (default /dev/video21).
Pins: a missing device and a non-video device (/dev/null: ENOTTY on the first ioctl) both return None with one
"continuing without it" line and never raise; a real loopback returns an open Device whose fd is NON-BLOCKING before
its first write. Exit 0 pass, 1 fail."""
import contextlib, io, os, sys, types

from nvpoca.__main__ import open_room

LOOP = sys.argv[1] if len(sys.argv) > 1 else "/dev/video21"
black = bytes([16, 128]) * 4
fail = 0


def check(name, cond, info=""):
    global fail
    print(f"  [{'ok' if cond else 'FAIL'}]   {name} {info}")
    fail += not cond


for dev in ("/dev/video99", "/dev/null"):
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        r = open_room(types.SimpleNamespace(room_output=dev, fps=60), 2, 2, black)
    check(f"{dev} -> None, one line", r is None and buf.getvalue().count("continuing without it") == 1, buf.getvalue().strip())

r = open_room(types.SimpleNamespace(room_output=LOOP, fps=60), 1920, 1080, bytes([16, 128]) * (1920 * 1080))
check(f"{LOOP} -> open device", r is not None)
if r is not None:
    check("room fd non-blocking", os.get_blocking(r.fileno()) is False)
    r.close()
print("PASS" if not fail else f"FAIL ({fail})")
sys.exit(1 if fail else 0)
