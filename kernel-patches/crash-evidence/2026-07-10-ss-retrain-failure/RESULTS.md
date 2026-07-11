# 2026-07-10 — first SS-retrain failure: camera stranded at USB2 by the ritual

**Verdict: NEW failure mode of the recovery tooling (not a crash).** The
pre-call ritual's SS-port cycle produced its usual USB2 fallback, but for the
first time the HS-side retrain cycle did NOT bring the camera back to
SuperSpeed — three HS-side cycles across two `pre-call.sh` runs (14:02:18,
14:02:57), camera stayed at `1-3` speed=480. Retrain had been **5/5
deterministic** (06-10 ×2, 06-11, 07-04, 07-08) before this.

## Context

- The cycle attempt was made on the **2.07-day-stale** 07-08 12:23 enumeration
  (after a 3-min OBS session ended 14:01:58 clean, 50 MB usbmon deleted).
  Two calls' worth of streaming had accumulated on that enumeration
  (07-08 call, 07-09 72-min call).
- v8.1 verified loaded, watchdog active, no precursors during any cycle.
- Board has no per-port power switching (06-30 finding) — no software VBUS
  drop exists, so once link cycles fail, physical replug is the only path.
- As of 07-11 00:16 the camera had not been replugged: still `1-3` @480,
  devnum 43, enum 07-10 14:03:17. **Replug outcome pending** — if a VBUS drop
  restores SS training, this joins 06-30 as camera-firmware state that
  survives everything except power removal (a milder cousin of the 06-30
  protocol-death: there the camera wouldn't even enumerate; here it
  enumerates and streams at USB2 but won't SS-train).

## Tooling gaps found

1. **`/dev/video0` is hardcoded in both call-watch.sh and pre-call.sh.** At
   USB2 the camera's nodes came up as `/dev/video1`+`/dev/video2` (14:05), so
   call-watch polled a nonexistent node from 14:03 onward — **zero capture
   coverage for any subsequent USB2-camera call** — and pre-call.sh's
   held-check would likewise miss a live stream. Fix: resolve nodes from the
   device (e.g. `/sys/bus/usb/devices/<port>:1.0/video4linux/`) instead of
   assuming video0.
2. The ritual's two-attempt retrain has no third state: it correctly said
   "physically replug", but nothing alerts on the camera *staying* at USB2
   for hours afterward (same class as the 06-30 "no alarm on 24h camera
   absence" watchdog gap).

## What this does and does not change

- Does NOT touch the crash tally (no failure markers fired at any point;
  07-09/07-10 sessions were both clean).
- DOES weaken "the ritual is cheap and safe" (06-10 learning): the SS cycle
  now carries a real risk of stranding the camera at USB2 until someone is
  physically at the machine. Risk/benefit still favors the ritual before
  important calls, but it should not be run casually right before joining.
- Watch item: whether retrain failure correlates with accumulated stale
  state (this attempt was the stalest enumeration ever cycled) — one
  datapoint, no conclusion.
