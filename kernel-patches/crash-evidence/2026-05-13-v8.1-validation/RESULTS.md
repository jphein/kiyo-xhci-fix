# v8.1 synthetic validation — 2026-05-13

## Goal

Validate the v8.1 patch (uniform 100ms throttle + COMMIT-specific 200ms
throttle + COMMIT-specific 10s URB timeout) against the
sequence-dependent failure mode that caused 4 xHCI cascading deaths in
41 minutes during the morning's Brave WebRTC call.

## Methodology

`kernel-patches/test-probe-commit-cycle.sh` driven by `v4l2-ctl`:

- 200 cycles, INTERVAL_MS=0 (zero pacing between cycles — worst case)
- 5 formats rotating (480p / 720p / 1080p in MJPG; 720p / 480p in
  YUYV) — the ladder Chromium WebRTC actually negotiates
- Each cycle: set format → 3-frame stream → close, forcing fresh
  probe/commit pair on every iteration
- `capture-usbmon.sh` running in parallel for byte-level forensics

## Environment

- Kernel: 6.17.0-20-generic (Ubuntu HWE)
- xHCI: Intel Cannon Lake `0000:00:14.0` (quirks 0x0000000000009810)
- Device: Razer Kiyo Pro 1532:0e05, firmware 1.5.0.1 (bcdDevice 8.21)
- uvcvideo: DKMS `uvcvideo-kiyo/1.0` built 2026-05-13 with v8.1 source
- Boot cmdline `usbcore.quirks=1532:0e05:k` (NO_LPM) active
- Camera idle pre-test (no other consumer holding /dev/video0)

## Results

```
Completed 200 cycles, 200 successful, 0 v4l2 errors
No kernel failure markers observed.
```

- v4l2-ctl exit code 0 on every cycle
- Zero `Failed to set UVC commit control : -110` events in dmesg
- Zero `HC died` events in dmesg
- Zero `Abort failed to stop command ring` events in dmesg
- Watchdog `journalctl --user -u usb-watchdog`: no FATAL, no LEVEL
  recovery firings

## Wire-level forensics (usbmon)

Captured raw on bus 2 (Kiyo's bus) during the entire run.

- Total USB events captured: **170,411**
- `SET_CUR PROBE_CONTROL` (wValue=0x0100, wIndex=0x0001): **808**
- `SET_CUR COMMIT_CONTROL` (wValue=0x0200, wIndex=0x0001): **200**
- Ratio: 4 probes per commit, confirming each cycle does the expected
  GET_MIN → GET_MAX → SET_CUR(probe) → GET_CUR(probe) → SET_CUR(commit)
  negotiation pattern
- All 1008 class control transfers completed normally; no -110, no
  endpoint stall, no late completions
- Capture file: `usbmon-200cycles-v8.1-clean.txt.gz`
  (compressed from 20 MB → 1.9 MB; gunzip + open in Wireshark as
  Linux USB capture, or grep text format directly)

## Interpretation

This run is the strongest synthetic discrimination of Hypothesis B
(sequence-dependent) we can do without burning another real call:

- The cycle rate is *much faster* than real WebRTC. WebRTC renegotiates
  format on order minutes; this script does it every ~300 ms.
- The probe/commit pattern is real (5 production-grade format
  variants, not a synthetic SET_CUR flood).
- The cumulative control-transfer count (1008 SET_CURs in ~60 s) is
  comparable to a multi-hour real call.

Conclusion: **at uniform 100ms + COMMIT-specific 200ms + COMMIT
URB timeout 10s, the Kiyo Pro firmware does not enter the
cascading-fault state under hot-restart stress.**

This is necessary but not sufficient. The remaining validation step is
a real WebRTC call (~30 min minimum) on this hardware, ideally with
`capture-usbmon.sh` running in parallel. If that passes clean, v8 is
ready for upstream.

## What this does NOT prove

- Long-duration firmware-state accumulation (e.g., 6-hour calls)
- Concurrent contention from other devices on bus 1+2
- The specific failure mode if it has multiple trigger paths

The dmesg patterns from the morning's crashes were *all* identical
("Failed to set UVC commit control" → "Abort failed to stop command
ring" → "HC died"), so multiple-trigger-paths is unlikely; but real
calls do produce wire-level patterns this synthetic test cannot fully
mimic (notably bandwidth-driven irregular re-negotiation timing).
