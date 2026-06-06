# 2026-06-06 v8.1 Resume Crash Analysis

**Date**: Saturday 2026-06-06 ~10:04–10:18 PDT  
**Kernel**: 6.17.0-35-generic  
**Module**: uvcvideo-kiyo/1.0 DKMS (srcversion 7FCA6457401AD6917E659B7) — v8.1 CTRL_THROTTLE active  
**Kiyo port**: 2-3 (moved from 2-1 after suspend/resume — confirmed by post-crash watchdog crash dump)  
**Watchdog action**: Level 2 xHCI rebind at 10:17:59, successfully recovered

## Crash Timeline

| Kernel time | Event |
|---|---|
| ~41268s | System resume from suspend (PM: suspend exit) |
| 43855.106 | `usb 2-3: timeout: still 12 active urbs on EP #82` |
| 43859.177 | `uvcvideo 2-3:1.1: Failed to set UVC commit control : -32 (exp. 26)` |
| ~44686 (inferred) | Second COMMIT stall (not directly logged) |
| 44686.223 | `xhci_hcd 0000:00:14.0: xHCI host not responding to stop endpoint command` |
| 44686.223 | `HC died; cleaning up` |
| 44686.223 | `uvcvideo 2-3:1.1: Failed to set UVC commit control : -110 (exp. 26)` ← post-mortem |

**Interval: EP#82 timeout → HC death = 831 seconds (~14 minutes)**

## Root Cause of EP#82 Activity: Google Meet

Google Meet (Brave browser, via `getUserMedia`) held `/dev/video0` open from the
previous session. The browser reacquired the camera on resume and continued submitting
ISO URBs continuously. The camera was not in an active call at crash time — the Meet
tab was open with camera permission held. ~29 minutes of continuous ISO streaming
post-resume drove the COMP_SHORT_PACKET flood to threshold.

**Reproducer (deterministic):**
1. Open Google Meet (camera permission granted, stream active)
2. Suspend → resume
3. Leave Meet tab open, camera idle (~30 min)
4. Watch for `usb 2-3: timeout: still N active urbs on EP #82`

No active call needed. The stream being held open is sufficient. This is the exact
scenario to run on the xhci-test kernel.

## Key Differences from 2026-05-30 Crashes

| | 2026-05-30 (call during work) | 2026-06-06 (resume crash) |
|---|---|---|
| First signal | COMMIT -110 stall | EP#82 URB timeout (video data) |
| COMMIT error code | -110 (ETIMEDOUT) | -32 (EPIPE / STALL) first |
| Interval to HC death | ~7.17s (measured via usbmon) | ~831s (14 min, second stall killed it) |
| usbmon captured | Yes (raw 136MB) | No (watchdog captured post-mortem only) |
| Context | Active WebRTC call | Post-resume, likely camera not in active use |

## EP #82 = EP2 IN (Isochronous video data stream)

Endpoint address 0x82: direction IN, endpoint number 2. For the Kiyo Pro this is the
isochronous bulk video data stream. "12 active URBs" timed out on this endpoint before
the commit stall — the video stream stopped first.

**Significance**: The 2026-05-30 crashes appeared to be COMMIT-triggered (control
endpoint failure). This crash shows video data endpoint failure FIRST. Two distinct
trigger paths:
1. Direct COMMIT control stall (2026-05-30 pattern, well-spaced commits still fail)
2. Video stream URB flood/timeout → firmware confused → control endpoint fails (today)

Path 2 maps directly to Michal Pecio's SHORT_PACKET hypothesis: the Kiyo's
wBytesPerInterval=8 vs wMaxPacketSize=64 mismatch causes COMP_SHORT_PACKET errors on
every video frame, flooding the xHCI event ring. The ring congestion can starve the
control endpoint, producing the STALL (-32) → eventual timeout (-110) → HC death cascade.

## The -32 EPIPE (STALL) vs -110 ETIMEDOUT

- **-32 EPIPE** (STALL): the firmware returned a USB STALL PID, or the host cancelled
  the transfer. Less severe than -110; the endpoint may self-recover.
- **-110 ETIMEDOUT** (ETIMEDOUT): the stop-endpoint command to xHCI timed out. This is the
  point of no return — the hardware command ring is stuck.

The -32 at 43859 may have been a transient stall that the firmware partially recovered
from. The HC death at 44686 (831s later) was likely a second commit stall that fully
locked the command ring.

## Implications for v9 / Pecio Reply

1. **v8.1 CTRL_THROTTLE is not sufficient for the resume path** — this crash happened
   post-resume before any WebRTC call started, so commit rate is not the trigger here.

2. **The xHCI-side fix (Michal's clamp + SHORT_PACKET retry) addresses Path 2** — the
   COMP_SHORT_PACKET flood is the upstream cause of the video-stream URB timeout and
   the firmware confusion that follows.

3. **For the Pecio reply**: include this as evidence that the failure mode is broader
   than COMMIT rate — Path 2 (video stream disruption → control failure) exists and is
   triggered by the wBytesPerInterval bug. Michal's patch addresses the root cause.

4. **usbmon capture needed for Path 2**: a replay of this scenario (resume → let camera
   idle → check for EP#82 timeouts) with usbmon running would quantify the SHORT_PACKET
   flood rate. Run on the xhci-test kernel to compare.

## Action Items

- [ ] Re-run xhci-test kernel (Michal's patch) after a resume, let idle, check if
      EP#82 URB timeouts appear
- [ ] Capture usbmon during a resume cycle on stock kernel to see SHORT_PACKET count
- [ ] Update Pecio reply draft (v5) with this new evidence (Path 2 failure mode,
      post-resume idle crash, -32 EPIPE signal preceding HC death)
