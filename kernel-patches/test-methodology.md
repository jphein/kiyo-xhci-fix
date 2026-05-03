# Test Methodology: Razer Kiyo Pro xHCI Cascade Failure

## Hardware Under Test

| Component | Detail |
|-----------|--------|
| **Webcam** | Razer Kiyo Pro (1532:0e05), firmware 8.21 |
| **Host Controller** | Intel Cannon Lake PCH xHCI (8086:a36d), PCI 0000:00:14.0 |
| **Kernel** | 6.8.0-106-generic (Ubuntu 24.04) |
| **Other USB devices** | Dygma keyboard (1209:2201), Logitech receiver (046d:c548) |

## Crash Reproduction

### Stress Test Script

`stress-test-kiyo.sh` exercises UVC controls via `v4l2-ctl` at ~0.2s intervals
per round. Each round performs the following control sequence on `/dev/video0`:

1. **Focus**: disable auto-focus, set manual focus=300, re-enable auto-focus
2. **White balance**: disable auto, slam to 2000K, slam to 7500K, re-enable auto
3. **Exposure**: switch to manual, set min (3), set max (2047), switch to auto
4. **Pan/tilt/zoom**: zoom 400, pan -36000, tilt 36000, reset all to 0
5. **Brightness/contrast/saturation**: cycle through 0, 255, 128 for each

After each round, the script verifies the device is still alive via
`v4l2-ctl --get-ctrl=brightness`. If the device stops responding, it waits 3s
for self-recovery before aborting.

### Observed Crash Pattern

Crashes consistently occur around **round 25 of 50** (roughly 5-10 seconds of
sustained rapid control changes). The failure sequence in `dmesg`:

```
xhci_hcd 0000:00:14.0: xHCI host not responding to stop endpoint command
xhci_hcd 0000:00:14.0: xHCI host controller not responding, assume dead
xhci_hcd 0000:00:14.0: HC died; cleaning up
```

This disconnects **all USB devices** on the controller, not just the camera.
Keyboard, mouse, and all other peripherals are lost. Without the watchdog
service, a hard reboot is required.

### Crash Root Cause Chain

1. Rapid UVC control SET_CUR requests overwhelm the Kiyo's firmware
2. Device endpoint stalls, returning `-32` (EPIPE)
3. xHCI driver issues a stop-endpoint command
4. Device firmware is unresponsive; stop-endpoint times out after 5s
5. xHCI driver declares host controller dead (`HC died`)
6. All USB devices on `0000:00:14.0` are torn down

## Quirks Tested

### Quirk 1: USB_QUIRK_NO_LPM (runtime test via sysfs)

- **Applied via**: `echo 0 > /sys/bus/usb/devices/.../power/usb3_lpm_permit`
- **What it does**: Disables USB 3.0 Link Power Management U1/U2 states
- **Result**: Did NOT prevent crash. LPM disable takes effect at enumeration
  time in the kernel; the sysfs knob may be read-only depending on hardware.
  The compiled kernel quirk is needed for full LPM disable, but LPM alone is
  not the sole trigger — rapid control transfers crash the device even with
  LPM disabled.

### Quirk 2: UVC_QUIRK_DISABLE_AUTOSUSPEND (runtime test via sysfs)

- **Applied via**: `echo on > /sys/bus/usb/devices/.../power/control`
- **What it does**: Prevents USB autosuspend, keeping device permanently active
- **Result**: Did NOT prevent crash under stress test. Autosuspend is a
  contributing factor during normal use (idle → resume → broken endpoint), but
  the stress test crashes the device through rapid control transfers while it
  is already fully active.

### Quirk 3: avoid_reset_quirk (sysfs)

- **Applied via**: `echo 1 > /sys/bus/usb/devices/.../avoid_reset_quirk`
- **What it does**: Prevents USB core from issuing device reset during error
  recovery, avoiding the fragile reset-resume path
- **Result**: Did NOT prevent crash under stress test. This quirk helps prevent
  cascade from a single device error to controller death, but does not prevent
  the initial endpoint stall caused by rapid control transfers.

### Combined Runtime Test

