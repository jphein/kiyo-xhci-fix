# 2026-08-25 — Stock-kernel HC death + two precursor stalls (the stock repro)

The datapoint owed upstream since April: HC death on **stock uvcvideo 7.0.12
(Ubuntu 7.0.0-30)**, no out-of-tree module anywhere, full usbmon preserved,
provenance stamped by call-watch (`uvcvideo=STOCK(D122AF0B) kiyo_mic=yes`).

## Events

| Time (PDT) | Event | Capture |
|---|---|---|
| 14:06:19 | Fresh replug enum, devnum 20 (SS) | — |
| 14:07–14:16 | Clean Brave call + clean OBS session | deleted per clean policy |
| 14:26:36 | **Two-phase lock → HC death** during 3rd session | `auto-captures/CRASH-20260825T212701Z-4events.txt.gz` (168MB raw) |
| 14:27:01–:16 | usb-watchdog Level 2 xHCI rebind; all devices back in ~16s; camera self-recovered (fresh enum 14:28:03) | `usb-watchdog-crash-20260825-142701.log` (rescued from tmpfs) |
| 14:30:13 | commit −110 stall on the 2-min-old enum; **Level 0 early intervention** cycled camera, no HC death | `CRASH-20260825T213016Z-1events.txt.gz` |
| 14:31:55 | JP physical replug (VBUS drop), devnum 9 | `CRASH-20260825T213154Z-1events.txt.gz` (pre-replug tail) |
| 15:08:25 | commit −32 stall on first STREAMON after v9-candidate module swap (same enum); Level 0 cycled | `CRASH-20260825T220834Z-1events.txt.gz` |
| 15:09:11 | Manual full xHCI rebind → fresh enum devnum 3 | — |
| after | Zero stalls/storms since (verified through 08-26 04:30) | — |

## Wire findings (first-pass on the 14:27 capture, analyzed on familiar)

- **Phase 1:** `SET_INTERFACE alt0` submitted at stream stop → hangs **5.16s** →
  unlinked (−2). Matches 06-13 (5.4s) and 05-30 (5.1–5.5s).
- **Phase 2:** COMMIT submitted immediately after → never completes; dmesg
  escalation: evaluate-context timeout → `Abort failed to stop command ring:
  -110` → `HC died`. Total wedge-to-death ≈ 18.5s after COMMIT submit.
  The `commit control : -110` line prints **post-mortem** (cleanup reap).
- **Audio (ep 0x82 = microphone) streamed healthily until HC death**; video
  (ep 0x81) had already stopped cleanly before Phase 1. Endpoint identity per
  the 08-19 wire correction: 0x81=video, 0x82=mic, 0x85=interrupt/status.
- **EP5/hypothesis-A check on stock: 5 events total on ep 0x85, all teardown**
  (2× −2, 1× −108). No COMP_SHORT_PACKET flood. Hypothesis A excluded on
  stock as well as v8.1.
- Endpoint census: 1,183,002 events audio ep2 · 291,711 video ep1 · 24 control.

## Same-day discovery: NO_LPM quirk not applied on 7.x

Device `quirks` attr reads `0x10` (only udev's RESET); `usb3_hardware_lpm_u1`
was **enabled** despite (a) the merged static table entry present in 7.0
sources and (b) live `usbcore.quirks=1532:0e05:k`. P1 merged yet defeated —
separate usb-core regression, report to linux-usb pending bisect. Stopgap
shipped in the v9-candidate module: `usb_disable_lpm()` at probe (verified:
u1/u2 disabled on every enum since).

## Confound (do not overread frequency)

katana was concurrently in a CPU/memory saturation incident (load ~25, 9.2GB
swap, tmpfs spill; order-9 alloc fallback in `uvc_alloc_urb_buffers` in-window).
The **mechanism** matches June's normal-load wire captures exactly; the
**event frequency** that day is not clean evidence. Fresh-enum tally after
this day: **5/6** (first fresh-enum failure — freshness reduces risk, is not
protection).
