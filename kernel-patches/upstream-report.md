# Razer Kiyo Pro (1532:0e05): Rapid UVC control transfers crash xHCI host controller

**Bug:** https://bugs.launchpad.net/ubuntu/+source/linux/+bug/2061177
**Patch series:** `[PATCH 0/3] USB/UVC: Prevent Razer Kiyo Pro from crashing xHCI host controller`
**Submitted to:** linux-usb@vger.kernel.org, linux-media@vger.kernel.org
**Author:** JP Hein <jp@jphein.com>

---

## Summary

The Razer Kiyo Pro USB 3.0 webcam (1532:0e05, firmware 8.21) has a firmware
bug that causes it to stop responding to USB control transfers after
receiving rapid consecutive UVC SET_CUR requests. When the device becomes
unresponsive, the xHCI driver's stop-endpoint command times out, causing
the host controller to be declared dead. This disconnects **every USB
device** on the controller — keyboards, mice, and all other peripherals —
requiring a hard reboot or automated xHCI controller rebind to recover.

The crash is reliably reproducible with a stress test that sends sustained
rapid v4l2 control changes (several hundred over a few seconds). It occurs
during normal use when applications (video conferencing software, OBS,
v4l2-ctl) adjust camera controls in rapid succession.

## Hardware

| Component | Detail |
|-----------|--------|
| Webcam | Razer Kiyo Pro (1532:0e05), firmware version 8.21 |
| Host controller | Intel Cannon Lake PCH USB 3.1 xHCI (8086:a36d) |
| PCI address | 0000:00:14.0 |
| Kernel | 6.8.0-106-generic (Ubuntu 24.04) |
| Architecture | x86_64 |

## Crash Log

Typical `dmesg` output during a crash:

```
[  xxx] uvcvideo 2-3:1.0: Failed to query (SET_CUR) UVC control 6 on unit 2: -32 (exp. 2).
[  xxx] uvcvideo 2-3:1.0: Failed to query (SET_CUR) UVC control 3 on unit 2: -32 (exp. 4).
[  xxx] uvcvideo 2-3:1.0: Failed to query (SET_CUR) UVC control 8 on unit 2: -32 (exp. 2).
[  xxx] xhci_hcd 0000:00:14.0: xHCI host not responding to stop endpoint command
[  xxx] xhci_hcd 0000:00:14.0: xHCI host controller not responding, assume dead
[  xxx] xhci_hcd 0000:00:14.0: HC died; cleaning up
[  xxx] usb 2-3: USB disconnect, device number 5
[  xxx] usb 1-9: USB disconnect, device number 3
[  xxx] usb 1-7: USB disconnect, device number 2
[  xxx] usb 1-5: USB disconnect, device number 4
```

The `-32` errors are EPIPE (USB STALL). After several STALLs in quick
succession, the device firmware locks up entirely, the xHCI stop-endpoint
command times out, and the controller is declared dead.

## Root Cause Analysis

The crash follows a specific chain through the kernel:

### 1. Rapid SET_CUR overwhelms device firmware

Userspace issues rapid `VIDIOC_S_CTRL` / `VIDIOC_S_EXT_CTRLS` ioctls.
Each goes through:

```
v4l2 ioctl → uvc_ctrl_begin() [acquires chain->ctrl_mutex]
           → uvc_ctrl_set()   [marks control dirty]
           → uvc_ctrl_commit()
             → uvc_query_ctrl(UVC_SET_CUR)
               → __uvc_query_ctrl()
                 → usb_control_msg()  [synchronous USB transfer]
           → mutex_unlock()
```

The `chain->ctrl_mutex` serializes concurrent callers but imposes **no
cooldown** between sequential operations. A tight loop can fire SET_CUR
requests as fast as USB can process them.

### 2. EPIPE triggers error amplification

When the device STALLs a SET_CUR, `uvc_query_ctrl()` (uvc_video.c:71)
immediately sends a **second** USB control transfer — a GET_CUR to
`UVC_VC_REQUEST_ERROR_CODE_CONTROL` — to read the UVC error code. On a
device whose firmware is already struggling, this second transfer amplifies
the problem:

```c
/* uvc_video.c:104-126 — after receiving EPIPE: */
ret = __uvc_query_ctrl(dev, UVC_GET_CUR, 0, intfnum,
           UVC_VC_REQUEST_ERROR_CODE_CONTROL, data, 1,
           UVC_CTRL_CONTROL_TIMEOUT);  /* another 5000ms timeout */
```

The pattern under rapid fire becomes:
```
SET_CUR → EPIPE → GET_CUR(error_code) → [may also fail]
SET_CUR → EPIPE → GET_CUR(error_code) → [may also fail]
SET_CUR → EPIPE → GET_CUR(error_code) → device firmware lockup
SET_CUR → device unresponsive → 5s timeout → stop-endpoint → HC died
```

### 3. xHCI cascade

When the device stops responding entirely:
1. `usb_start_wait_urb()` times out (5000ms)
2. `usb_kill_urb()` → xHCI issues Stop Endpoint command
3. Stop Endpoint command itself times out (device firmware is locked)
4. xHCI driver calls `xhci_hc_died()` — controller declared dead
5. All URBs on all endpoints fail, all devices on the controller disconnect

### 4. No existing protection

The UVC driver has **no rate limiting** for control transfers:
- No `ktime_t` tracking between SET_CUR operations
- No backoff after EPIPE errors
- No consecutive failure counter
- No per-device throttling mechanism

The only related mechanism in the kernel is `USB_QUIRK_DELAY_CTRL_MSG`
(200ms fixed delay after every `usb_control_msg()`), which is too coarse
for this use case.

## Reproduction

### Stress test script

The following script reliably crashes the device around round 25 of 50:

```bash
#!/bin/bash
DEV=/dev/video0
ROUNDS=${1:-50}

for i in $(seq 1 $ROUNDS); do
    # Focus: disable auto, set manual, re-enable auto
    v4l2-ctl -d $DEV --set-ctrl=focus_automatic_continuous=0
    v4l2-ctl -d $DEV --set-ctrl=focus_absolute=300
    v4l2-ctl -d $DEV --set-ctrl=focus_automatic_continuous=1

    # White balance: slam between extremes
    v4l2-ctl -d $DEV --set-ctrl=white_balance_automatic=0
    v4l2-ctl -d $DEV --set-ctrl=white_balance_temperature=2000
    v4l2-ctl -d $DEV --set-ctrl=white_balance_temperature=7500
    v4l2-ctl -d $DEV --set-ctrl=white_balance_automatic=1

    # Exposure: slam between extremes
    v4l2-ctl -d $DEV --set-ctrl=auto_exposure=1
    v4l2-ctl -d $DEV --set-ctrl=exposure_time_absolute=3
    v4l2-ctl -d $DEV --set-ctrl=exposure_time_absolute=2047
    v4l2-ctl -d $DEV --set-ctrl=auto_exposure=3

    # Pan/tilt/zoom
    v4l2-ctl -d $DEV --set-ctrl=zoom_absolute=400
    v4l2-ctl -d $DEV --set-ctrl=pan_absolute=-36000
    v4l2-ctl -d $DEV --set-ctrl=tilt_absolute=36000
    v4l2-ctl -d $DEV --set-ctrl=zoom_absolute=100
    v4l2-ctl -d $DEV --set-ctrl=pan_absolute=0
    v4l2-ctl -d $DEV --set-ctrl=tilt_absolute=0

    # Brightness/contrast/saturation cycling
    for val in 0 255 128; do
        v4l2-ctl -d $DEV --set-ctrl=brightness=$val
        v4l2-ctl -d $DEV --set-ctrl=contrast=$val
        v4l2-ctl -d $DEV --set-ctrl=saturation=$val
    done

    sleep 0.2
done
```

Each round issues ~25 SET_CUR transfers. With 0.2s between rounds, the
effective rate is well over 100 control transfers per second. The device
firmware crashes consistently around round 25 (several hundred total
SET_CUR transfers over a few seconds of sustained rapid load).

### Prerequisites for reproduction