All three quirks applied together via udev rule
(`99-razer-kiyo-pro.rules`) — the stress test still crashes the controller.
This confirms that **the root cause is in the device firmware's handling of
rapid UVC control transfers**, not solely in power management transitions.

## Test Procedures

### Pre-Test Setup

1. Ensure SSH is running (`sudo systemctl enable --now ssh`) for recovery
   if USB dies
2. Start the USB watchdog: `systemctl --user start usb-watchdog.service`
3. Open a second terminal for log monitoring:
   `journalctl -k -f | grep -i 'xhci\|uvc\|kiyo\|error'`

### Stress Test Execution

```bash
sudo bash ~/Projects/kiyo-xhci-fix/kernel-patches/apply-and-test.sh   # apply quirks
bash ~/Projects/kiyo-xhci-fix/kernel-patches/stress-test-kiyo.sh 50   # run test
```

Record: round number at crash, full dmesg output, quirks in effect.

### Watchdog Recovery Test

```bash
bash ~/Projects/kiyo-xhci-fix/kernel-patches/test-watchdog.sh
```

This simulates a crash by unbinding the xHCI controller and verifies:
- Watchdog detects the missing devices within seconds
- Recovery re-enumerates the controller
- Dygma keyboard (1209:2201) and Logitech receiver (046d:c548) return
- Crash log is saved to `/tmp/usb-watchdog-crash-*.log`

### Post-Crash Data Collection

The watchdog automatically saves crash context to
`/tmp/usb-watchdog-crash-YYYYMMDD-HHMMSS.log` containing:
- Last 50 lines of dmesg
- `lsusb` output
- HID device sysfs state
- Expected device presence check

For manual collection:
```bash
dmesg | tail -100 > /tmp/usb-crash-manual.log
lsusb >> /tmp/usb-crash-manual.log
```

## 6.17.0-xhci-test Kernel Results (2026-04-10)

Custom kernel with Michal Pecio's xhci patch (clamps max_esit_payload to at
least max_packet_size, resets err_count on COMP_SHORT_PACKET). Two tests run
on Intel Cannon Lake (8086:a36d).

### Test 1: All fixes + Michal's xhci patch

Active: `usbcore.quirks=1532:0e05:k` (NO_LPM) + DKMS uvcvideo (CTRL_THROTTLE)
+ Michal's xhci patch.

**Result: HC DIED.**

Cascade sequence from full log (1.06M lines):
1. 437 repeated Cancel/resubmit cycles on EP5 IN (ep 0x85, interrupt) over ~7 min
2. Endpoint reconfigure triggered
3. ~994K spurious SHORT_PACKET completion events (comp_code 13) over ~5 min
4. Control URB timeouts on default control endpoint
5. `xhci_hc_died()` — all USB devices disconnected

Full log: `crash-evidence/crash-6.17.0-xhci-test-20260410-152541.log.gz` (2.9MB)

### Test 2: Michal's xhci patch ONLY (no JP patches)

No NO_LPM, no CTRL_THROTTLE, no DISABLE_AUTOSUSPEND — only Michal's xhci patch.

**Result: HC SURVIVED.**

Firmware locked up at stress test round ~23 as expected. Transfer errors on
ep 10 occurred but the host controller handled them gracefully — no HC death.
`max_esit_payload 8 -> 64` confirmed firing at boot for EP5 IN.

Full log: `crash-evidence/crash-6.17.0-xhci-test-20260410-154243.log.gz` +
`crash-evidence/michal-only-stress-20260410.log`

### Analysis

EP5 IN (interrupt, wBytesPerInterval=8, wMaxPacketSize=64) is at the center of
both tests. The firmware's spec violation causes the xHCI driver to allocate
insufficient bandwidth (max_esit_payload=8 instead of 64). Michal's patch
corrects this at the driver level. The different outcomes between Test 1 and
Test 2 may be due to different test conditions (stream teardown vs active
streaming when firmware lockup occurs).

## Stream-mmap loop test (2026-05-03)

