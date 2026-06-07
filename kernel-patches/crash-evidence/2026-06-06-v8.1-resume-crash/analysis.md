# 2026-06-06 v8.1 Resume Crash Analysis

> **Revision note (2026-06-07, Opus re-audit):** the first draft of this file
> (Sonnet) contained three errors now corrected below: (a) resume→timeout was
> ~43 min, not "29 min"; (b) the `-110` at HC-death time is a cleanup artifact,
> not a "second commit stall"; (c) the endpoint that hung (EP2, iso) has *correct*
> descriptors — it is **not** an instance of the EP5 `wBytesPerInterval` bug.
> Claims are now tagged **[observed]** vs **[hypothesis]**.

**Date**: Saturday 2026-06-06 ~09:35 resume → 10:17:59 HC death PDT
**Kernel**: 6.17.0-35-generic
**Module**: uvcvideo-kiyo/1.0 DKMS (srcversion 7FCA6457401AD6917E659B7) — v8.1 CTRL_THROTTLE active
**Kiyo port**: 2-3 (was 2-1 in earlier sessions — physical move; confirmed live)
**Watchdog action**: Level 2 xHCI rebind at 10:17:59, successfully recovered
**Capture limitation**: watchdog grabbed `dmesg | tail -50` at HC-death time only.
No usbmon. The 827 s before death is **opaque** — nothing was logged in that window.

## Crash Timeline [observed]

| Kernel monotonic | Δ | Event |
|---|---|---|
| 41268.700 | — | `PM: suspend exit` (resume) |
| 42719 / 43110 | +24 / +31 min | VIA Labs hub (2-4) disconnect+re-enumerate ×2 |
| 43855.106 | +43.1 min from resume | `usb 2-3: timeout: still 12 active urbs on EP #82` |
| 43859.177 | +4.07 s | `uvcvideo 2-3:1.1: Failed to set UVC commit control : -32` (EPIPE/STALL) |
| 43859.276 | +0.10 s | `usb 2-4: reset SuperSpeed USB device number 6` (VIA hub) |
| *(43859 → 44686)* | **827 s of kernel silence — no usbmon, contents unknown** | |
| 44686.223278 | — | `xhci_hcd 0000:00:14.0: xHCI host not responding to stop endpoint command` |
| 44686.223308 | — | `HC died; cleaning up` |
| 44686.223337 | — | `Failed to set UVC commit control : -110` ← **logged *after* "HC died"; this is the cleanup flushing a pending URB, not a fresh commit** |

**Observed interval EP#82 timeout → HC death = 827 s (13.8 min).**

## What the trailing `-110` actually is [corrected]

The earlier draft read the `-110` as "a second COMMIT stall at 44686 that killed
the HC." That inverts cause and effect. The `-110` line (.223337) is timestamped
**after** `HC died; cleaning up` (.223308). When the HC dies, xhci error-completes
every in-flight URB; a commit-control URB that had been submitted earlier and was
hanging gets flushed with `-110` as part of that cleanup. The dead controller
causes the `-110`; the `-110` did not cause the death.

What actually preceded the death: at ~44681 (≈5 s before, the xHCI command
timeout) *something* issued a **stop-endpoint command**. The wedged controller
didn't answer → command-ring abort → `xhci_hc_died()`. The most likely trigger of
that stop-endpoint is the cancellation/teardown of the iso URBs that had been
stuck on EP#82 since 43855 — **but with no usbmon this is [hypothesis], not
[observed].**

## Camera was held open by Google Meet [confirmed by JP]

Google Meet (Brave, `getUserMedia`) held `/dev/video0` from before suspend; the
browser reacquired the stream on resume. No active call — just the tab holding
camera permission. Elapsed resume→EP#82-timeout was **~43 min** (upper bound on
streaming duration; we don't know exactly when Meet re-grabbed the stream).

**Deterministic reproducer to attempt:**
1. Join/open Google Meet, camera on (stream live).
2. Suspend → resume.
3. Leave the Meet tab open, camera held, otherwise idle.
4. Watch for `usb 2-N: timeout: still N active urbs on EP #82`.

