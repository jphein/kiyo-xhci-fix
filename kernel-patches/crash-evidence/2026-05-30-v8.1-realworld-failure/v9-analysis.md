# v9 analysis — why v8.1 failed on the 2026-05-30 live call

Wire-level analysis of the live-call usbmon capture
(`/tmp/kiyo-livecall-usbmon-20260530-122904.txt`, ~136 MB, all buses).
Filtered to the Kiyo's actual UVC control traffic on bus 2
(`Co:2:*:0`, setup `21 01 0X00 0001 001a` = SET_CUR PROBE/COMMIT_CONTROL,
26-byte payload). Evidence extracts in this dir:
`kiyo-bus2-control-transfers-20260530.txt`,
`kiyo-commit-cadence-and-errors-20260530.txt`.

> ⚠️ First-pass caveat: an initial grep on `21 01 0200` was **contaminated**
> by bus-1 HID/RGB traffic sharing that wValue (2-byte payloads on
> `Co:1:009`). The findings below use the strict UVC filter
> (`Co:2`, wIndex `0001`, 26-byte). N is small (7 COMMIT, 13 PROBE) —
> these are real renegotiations, not a synthetic flood.

## Finding 1 — the failure is NOT COMMIT rate

The 7 real `COMMIT_CONTROL` transfers were **seconds to minutes apart**
(inter-COMMIT Δ ≈ 12.8 s, 269 s, 13.2 s, 45 s, 26.6 s, 197 s). v8.1's
200 ms COMMIT floor is satisfied by 1–3 orders of magnitude on every
single one — **and they still failed.** Throttling COMMIT *rate* (the
entire v5→v8.1 thesis) does not address the trigger.

Source confirms the throttle *is* applied to COMMIT: the streaming path
`uvc_set_video_ctrl()` routes through the throttled `__uvc_query_ctrl()`
(`uvc_video.c:452`), where `dev->last_ctrl_jiffies` gates a `msleep`. So
the throttle runs — it just doesn't matter, because the COMMITs aren't
arriving fast.

## Finding 2 — COMMIT stalls ~7.2 s, then the HC dies *before* the 10 s URB timeout

Two COMMIT failures, paired submit → complete:

| COMMIT submitted | completed (`-108` ESHUTDOWN) | outstanding |
|---|---|---|
| t=1490026767 | t=1497192274 | **7.17 s** |
| t=1758826988 | t=1765994072 | **7.17 s** |

Two independent stalls at the *same* ~7.17 s is deterministic, not
random. Consistent mechanism: firmware stalls the COMMIT → xHCI
`stop endpoint` command times out → command-ring abort → **HC died (~7 s)**
→ the pending COMMIT URB completes `-108`. dmesg for the same events
shows the matching `Failed to set UVC commit control : -110/-108` →
`xHCI host controller not responding, assume dead` → `HC died`.

**Consequence:** v8.1's signature mitigation — extending the COMMIT URB
timeout to 10 s — **never fires.** The Cannon Lake controller dies at
~7 s, before the 10 s timeout is reached. That mitigation is moot on this
silicon.

## Implication for v9 — change the axis

1. **A bigger/smarter uvcvideo throttle is unlikely to help.** COMMITs are
   already well-spaced and still stall, and the host dies before any URB
   timeout extension matters. More throttle tuning is polishing the wrong
   lever.
2. **The fix belongs on the xHCI side: survive a firmware-stalled control
   endpoint instead of dying.** This matches the upstream evidence —
   Michal Pecio's xhci clamp + short-packet-retry patch (Test 2) let the
   HC *survive* the firmware lockup. A `6.17.0-xhci-test` kernel with that
   patch is already installed on this box.
3. **Recommended next step:** deprioritise further uvcvideo-throttle
   iteration; reproduce this exact live-call cascade on the
   `6.17.0-xhci-test` kernel (Michal's patch) with usbmon running, and
   take the result back to Mathias Nyman / Michal Pecio on-thread. The
   already-merged quirks (NO_LPM) + autosuspend/reset settings stay; the
   throttle quirk's value is now in doubt for real-world use.

## What would make this airtight (not yet done)

- Larger N — this is 7 COMMITs from one call.
- Confirm the ~7.17 s is the xHCI command timeout (5 s) + abort latency
  vs. a firmware-side watchdog, by correlating with `xhci` dynamic-debug
  timestamps.
- Preserve the full 136 MB capture before reboot (currently in `/tmp`,
  volatile). The filtered bus-2 extract here is durable; the raw is not.