Run via `kernel-patches/matrix/michal-tests/run-streamloop.sh` with
test-mode watchdog supervision. Conditions: kernel 6.17.0-20-generic
vanilla (booted into the `Kiyo VANILLA (no fixes)` GRUB entry), no
`usbcore.quirks` cmdline parameter, stock uvcvideo (no DKMS module),
two Razer Kiyo Pro units on Intel xHCI 0000:00:14.0 ports 2-1 and 2-2.

Per-iteration v4l2-ctl invocation:
`--set-fmt-video=width=1920,height=1080,pixelformat=MJPG --set-parm=30 --stream-mmap --stream-count=1`.
Each iteration is a fresh open → format negotiation (4 control
transfers: VS_PROBE_CONTROL probe/commit + VS_FRAME_CONTROL set-fps)
→ isoc frame capture → close. 300s per Kiyo, sequential (off-target
Kiyo unbound for the duration of each cell).

| Cell | Device | Iters | dmesg.post | Stream-loop | Watchdog |
|------|--------|-------|------------|-------------|----------|
| 2-1 | `/dev/video0` | 134 | clean | `PASS: clean` | `no_death_in_window` |
| 2-2 | `/dev/video2` | 92 | clean | `PASS: clean` | `no_death_in_window` |

No `xhci_hc_died`, no `event condition 198`, no `Command timeout` /
`Stop Endpoint timeout` on either Kiyo. Pure stream-mmap teardown
on Intel does not reproduce HC death within the 5-minute window per
Kiyo, even with a stock kernel + stock uvcvideo + no quirks (Test 1
spec from Michal Pecio's 2026-04-13 walk-through).

Combined with hammerint on Intel (2026-04-29, 60s × 2 Kiyos clean
with NO_LPM active), two independent reproducer styles agree that
Intel xHCI tolerates the Kiyo firmware bug where ASMedia dies. The
intervention CTRL_THROTTLE makes operates on the **trigger** path
(rapid SET_CUR overflow); the Intel xHCI's resilience is on the
**cascade** path (stop-endpoint timeout escalation to HC death).
Both paths are real; Test 1 + Test B together confirm the trigger-
vs-cascade split.

Forensics: `kernel-patches/matrix/michal-tests/results/streamloop-20260503T221219Z/`.

### Note on stream-loop.sh format-must-be-set bug

An earlier revision of `stream-loop.sh` did not set the pixel format
on each v4l2-ctl invocation. Without an explicit `--set-fmt-video`,
the Kiyo Pro driver returns `VIDIOC_REQBUFS = -EINVAL` and the loop
spins on REQBUFS failures (~233 failures/sec) instead of streaming.
The script's verdict-grep on `dmesg.post` still ran, but no actual
streaming was being measured — equivalent to the
`v4l2-stream-loop-trimmed-20260413-071034.log` shape (`vb2_core_reqbufs+0x1e6/0x540`
WARN). Fixed 2026-05-03 by adding `--set-fmt-video=width=$WIDTH,height=$HEIGHT,pixelformat=$PIXFMT --set-parm=$FPS`
to every invocation; format/fps overridable via `WIDTH`, `HEIGHT`,
`PIXFMT`, `FPS` env vars (defaults 1920x1080 MJPG @ 30fps).

## Conclusions for Upstream Report

1. **Power management quirks alone are insufficient.** The crash can be
   triggered purely through rapid UVC control transfers with the device fully
   active and LPM disabled.

2. **The firmware cannot handle rapid SET_CUR requests.** The device's
   endpoint stalls under control transfer load, and the resulting
   stop-endpoint timeout cascades to full controller death.

3. **The firmware has a USB descriptor spec violation.** EP5 IN declares
   `wBytesPerInterval = 8` but `wMaxPacketSize = 64`. The xHCI driver
   derives `max_esit_payload` from `wBytesPerInterval`, under-allocating
   bandwidth. This is the root cause of the spurious SHORT_PACKET event
   flood seen in Test 1.

4. **Michal Pecio's xhci patch (max_esit_payload clamp) allows HC to
   survive firmware lockup.** Test 2 proved the HC can handle firmware
   errors gracefully when bandwidth is correctly allocated.

5. **The proposed kernel patches are still needed** for preventing the
   firmware lockup in the first place. The xhci fix handles the consequence
   (HC death); the UVC patches prevent the cause (firmware overwhelm).
