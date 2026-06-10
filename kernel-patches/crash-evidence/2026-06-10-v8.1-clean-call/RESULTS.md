# 2026-06-10 — first clean v8.1 real-world call (61 min, Brave/Meet)

**Verdict: PASS — but with a deliberate confound.** v8.1 survived a 61-minute
real-world Brave video call AND the post-call idle window with zero precursors,
zero watchdog interventions. However the camera was freshly re-enumerated
minutes before the call (pre-call port cycle), so this datapoint supports two
readings: (a) v8.1 works under real load, or (b) **fresh firmware state is the
operative mitigation** — which fits the accumulated-state single-root-cause
picture from the 06-07 Opus re-audit better than (a). Both prior v8.1 failures
(05-30, 06-06) involved long-lived camera state.

## Environment

- Kernel: 6.17.0-35-generic (stock Ubuntu HWE image; `6.17.0-xhci-test` installed but NOT booted)
- uvcvideo: DKMS `uvcvideo-kiyo/1.0` v8.1, srcversion `7FCA6457401AD6917E659B7`
  (verified loaded == `updates/dkms` .ko ≠ stock `7CD08F45C7F58DA18CC11AA`)
- NO_LPM: active via **boot cmdline** `usbcore.quirks=1532:0e05:k`
  (note: the modprobe.d copy of this option is ineffective — usbcore is builtin on this kernel)
- Audio quirk: `snd-usb-audio quirk_flags=0x4000001` for 1532:0e05
- Watchdog: active, Level 0 early intervention enabled (commit e3957db)
- Boot 09:33:25 PDT; **no suspend/resume this boot** (Path-2 fragile state absent)
- usbmon auto-capture armed via `call-watch.sh` (classifier fixed same day to
  also preserve on the `timeout: still N active urbs` precursor)

## Timeline (PDT; kernel monotonic in brackets)

| Time | Event |
|---|---|
| 09:33 | Boot. Kiyo enumerates at 2-3 SuperSpeed. One `Failed to set UVC probe control : -32 (exp. 26)` — see "benign artifact" below |
| ~10:55 [4921.3] | **Pre-call cycle #1** — link-level SS-port cycle (`usb2-port3/disable` 1→0). Camera fell back to **USB2**: two `device descriptor read/64, error -71` (failed SS training), re-enumerated as `1-3` high-speed (480) |
| ~10:56 [4984.5] | **Pre-call cycle #2** — HS-port cycle (`usb1-port3/disable` 1→0). Camera retrained SuperSpeed: `2-3: new SuperSpeed USB device number 5`, speed=5000. udev pins reapplied (`power/control=on`, `avoid_reset_quirk=1`) |
| 10:59:22 | Call start (holder=brave). usbmon capture on bus 2 begins |
| 12:00:45 | Call end. **Clean** — 290 MB usbmon captured, deleted per clean-call policy |
| 12:26 | Post-call window check: zero precursors since 12:00, Kiyo still `2-3 speed=5000`. (06-06's cascade hit ~14 min post-idle; this window passed clean) |

Watchdog journal: **zero lines** from 10:40 onward — no Level 0 blips, nothing.

## Operational learnings

1. **SS-port link cycle strands the camera at USB2 — apparently every time**
   (2/2 observations on 2026-06-10: the manual pre-call cycle and the
   `pre-call.sh` validation run both fell back). Disabling/re-enabling
   `usb2-port3` lets the device connect via its USB2 pins (bus 1, 480)
   when SS training fails. Fix: cycle the HS-side port (`usb1-port3/disable`)
   — the device then retrains SuperSpeed. **Always verify `speed` == 5000 at
   2-3 after any port cycle.** This applies to `revive-kiyo.sh` too (same
   mechanism — it now checks). The `-71` descriptor errors during the fallback
   are expected noise from the failed SS training, not a fault.

2. **`Failed to set UVC probe control : -32 (exp. 26)` is a benign
   per-enumeration artifact.** It fired on every single enumeration this boot
   (boot, USB2 fallback, SS retrain) with the camera healthy each time. It is
   NOT a precursor and must not be added to watchdog/call-watch trigger
   patterns. The dangerous sibling is `Failed to set UVC **commit** control`.

3. **The classifier gap that nearly cost us evidence:** `call-watch.sh`
   preserved captures only on commit-stall/HC-died markers. On a stock kernel a
   precursor-only call (`timeout: still N active urbs` — the EP#82 signature
   reply-to-pecio-v7 wants captured) would have been classified CLEAN and the
   usbmon deleted. Fixed 2026-06-10: both grep patterns now mirror the
   watchdog's Level-0 trigger.

## What this datapoint does and does not change

- Does NOT satisfy pecio-v7 pending item 1 (stock repro) — v8.1 was loaded.
- Does NOT vindicate v8.1 alone — the fresh-enumeration confound is real.
- DOES establish the **pre-call fresh-enumeration ritual** as cheap, safe
  practice (`./pre-call.sh`). If several future calls with the ritual stay
  clean, that pattern itself is reportable upstream as supporting the
  accumulated-firmware-state hypothesis.
- Optional future A/B: a call WITHOUT the pre-cycle on v8.1 would disambiguate
  (a) vs (b) — at the cost of risking a crash mid-call. Only worth it on a
  call that can tolerate a watchdog blip.
