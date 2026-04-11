# kiyo-xhci-fix

Linux kernel patches and userspace watchdog for the **Razer Kiyo Pro (1532:0e05)** USB crash bug.

## The Problem

The Razer Kiyo Pro's firmware (v1.5.0.1) has two failure modes that cascade into complete xHCI host controller death, disconnecting **all** USB devices on the bus — keyboard, mouse, everything — requiring a hard reboot.

1. **LPM/autosuspend resume:** The device fails to reinitialize after USB Link Power Management transitions, producing EPIPE (-32) on UVC SET_CUR. The stalled endpoint triggers an xHCI stop-endpoint timeout, and the kernel declares the controller dead.

2. **Rapid control transfers:** ~25 rapid consecutive UVC SET_CUR operations overwhelm the firmware, causing endpoint stalls that cascade into host controller death.

3. **USB descriptor spec violation:** EP5 IN (interrupt) declares `wBytesPerInterval = 8` but `wMaxPacketSize = 64`. The xHCI driver under-allocates bandwidth based on this, leading to spurious SHORT_PACKET completion events that can flood the host controller.

The kernel's built-in xHCI error recovery makes it worse: it detects the fault, resets the controller, the reset triggers another fault, and the system enters a death spiral.

**Important:** Testing shows NO_LPM alone is insufficient — a stress test with NO_LPM active caused delayed controller death 13 minutes later via TRB warning escalation. Both LPM prevention and control throttling are needed.

**Affected:** Linux 6.8+ (tested on Ubuntu 24.04), Intel xHCI controllers, Razer Kiyo Pro firmware 1.5.0.1 (bcdDevice 8.21).

## The Fix

Three kernel patches, all necessary:

### 1. Kernel Patches (upstream submissions)

- **`0001`** — `USB_QUIRK_NO_LPM` for 1532:0e05 — disables Link Power Management to prevent firmware destabilization during power state transitions
- **`0002`** — `UVC_QUIRK_CTRL_THROTTLE` — new UVC quirk that rate-limits all control transfers (50ms interval) in `__uvc_query_ctrl()`
- **`0003`** — Razer Kiyo Pro device entry with `UVC_QUIRK_CTRL_THROTTLE | UVC_QUIRK_DISABLE_AUTOSUSPEND | UVC_QUIRK_NO_RESET_RESUME`, plus full `lsusb -v` in commit message documenting the wBytesPerInterval spec violation

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
# Then replug the camera (or unbind/rebind the USB port)
```

Note: The runtime quirk only applies to devices enumerated **after** it's set. This only addresses crash trigger #1 (LPM). For full protection against rapid control transfer crashes, the CTRL_THROTTLE patch (via DKMS) is also needed.

## Full Install (recommended)

Three components are needed for a complete fix before all patches are merged upstream:

1. **modprobe.d config** — covers patch 1 (NO_LPM) via `usbcore quirks=` parameter, since patch 1 modifies `usb/core/quirks.c` and can't be built via DKMS. Must be in initramfs so LPM is disabled before device enumeration.
2. **udev rule** — disables autosuspend at plug time to complement the modprobe.d config.
3. **DKMS module** — patches 2-3 (CTRL_THROTTLE + device quirks) as an out-of-tree uvcvideo module.

All three are required. The DKMS module alone won't prevent LPM-triggered stalls, and the usbcore quirk alone won't prevent rapid control transfer crashes.

> **Secure Boot note:** DKMS modules are unsigned. If Secure Boot is enabled, you must either enroll a MOK signing key (with `CA:TRUE` — non-CA certs land in the `.platform` keyring which the kernel ignores for module verification) or disable Secure Boot.

### Step 1: Disable LPM (covers patch 1 — USB_QUIRK_NO_LPM)

LPM must be disabled at the USB core level **before** the device enumerates. A udev rule fires too late — the `usb3_hardware_lpm_u1/u2` sysfs attributes are read-only at runtime.

**Important:** On most distro kernels, `usbcore` is built-in (not a loadable module), so `modprobe.d` options are ignored. You must pass the quirk via the **kernel command line** instead.

```bash
# Add to kernel command line (GRUB)
sudo sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 usbcore.quirks=1532:0e05:k"/' /etc/default/grub
sudo update-grub

