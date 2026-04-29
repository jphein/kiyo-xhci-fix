# Michal's follow-up tests (2026-04-13 / 2026-04-27)

Two tests Michal Pecio asked for in the v5 2/3 thread, post-matrix.
They probe whether the failure is a UVC bug or a generic xHC bug.

## Test A — stream-open/close loop

Asked 2026-04-13 (in his Test 1 walk-through), nudged again 2026-04-27.
Goal: kill the HC using only repeated stream open/close, no quirks,
no driver changes, no control spam.

Pre-condition: open the camera with a viewer (e.g. `vlc` or
`v4l2-ctl --stream-mmap`) once first, then close it. This puts the
device in the "warmed up" state Michal saw before death.

Run:

    bash stream-loop.sh

Hits the HC with one v4l2 frame grab per iteration in a tight loop.
If the HC dies without any of our patches active, that strengthens
Michal's "this is an xHC HW bug, not a UVC bug" position — and we
gain a row for the v8 cover letter.

## Test B — interrupt-endpoint hammer (`hammerint`)

Asked 2026-04-27. Michal's standalone libusb-1.0 program. He says
it reliably breaks ASMedia HCs within seconds; question is whether
Intel HCs break too.

The source is attached to his 2026-04-27 06:35 UTC reply on the
v5 2/3 thread. Save it here:

    michal-tests/hammerint.c

Then:

    bash run-hammerint.sh

The runner builds with `cc -lusb-1.0 hammerint.c -o hammerint`
and runs `sudo ./hammerint 1532 0e05 0 85` (Kiyo VID:PID, interface 0,
EP 0x85 IN).

If this kills the Intel HC with no uvcvideo in the picture, the
v8 cover letter needs a paragraph acknowledging Michal's HW-bug
framing — the quirk is mitigation, not cause-fix.

## Why these tests sit outside the main matrix

The 5×2 cell matrix in the parent directory exists to answer
"does CTRL_THROTTLE earn its keep on top of Michal's xhci patch?"
These two tests answer a different, broader question: "is the
failure mode reproducible without uvcvideo at all?" Different
hypothesis, different framing — keep them separate so the matrix
results stay clean.

Both tests should be run on a STOCK 6.17 kernel with no quirks
and no patched uvcvideo. The point is to fail in the unmodified
configuration.
