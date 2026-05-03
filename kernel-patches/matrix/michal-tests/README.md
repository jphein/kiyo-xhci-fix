# Michal's follow-up tests (2026-04-13 / 2026-04-27)

Two tests Michal Pecio asked for in the v5 2/3 thread, post-matrix.
They probe whether the failure is a UVC bug or a generic xHC bug.

## Test A — stream-open/close loop ✅ ran 2026-05-03

Asked 2026-04-13 (in his Test 1 walk-through), nudged again 2026-04-27.
Goal: kill the HC using only repeated stream open/close, no quirks,
no driver changes, no control spam.

### Recommended runner: `run-streamloop.sh`

Mirrors `run-hammerint.sh`'s structure: discovers all 1532:0e05 devices
by sysfs path, maps each to its `/dev/videoN` streaming endpoint, runs
the per-device cycle sequentially with off-target Kiyos unbound,
spawns the watchdog in test-mode for forensics + auto-recovery, settles,
rebinds.

    bash run-streamloop.sh

Defaults: `DURATION_SEC=300`, `WATCHDOG_MAX_RECOVERIES=1`. Override via
env vars (`DURATION_SEC=600 ./run-streamloop.sh`).

Pre-condition: boot into a kernel cmdline **without** `usbcore.quirks=1532:0e05:k`
(the wrapper warns and tags `quirk_active=1` if the quirk is still
present, so results stay self-describing). The included GRUB entry
`Ubuntu 6.17.0-20 — Kiyo VANILLA (no fixes)` (in `/etc/grub.d/40_custom`)
provides this.

Inner script `stream-loop.sh` per-iteration: open device → set MJPG
1920x1080 @ 30fps → capture 1 frame → close. The format must be set on
**every** v4l2-ctl invocation — without it the driver returns
`VIDIOC_REQBUFS = -EINVAL` and the loop spins on REQBUFS failures
instead of streaming. Format/resolution overridable via `WIDTH`,
`HEIGHT`, `PIXFMT`, `FPS` env vars.

### Result: 2026-05-03 (Intel xHCI 0000:00:14.0, kernel 6.17.0-20-generic vanilla)

Two-Kiyo run, 300s each, no quirks, no patched uvcvideo.

| Cell | Iters | Stream-loop verdict | Watchdog verdict | dmesg.post |
|------|-------|---------------------|-----------------|------------|
| `kiyo-2-1` (`/dev/video0`) | 134 | `PASS: clean` | `no_death_in_window` | clean |
| `kiyo-2-2` (`/dev/video2`) | 92 | `PASS: clean` | `no_death_in_window` | clean |

No `xhci_hc_died`, no `event condition 198`, no command timeouts on
either Kiyo. Pure stream-mmap teardown on Intel does **not** reproduce
HC death within a 5-minute window per Kiyo (~134 × 4 control transfers
+ isoc frames per cycle on Kiyo 2-1).

Per-cell forensics: `results/streamloop-20260503T221219Z/`.

Combined with the hammerint result on Intel (2026-04-29: 60s × 2 Kiyos
clean, NO_LPM active), this is **two independent reproducer styles
agreeing that Intel xHCI tolerates the firmware bug** where ASMedia
catastrophically dies. Doesn't disprove Michal's HW-bug framing —
confirms the silicon-tolerance gradient.

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
