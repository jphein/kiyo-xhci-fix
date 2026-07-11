# 2026-07-09 — first clean v8.1 call on STALE state (72 min, Brave/Meet)

**Verdict: PASS — and this is the accidental A/B the 06-10 RESULTS proposed.**
v8.1 survived a 72-minute real-world Brave call on a camera enumeration that
was **25.5 hours old** (no pre-call cycle — Brave grabbed `/dev/video0` before
the ritual could run). Zero precursors, zero watchdog interventions, camera
still at `2-3 speed=5000` on the *same* enumeration afterward. This is the
first **stale→clean** datapoint, breaking the previously perfect correlation:

| State at call start | Outcome | Dates |
|---|---|---|
| Fresh enumeration | clean 4/4 | 06-10, 06-11, 07-01, 07-08 |
| Stale state | failure 4/5 | 05-30, 06-06, 06-13, 06-30 (@3.2d) |
| Stale state | **clean 1/5** | **07-09 (@1.06d) — this call** |

06-10 RESULTS.md framed the open question as (a) "v8.1 works under real load"
vs (b) "fresh firmware state is the operative mitigation", and proposed a call
WITHOUT the pre-cycle to disambiguate. Today ran that experiment by accident.
One datapoint of (a)-support, with caveats below.

## Environment

- Kernel: 6.17.0-35-generic (stock Ubuntu HWE image)
- uvcvideo: DKMS `uvcvideo-kiyo/1.0` v8.1, srcversion `7FCA6457401AD6917E659B7`
  — verified loaded == DKMS .ko by `pre-call.sh` at 13:55:42
- Watchdog: active, Level 0 armed (verified 13:55:42); journal **empty** for
  the whole call window
- Boot 2026-07-08 06:57 PDT; **no suspend/resume this boot** (06-06's Path-2
  fragile state absent)
- Camera enumeration: 2026-07-08 12:23:29 PDT — yesterday's pre-call ritual
  (standard SS-cycle → USB2 fallback `-71` → HS-cycle → SS retrain, per the
  06-10 known pattern). One clean call (07-08) already streamed on this
  enumeration before today's.
- Load at call start: **7.20 on 8 cores** (real-world load; ghostty ~48%CPU) —
  call quality subjectively fine, no starvation symptoms reported
- Memory fragmented (1.3d uptime): see order-9 warn_alloc below

## Timeline (PDT)

| Time | Event |
|---|---|
| 13:53:36 | Brave opens `/dev/video0` (back-calculated from fuser etime) |
| 13:53:46 | STREAMON. `warn_alloc` splat: order-9 page allocation failure in `uvc_alloc_urb_buffers` → uvcvideo fell back to smaller URB buffers, stream started fine (see learning 3) |
| 13:55:42 | `pre-call.sh` run — **refused to cycle** (device held), correctly. v8.1 + watchdog checks passed. Call proceeds on stale state |
| 13:56:02 | `call-watch.sh` started; detected active call, usbmon capture begins on bus 2 (**first ~2.5 min of the call not captured**) |
| 15:05:54 | Call end. **CLEAN** — 1.7 GB usbmon captured, deleted per clean-call policy |
| 15:06+ | Post-call: camera still `2-3`, speed=5000, same enum timestamp (07-08 12:23:29 — never re-enumerated), `power/control=on`. dmesg: zero failure markers for the entire window |
| 16:26 | **Post-call idle sweep (+80 min): CLEAN.** Zero usb/xhci/uvc dmesg lines since call end; video0 idle; same enum, speed=5000. The 06-06-style ~14-min post-idle danger window passed clean — matches 06-10's post-call finding |

## Learnings

1. **Staleness is a risk factor, not a determinism.** With 4/4 fresh→clean and
   now 4/5 stale→failure, fresh enumeration still looks protective, but stale
   state alone doesn't doom a call. Consistent with the two-phase reconfig-lock
   model: the failure needs stale state AND a mid-call reconfiguration
   (COMMIT) that lands on the locked window. A call that never issues a risky
   reconfig can run clean on stale state indefinitely. Caveat: today's
   staleness (1.06d, one prior call) was milder than 06-30's (3.2d).

2. **Clean-call capture deletion loses the denominator.** We can't count how
   many COMMIT/reconfig events this call issued because the 1.7 GB capture was
   deleted on classify. If the two-phase model is right, that count is the
   exposure denominator (reconfigs survived per call). Future improvement:
   `call-watch.sh` could extract a one-line summary (COMMIT count, alt-setting
   changes) from the capture *before* deleting it.

3. **Order-9 `warn_alloc` at STREAMON is benign, not a precursor.** After 1.3d
   uptime the allocator couldn't find 2 MB contiguous for the URB buffers
   (`usb_alloc_noncoherent` → `dma_direct` path, no IOMMU remapping);
   `uvc_alloc_urb_buffers` retried at smaller order and streaming proceeded.
   Do NOT add to watchdog/call-watch trigger patterns. Note for wire-analysis:
   smaller URB buffers change completion cadence on the bus vs a fresh-boot
   call, and this call was clean anyway.

4. **The ritual has a race with call apps.** "Starting a call now" → Brave
   held `/dev/video0` within seconds, before `pre-call.sh` could cycle. The
   ritual must run *before* opening the meeting URL. `pre-call.sh`'s
   refuse-while-held check worked exactly as designed (cycling a held camera
   kills its stream).

5. **call-watch should be running before the app launches** — starting it
   mid-call worked (IDLE→ACTIVE transition fired on first poll) but the first
   ~2.5 min went uncaptured. Had the call crashed in those minutes, we'd have
   had dmesg but no wire data.

## What this datapoint does and does not change

- ANSWERS (partially) the 06-10 optional A/B: one stale, no-pre-cycle call ran
  clean on v8.1. Supports reading (a); does not prove it — one datapoint,
  moderate staleness, unknown reconfig count (learning 2).
- **v9 series framing (draft b7bb301) must be updated before sending**: any
  claim that stale state predicts failure is now 4/5, not 4/4. The honest
  framing is "fresh enumeration has never failed; stale state has failed 4 of
  5 times."
- Does NOT satisfy pecio-v7 pending item 1 (stock repro) — v8.1 was loaded.
- The pre-call ritual remains cheap, safe practice. This result doesn't argue
  for abandoning it — it argues the ritual is probably *sufficient* but maybe
  not *necessary* on v8.1.
