# kiyo-xhci-fix

Linux kernel patches and userspace watchdog for the **Razer Kiyo Pro (1532:0e05)** USB crash bug.

## The Problem

The Razer Kiyo Pro's firmware (v8.21) has two failure modes that cascade into complete xHCI host controller death, disconnecting **all** USB devices on the bus — keyboard, mouse, everything — requiring a hard reboot.

1. **LPM/autosuspend resume:** The device fails to reinitialize after USB Link Power Management transitions, producing EPIPE (-32) on UVC SET_CUR. The stalled endpoint triggers an xHCI stop-endpoint timeout, and the kernel declares the controller dead.

2. **Rapid control transfers:** ~25 rapid consecutive UVC SET_CUR operations overwhelm the firmware. The standard UVC error-code query (GET_CUR after EPIPE) amplifies the failure by sending a second transfer to the already-stalling device.

The kernel's built-in xHCI error recovery makes it worse: it detects the fault, resets the controller, the reset triggers another fault, and the system enters a death spiral.

**Important:** Testing shows NO_LPM alone is insufficient — a stress test with NO_LPM active caused delayed controller death 13 minutes later via TRB warning escalation. Both LPM prevention and control throttling are needed.

**Affected:** Linux 6.8+ (tested on Ubuntu 24.04), Intel xHCI controllers, Razer Kiyo Pro firmware 8.21.

## The Fix

Three kernel patches, all necessary:

### 1. Kernel Patches (upstream submissions)

- **`0001`** — `USB_QUIRK_NO_LPM` for 1532:0e05 — disables Link Power Management to prevent firmware destabilization during power state transitions
- **`0002`** — `UVC_QUIRK_CTRL_THROTTLE` — new UVC quirk that rate-limits SET_CUR transfers (50ms interval) and skips error-code queries after EPIPE to prevent crash amplification
- **`0003`** — Razer Kiyo Pro device entry with `UVC_QUIRK_CTRL_THROTTLE | UVC_QUIRK_DISABLE_AUTOSUSPEND | UVC_QUIRK_NO_RESET_RESUME`

See [`kernel-patches/upstream-report.md`](kernel-patches/upstream-report.md) for the full bug analysis submitted to `linux-usb@vger.kernel.org`.

### 2. Userspace Watchdog (`usb-watchdog.sh`)

A systemd user service that monitors `journalctl -k` for xHCI fatal errors and performs single-pass recovery:

- **Level 1:** Rebind the Kiyo's USB port
- **Level 2:** Full xHCI controller PCI unbind/bind
- **Level 3:** Full xHCI driver reload (modprobe)

If all levels fail, the watchdog **stops** — no retry loops, no death spirals. A wedged controller needs a reboot.

### 3. Quick Fix (no reboot, no patches)

```bash
# Disable LPM for the Kiyo at runtime (k = USB_QUIRK_NO_LPM)
echo "1532:0e05:k" | sudo tee /sys/module/usbcore/parameters/quirks

# Make it permanent
echo 'options usbcore quirks=1532:0e05:k' | sudo tee /etc/modprobe.d/razer-kiyo-usb.conf
sudo update-initramfs -u
```

Note: This only addresses crash trigger #1 (LPM). For full protection against rapid control transfer crashes, the CTRL_THROTTLE patch is also needed.

## DKMS Install (recommended)

Builds the patched uvcvideo module automatically on every kernel upgrade:

```bash
# Copy patched source to DKMS directory
sudo mkdir -p /usr/src/uvcvideo-kiyo-1.0/drivers/media/usb/uvc

# Download UVC source matching your kernel and apply patches
KVER=$(uname -r | sed 's/-.*//')
for f in uvc_driver.c uvc_video.c uvc_ctrl.c uvc_queue.c uvc_isight.c \
         uvc_v4l2.c uvc_status.c uvc_entity.c uvc_metadata.c \
         uvc_debugfs.c uvcvideo.h; do
    sudo curl -sL "https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/plain/drivers/media/usb/uvc/$f?h=v$KVER" \
        -o /usr/src/uvcvideo-kiyo-1.0/drivers/media/usb/uvc/$f
done

# Apply CTRL_THROTTLE patches
cd /usr/src/uvcvideo-kiyo-1.0
sudo git init && sudo git add . && sudo git commit -m "stock"
sudo git apply /path/to/kiyo-xhci-fix/kernel-patches/0002-*.patch
sudo git apply /path/to/kiyo-xhci-fix/kernel-patches/0003-*.patch

# Create DKMS config
sudo tee dkms.conf << 'EOF'
PACKAGE_NAME="uvcvideo-kiyo"
PACKAGE_VERSION="1.0"
BUILT_MODULE_NAME[0]="uvcvideo"
DEST_MODULE_LOCATION[0]="/updates"
AUTOINSTALL="yes"
CLEAN="make clean"
MAKE[0]="make -C ${kernel_source_dir} M=${dkms_tree}/${PACKAGE_NAME}/${PACKAGE_VERSION}/build modules"
EOF

# Create Makefile
sudo tee Makefile << 'EOF'
KDIR := /lib/modules/$(shell uname -r)/build
obj-m := uvcvideo.o
uvcvideo-objs := drivers/media/usb/uvc/uvc_driver.o drivers/media/usb/uvc/uvc_queue.o \
    drivers/media/usb/uvc/uvc_v4l2.o drivers/media/usb/uvc/uvc_video.o \
    drivers/media/usb/uvc/uvc_ctrl.o drivers/media/usb/uvc/uvc_status.o \
    drivers/media/usb/uvc/uvc_isight.o drivers/media/usb/uvc/uvc_debugfs.o \
    drivers/media/usb/uvc/uvc_metadata.o drivers/media/usb/uvc/uvc_entity.o
all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules
clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean
EOF

# Register, build, install
sudo dkms add uvcvideo-kiyo/1.0
sudo dkms build uvcvideo-kiyo/1.0
sudo dkms install uvcvideo-kiyo/1.0

# Load immediately (close video apps first)
sudo rmmod uvcvideo && sudo modprobe uvcvideo
```

To remove when upstream patches land: `sudo dkms remove uvcvideo-kiyo/1.0 --all`

## Testing

```bash
# Reproduce the crash (WARNING: will kill all USB devices)
bash kernel-patches/stress-test-kiyo.sh 50

# Build and test the CTRL_THROTTLE patch in isolation
sudo bash kernel-patches/build-uvc-module.sh
sudo bash kernel-patches/test-ctrl-throttle.sh 50
```

Crash evidence from real-world failures is in [`kernel-patches/crash-evidence/`](kernel-patches/crash-evidence/).

## Install

```bash
# Install the watchdog service
bash kernel-patches/install-watchdog.sh
```

## Files

| File | Purpose |
|------|---------|
| `usb-watchdog.sh` | Watchdog daemon — monitors kernel log, escalates recovery |
| `usb-watchdog.service` | systemd user service unit |
| `usb-watchdog-sudoers` | Targeted sudoers rules for watchdog |
| `reset-camera.sh` | One-shot manual recovery script |
| `fix-kiyo-pro.sh` | All-in-one fix installer (quirk + udev + WirePlumber) |
| `kernel-patches/0000-cover-letter.txt` | Patch series cover letter |
| `kernel-patches/*.patch` | Kernel patches for upstream submission |
| `kernel-patches/send-patches.sh` | Sends patch series to linux-usb/linux-media via `git send-email` |
| `kernel-patches/uvcvideo-patched.ko` | Pre-built patched uvcvideo module (6.8.0-106-generic) |
| `kernel-patches/build-uvc-module.sh` | Builds patched uvcvideo module from kernel source |
| `kernel-patches/apply-and-test.sh` | Applies patches to kernel tree and runs build |
| `kernel-patches/test-ctrl-throttle.sh` | CTRL_THROTTLE isolation test (swaps module, removes LPM quirk) |
| `kernel-patches/test-quirks-locally.sh` | Local quirk validation without rebooting |
| `kernel-patches/test-watchdog.sh` | Watchdog service test harness |
| `kernel-patches/stress-test-kiyo.sh` | Crash reproducer / validation tool |
| `kernel-patches/install-watchdog.sh` | Installs watchdog systemd service |
| `kernel-patches/upstream-report.md` | Full bug report for linux-usb mailing list |
| `kernel-patches/test-methodology.md` | Test methodology and procedures |
| `kernel-patches/research-*.md` | Root cause analysis notes |
| `kernel-patches/crash-evidence/` | Kernel logs from real crash events |

## Hardware

- **Webcam:** Razer Kiyo Pro (1532:0e05, firmware 1.5.0.1)
- **Controller:** Intel Cannon Lake PCH xHCI (8086:a36d) at PCI 0000:00:14.0
- **Kernel:** Tested on 6.8.0-106-generic and 6.17.0-19/20-generic (Ubuntu 24.04 + HWE)

## Upstream Status

- **Patch 1** (`USB_QUIRK_NO_LPM`): **Merged** into `usb-linus` by Greg Kroah-Hartman. Will ship in the next -rc release and be backported to stable kernels.
- **Patches 2-3** (`UVC_QUIRK_CTRL_THROTTLE` + device entry): Submitted to linux-media, awaiting review.

## License

MIT