This needs to be re-confirmed as deterministic — we have it once. Run it on stock
first (does it reproduce?), then on xhci-test.

## Endpoint facts [observed, from lsusb -vv + SS companion descriptors]

| EP | Type | wMaxPacketSize | wBytesPerInterval | Mismatch? |
|---|---|---|---|---|
| 0x85 (EP5 IN) | Interrupt | 64 | **8** | **YES — Michal's bug** (8 < 64) |
| 0x81 (EP1 IN) | Isochronous | 1024 | 3072 / 33792 | no |
| **0x82 (EP2 IN)** | **Isochronous** | 196/68/100/132 | 196/68/100/132 | **no — all correct** |

**The endpoint that hung (EP2, iso) has correct descriptors.** It is *not* an
instance of the EP5 `wBytesPerInterval` mismatch. This is the key correction: the
06-06 hang cannot be attributed directly to the descriptor bug Michal identified.

## Relationship to Michal Pecio's patch [hypothesis — to be tested, not asserted]

Michal's test patch has two parts:
1. `xhci-mem.c`: clamp `max_esit_payload = max_packet` when `interval &&
   max_esit_payload < max_packet`. This corrects **EP5** (interrupt) bandwidth
   bookkeeping. It does not change EP2 (whose values are already consistent).
2. `xhci-ring.c`: retry on `COMP_SHORT_PACKET` in **`process_bulk_intr_td`** —
   the bulk/interrupt TD path. **This does not run for isochronous transfers.**

So neither part *obviously* touches the iso EP2 path that hung on 06-06. Two
possibilities the xhci-test run must distinguish:

- **(A) Shared root via ring pressure:** EP5's underallocation produces a
  `COMP_SHORT_PACKET` flood that congests the shared event/command ring, and that
  congestion is what eventually wedges EP2 and ep0. If so, fixing EP5 (part 1)
  could prevent the EP2 hang indirectly. *Plausible but unproven — we have no
  EP5 short-packet evidence in this crash (no usbmon).*
- **(B) Independent iso-side fault:** the EP2/firmware lock is a separate issue
  that Michal's patch won't address.

The xhci-test re-run is the experiment that decides between (A) and (B). Until
then, do **not** tell Michal his patch "is the fix" for this crash.

## Why v8.1's mitigations are structurally blind to this [observed]

- The first commit failure was **`-32` EPIPE = an immediate device STALL**, not a
  timeout. v8.1 raised the COMMIT *URB timeout* to 10 s — but you cannot wait
  longer for a response that already came back as STALL. The timeout extension is
  inapplicable to a STALL by construction.
- The crash occurred with **no UVC control activity driving it** (camera idle at
  the OS level). The CTRL_THROTTLE inter-commit interval governs control-transfer
  *rate*; there was no rate to throttle here. Throttling is the wrong layer for
  this failure.

## Relationship to 2026-05-30 [observed where noted]

| | 2026-05-30 (active call) | 2026-06-06 (resume, Meet idle) |
|---|---|---|
| First logged symptom | COMMIT stall | EP#82 iso URB timeout |
| First commit error code | -110 | -32 (EPIPE) then -110 at death |
| EP#82-timeout→death | n/a (usbmon: ~7.17 s submit→death) | 827 s (opaque) |
| usbmon | yes (~136 MB) | no |

These may be **two presentations of one root cause** (sustained streaming
destabilises firmware/host; control-commit stall is a visible symptom) rather than
two mechanistically distinct paths. The earlier "Path 1 / Path 2" labelling
over-committed to two-distinct-mechanisms; treat that as a working hypothesis.

## Action items

- [ ] **Reproduce on stock first**: confirm the Meet-resume-idle sequence reliably
      produces the EP#82 timeout. One occurrence ≠ deterministic yet.
- [ ] Capture **usbmon** during that stock reproduction — specifically to see
      whether EP5 `COMP_SHORT_PACKET` events are in fact flooding (tests theory A).
- [ ] Re-run on **6.17.0-xhci-test** (Michal's patch) with usbmon: does the EP#82
      hang disappear? Decides A vs B.
- [ ] Only after the above: finalise the Pecio reply (currently `reply-to-pecio-v6.txt`).