# Or for systemd-boot:
# Append usbcore.quirks=1532:0e05:k to your entry's options line
```

A `modprobe.d` config (`razer-kiyo-usb.conf`) is also included as a fallback for kernels where usbcore is a loadable module.

This takes effect on next reboot. To verify after reboot:
```bash
cat /proc/cmdline | grep -o 'usbcore.quirks=[^ ]*'   # should show usbcore.quirks=1532:0e05:k
# Verify LPM files are absent for Kiyo ports (quirk prevents LPM negotiation entirely):
ls /sys/bus/usb/devices/2-*/power/usb3_hardware_lpm_u1 2>&1  # should show "No such file"
```

### Step 2: udev rule (autosuspend + reset quirk)

```bash
sudo cp 99-razer-kiyo-pro.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules
```

Remove the GRUB parameter, modprobe.d config, and udev rule once patch 1 ships in your running kernel (check: `grep -r "1532.*0e05" /lib/modules/$(uname -r)/kernel/drivers/usb/core/`).

### Step 3: DKMS module (covers patches 2-3)

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
| `razer-kiyo-usb.conf` | modprobe.d config — `usbcore quirks=1532:0e05:k` disables LPM (covers patch 1) |
| `99-razer-kiyo-pro.rules` | udev rule — disables autosuspend at plug time |
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
| `kernel-patches/capture-crash.sh` | dmesg capture script for crash reproduction |
| `kernel-patches/michal-xhci-test.patch` | Michal Pecio's xhci test patch (max_esit_payload clamp + short packet retry) |
| `kernel-patches/crash-evidence/` | Kernel logs from real crash events |
| `firmware-analysis/README.md` | Firmware analysis — UVC XU protocol, normal-mode flash, ROM boot, SCSI protocol |
| `firmware-analysis/kiyo-flash.py` | Linux firmware tool — normal-mode flash, ROM boot, probe, u-boot shell |
| `firmware-analysis/usbmon-capture.md` | USB protocol capture setup and analysis guide |
| `firmware-analysis/capture-flash.sh` | usbmon capture script for flash protocol analysis |
| `firmware-analysis/parse-usbmon.sh` | usbmon output parser for flash protocol verification |

## Hardware

- **Webcam:** Razer Kiyo Pro (1532:0e05, firmware 1.5.0.1 / bcdDevice 8.21) — reproduced on two separate units running simultaneously, confirming the bug is not unit-specific
- **SoC:** Sigmastar SAV630D (ARM Cortex-A53 vision ISP, PSA Certified Level 1)
- **Image sensor:** Sony IMX327 (2MP, 1/2.8", starlight)
- **SPI flash:** Winbond W25N01GVZEIG (1Gbit SPI NAND)
- **Camera module vendor:** AIT (Alpha Imaging Technology → MStar → SigmaStar → MediaTek lineage)
- **Controller:** Intel Cannon Lake PCH xHCI (8086:a36d) at PCI 0000:00:14.0
- **Kernel:** Tested on 6.8.0-106-generic, 6.17.0-19/20-generic (Ubuntu 24.04 + HWE), and custom 6.17.0-xhci-test (Michal Pecio's xhci patch)

## Firmware Root Cause

The camera's firmware (Sigmastar SAV630D, built by AIT) has a **USB descriptor spec violation**: the SuperSpeed Endpoint Companion Descriptor for EP5 IN (interrupt) declares `wBytesPerInterval = 8` when it should be `64` (matching `wMaxPacketSize`). This causes the xHCI driver to allocate insufficient bandwidth for the endpoint, contributing to spurious completion events that can cascade into host controller death.

The bug byte is at offset `0x1F570A` in the raw firmware image (`fwimage.bin`) and at offset `0xa1845d` in the .NET ResourceSet (`DeviceUpdater.resources`).

A Linux firmware tool ([`firmware-analysis/kiyo-flash.py`](firmware-analysis/kiyo-flash.py)) implements the reverse-engineered UVC Extension Unit protocol — the same protocol used by the official Windows updater. The tool sends firmware in 32-byte chunks through XU6 selector 3, using raw USB control transfers to bypass the Linux UVC driver's descriptor validation (sel=3 is marked GET-only but the device accepts SET_CUR). ROM boot mode recovery via SCSI is also implemented as a fallback.

**Flash status (2026-04-11):** After extensive testing (6+ attempts with progressive bug fixes), the normal-mode UVC XU flash path does NOT persist firmware on this device. The device accepts data and reports burn-complete (status 0x82) but wBytesPerInterval remains 8 after power cycle. The soft ROM boot entry path is also locked out in production firmware. A firmware-level fix would require either hardware ROM boot (grounding the SoC boot pin) or a Windows VM with USB passthrough to test the official updater. See [`firmware-analysis/README.md`](firmware-analysis/README.md) for the full protocol documentation and findings.

## Upstream Status

- **Patch 1** (`USB_QUIRK_NO_LPM`): **Merged** into `usb-linus` by Greg Kroah-Hartman. Backported to stable kernels 6.1, 6.6, 6.12, 6.18, and 6.19 as of 2026-04-09.
- **Patches 2-3** (`UVC_QUIRK_CTRL_THROTTLE` + device entry): Submitted to linux-media, under review by Ricardo Ribalda. v7 sent 2026-04-09 — throttle-only (dropped error-code skip per Ricardo), full `lsusb -v` in commit message per Ricardo.
- **Thread Message-ID:** `<20260331003806.212565-1-jp@jphein.com>`
- **v7 Message-ID:** `<20260410002720.1033303-1-jp@jphein.com>`

### Key Upstream Discussion

- **Mathias Nyman (Intel xHCI maintainer):** Dual-URB cancellation on control EP leaves dequeue on no-op TRB, violating xHCI spec 4.8.3. Disabling LPM reduces control transfers, lowering the dual-cancel risk.
- **Michal Pecio:** Identified wBytesPerInterval=8 as a spec violation; xHCI driver's max_esit_payload derived from it. His test patch (clamp max_esit_payload + short packet retry) allowed HC to survive firmware lockup. Latest (2026-04-11): asked Mathias about Intel vendor-defined error code 198 from Test 2 logs — ball is with Mathias, no action needed from JP.
- **Test results (2026-04-10):** Two crash reproduction tests on kernel 6.17.0-xhci-test with Michal's xhci patch:
  - **Test 1** (all fixes + Michal's patch): HC DIED — 437 repeated cancel/resubmit on EP5 IN → ~994K spurious SHORT_PACKET events → control URB timeouts → hc_died
  - **Test 2** (Michal's patch only, no JP patches): HC SURVIVED — firmware locked at round ~23 but host controller handled errors gracefully

## License

GPL-3.0-or-later