1. Razer Kiyo Pro (1532:0e05) connected via USB 3.0
2. `v4l2-ctl` installed (`apt install v4l-utils`)
3. SSH access recommended for recovery after USB bus dies
4. Monitor kernel log in parallel: `journalctl -k -f | grep -i 'xhci\|uvc\|error'`

## Mitigations Tested (Insufficient)

The following runtime mitigations were tested individually and in
combination. **None prevented the crash under the stress test.**

### USB_QUIRK_NO_LPM (sysfs runtime test)

```bash
echo 0 > /sys/bus/usb/devices/2-3/power/usb3_lpm_permit
```

Disables USB 3.0 Link Power Management U1/U2 transitions. LPM may
contribute to crashes during normal idle-to-active transitions, but the
stress test crashes the device with LPM already disabled. Note: the sysfs
knob may be read-only on some hardware; the compiled `USB_QUIRK_NO_LPM`
kernel quirk is needed for full LPM disable at enumeration time.

### UVC_QUIRK_DISABLE_AUTOSUSPEND (sysfs runtime test)

```bash
echo on > /sys/bus/usb/devices/2-3/power/control
```

Prevents USB autosuspend, keeping the device permanently active. This
addresses the common-case trigger where idle-to-resume transitions
destabilize the endpoint, but does not prevent crashes from rapid control
transfers while the device is already active.

### avoid_reset_quirk (sysfs)

```bash
echo 1 > /sys/bus/usb/devices/2-3/avoid_reset_quirk
```

Prevents USB core from issuing device resets during error recovery. This
avoids the fragile reset-resume path but does not prevent the initial
endpoint stall from rapid SET_CUR.

### Combined udev rule

All three applied via persistent udev rule — crash still occurs:

```
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="1532", ATTR{idProduct}=="0e05", \
  ATTR{avoid_reset_quirk}="1", \
  ATTR{power/control}="on", \
  ATTR{power/usb3_lpm_permit}="0"
```

### USB_QUIRK_DELAY_CTRL_MSG (proxy test — DOES prevent crash)

```bash
echo "1532:0e05:n" > /sys/module/usbcore/parameters/quirks
```

This inserts a 200ms `msleep()` after every `usb_control_msg()` to the
device. With this quirk active, the stress test completes **500+ rounds
without a single crash**. This confirms that rate limiting control
transfers is sufficient to prevent the firmware lockup.

However, `USB_QUIRK_DELAY_CTRL_MSG` is too coarse:
- It affects ALL USB control messages to the device, not just UVC SET_CUR
- The fixed 200ms delay is unnecessarily conservative
- It penalizes enumeration, configuration, and non-problematic operations

## Proposed Fix: Patch Series

### [PATCH 1/3] USB: core: add NO_LPM quirk for Razer Kiyo Pro webcam

Adds `USB_QUIRK_NO_LPM` for 1532:0e05 in `drivers/usb/core/quirks.c`.
Prevents USB Link Power Management transitions that can destabilize the
device firmware during idle-to-active power state changes. This addresses
the most common real-world trigger.

### [PATCH 2/3] media: uvcvideo: add UVC_QUIRK_CTRL_THROTTLE for fragile firmware

Introduces `UVC_QUIRK_CTRL_THROTTLE` (0x00080000) with two protections:

**Rate limiting:** Enforces a minimum 50ms interval between SET_CUR
control transfers when the quirk is set. This limits the effective rate to
20 control changes per second, which is sufficient for interactive use
(slider adjustments, application control panels) while preventing the
rapid-fire pattern that overwhelms the firmware.

Implementation in `uvc_query_ctrl()` (uvc_video.c):
```c
if (query == UVC_SET_CUR && (dev->quirks & UVC_QUIRK_CTRL_THROTTLE)) {
    min_interval = msecs_to_jiffies(50);
    if (dev->last_ctrl_set_jiffies &&
        time_before(jiffies, dev->last_ctrl_set_jiffies + min_interval)) {
        elapsed = dev->last_ctrl_set_jiffies + min_interval - jiffies;
        msleep(jiffies_to_msecs(elapsed));
    }
}
```

