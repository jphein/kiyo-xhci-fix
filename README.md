# kiyo-xhci-fix

Linux kernel patches and userspace watchdog for the **Razer Kiyo Pro (1532:0e05)** USB crash bug.

## The Problem

The Razer Kiyo Pro's firmware (v8.21) crashes when it receives rapid UVC `SET_CUR` control transfers while USB Link Power Management (LPM) is active. This triggers a cascade failure on the Intel xHCI controller (Cannon Lake PCH, 8086:a36d) that disconnects **all** USB devices on the bus — keyboard, mouse, everything.

The kernel's built-in xHCI error recovery makes it worse: it detects the fault, resets the controller, the reset triggers another fault, and the system enters a death spiral requiring a hard reboot.

**Affected:** Linux 6.8+ (tested on Ubuntu 24.04), Intel xHCI controllers, Razer Kiyo Pro firmware 8.21.

## The Fix

Three layers, any of which prevents the crash independently:

### 1. Kernel Patches (upstream submissions)

- **`0001`** — `USB_QUIRK_NO_LPM` for 1532:0e05 — disables Link Power Management, preventing the firmware bug from triggering
- **`0002`** — UVC quirks (`UVC_QUIRK_PROBE_MINMAX`, `UVC_QUIRK_FIX_BANDWIDTH`) — safer format negotiation
- **`0003`** — UVC control throttle quirk — rate-limits `SET_CUR` transfers to prevent firmware overload

See [`kernel-patches/upstream-report.md`](kernel-patches/upstream-report.md) for the full bug analysis submitted to `linux-usb@vger.kernel.org`.

### 2. Userspace Watchdog (`usb-watchdog.sh`)

A systemd user service that monitors `journalctl -k` for xHCI fatal errors and performs single-pass recovery:

- **Level 1:** Rebind the Kiyo's USB port
- **Level 2:** Full xHCI controller PCI unbind/bind
- **Level 3:** Full xHCI driver reload (modprobe)

If all levels fail, the watchdog **stops** — no retry loops, no death spirals. A wedged controller needs a reboot.

### 3. Quick Fix (no reboot, no patches)

```bash
# Disable LPM for the Kiyo at runtime
echo "1532:0e05:n" | sudo tee /sys/module/usbcore/parameters/quirks

# Make it permanent
echo 'options usbcore quirks=1532:0e05:n' | sudo tee /etc/modprobe.d/razer-kiyo-usb.conf
sudo update-initramfs -u
```

## Install

```bash
# Install the watchdog service
bash kernel-patches/install-watchdog.sh

# Test with the stress test (reproduces the crash without the quirk)
bash kernel-patches/stress-test-kiyo.sh 50
```

## Files

| File | Purpose |
|------|---------|
| `usb-watchdog.sh` | Watchdog daemon — monitors kernel log, escalates recovery |
| `usb-watchdog.service` | systemd user service unit |
| `usb-watchdog-sudoers` | Targeted sudoers rules for watchdog |
| `reset-camera.sh` | One-shot manual recovery script |
| `fix-kiyo-pro.sh` | All-in-one fix installer (quirk + udev + WirePlumber) |
| `kernel-patches/*.patch` | Kernel patches for upstream submission |
| `kernel-patches/stress-test-kiyo.sh` | Crash reproducer / validation tool |
| `kernel-patches/upstream-report.md` | Full bug report for linux-usb mailing list |
| `kernel-patches/research-*.md` | Root cause analysis notes |

## Hardware

- **Webcam:** Razer Kiyo Pro (1532:0e05, firmware 8.21)
- **Controller:** Intel Cannon Lake PCH xHCI (8086:a36d) at PCI 0000:00:14.0
- **Kernel:** 6.8.0-106-generic (Ubuntu 24.04)

## License

MIT
