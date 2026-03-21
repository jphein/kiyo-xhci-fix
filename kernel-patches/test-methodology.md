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
sudo bash ~/Projects/scripts/kernel-patches/apply-and-test.sh   # apply quirks
bash ~/Projects/scripts/kernel-patches/stress-test-kiyo.sh 50   # run test
```

Record: round number at crash, full dmesg output, quirks in effect.

### Watchdog Recovery Test

```bash
bash ~/Projects/scripts/kernel-patches/test-watchdog.sh
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

## Conclusions for Upstream Report

1. **Power management quirks alone are insufficient.** The crash can be
   triggered purely through rapid UVC control transfers with the device fully
   active and LPM disabled.

2. **The firmware cannot handle rapid SET_CUR requests.** The device's
   endpoint stalls under control transfer load, and the resulting
   stop-endpoint timeout cascades to full controller death.

3. **The proposed kernel patches (NO_LPM + DISABLE_AUTOSUSPEND +
   NO_RESET_RESUME) address the common-case trigger** — where idle-to-active
   transitions destabilize the device. They do not address the stress-test
   scenario, which requires either UVC driver-level rate limiting of control
   transfers or a device firmware fix.

4. **The patches are still worth submitting** because the vast majority of
   real-world crashes occur through the power management path, not through
   rapid control hammering. The stress test is a synthetic worst case that
   exposes the underlying firmware bug.