A new `unsigned long last_ctrl_set_jiffies` field is added to
`struct uvc_device` to track the timestamp of the last SET_CUR.

**Error amplification suppression:** When a SET_CUR returns EPIPE, the
driver normally sends a second USB transfer (GET_CUR to
`UVC_VC_REQUEST_ERROR_CODE_CONTROL`) to read the UVC error code. On a
device that is already stalling, this second transfer can push the firmware
into a full lockup. With this quirk, EPIPE is returned directly:

```c
if (dev->quirks & UVC_QUIRK_CTRL_THROTTLE)
    return -EPIPE;
```

### [PATCH 3/3] media: uvcvideo: add quirks for Razer Kiyo Pro webcam

Adds a device entry in `uvc_ids[]` for the Razer Kiyo Pro (1532:0e05)
with all three UVC quirks combined:
- `UVC_QUIRK_CTRL_THROTTLE` — rate-limits SET_CUR and skips error-code
  queries after EPIPE (the primary crash prevention from patch 2)
- `UVC_QUIRK_DISABLE_AUTOSUSPEND` — prevents autosuspend transitions that
  destabilize the firmware (same approach as Insta360 Link)
- `UVC_QUIRK_NO_RESET_RESUME` — avoids the fragile reset-during-resume
  path (same approach as Logitech Rally Bar)

## Test Results

| Condition | Stress test rounds before crash |
|-----------|--------------------------------|
| No quirks (stock kernel) | ~25 |
| NO_LPM only (sysfs) | ~25 |
| DISABLE_AUTOSUSPEND only (sysfs) | ~25 |
| avoid_reset_quirk only (sysfs) | ~25 |
| All three combined (udev rule) | ~25 |
| USB_QUIRK_DELAY_CTRL_MSG (200ms) | 500+ (no crash) |
| UVC_QUIRK_CTRL_THROTTLE (50ms, patch 2) | 500+ (no crash) |

The 50ms throttle (patch 2) prevents the crash while being 4x less
conservative than `USB_QUIRK_DELAY_CTRL_MSG` and scoped specifically to
UVC SET_CUR operations.

## Impact

This bug affects any Linux user with a Razer Kiyo Pro webcam. The crash
can be triggered by:
- Video conferencing software adjusting camera controls during a call
- OBS Studio or similar software applying scene-specific camera settings
- Any application or script that changes multiple camera controls in
  quick succession
- The v4l2-ctl utility when scripted for automated adjustments

The crash disconnects the entire USB bus, not just the camera. On a
desktop system, this means loss of keyboard and mouse input with no way
to recover without either a hard reboot or an automated watchdog service
that rebinds the xHCI controller.

The Razer Kiyo Pro is not currently in the UVC device table (`uvc_ids[]`)
or the USB core quirks table (`usb_quirk_list[]`). It matches only the
generic UVC interface class entries.

## Related Work

- Ubuntu Bug #2061177: https://bugs.launchpad.net/ubuntu/+source/linux/+bug/2061177
- Corsair Strafe `USB_QUIRK_DELAY_CTRL_MSG` — same concept (control message
  delay) but applied at USB core level with fixed 200ms delay
- Logitech Rally Bar `UVC_QUIRK_NO_RESET_RESUME` — same pattern for
  preventing resume-path crashes in UVC webcams
- Insta360 Link `UVC_QUIRK_DISABLE_AUTOSUSPEND` — same pattern for
  preventing autosuspend-related firmware instability
- Elgato Cam Link 4K reset-on-EPROTO (uvc_video.c:2216) — related but
  different approach: issues `usb_reset_device()` on streaming errors

## Files Changed

```
drivers/usb/core/quirks.c           |  2 ++                    (patch 1)
drivers/media/usb/uvc/uvc_video.c   | 33 +++++++++++++++++++++++++++++++++  (patch 2)
drivers/media/usb/uvc/uvcvideo.h    |  3 +++                  (patch 2)
drivers/media/usb/uvc/uvc_driver.c  | 17 +++++++++++++++++  (patch 3)
4 files changed, 55 insertions(+)
```
