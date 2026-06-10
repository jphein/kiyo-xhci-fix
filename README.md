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

**Confirmed cross-platform (firmware bug, not Linux-specific):** The same v4l2-ctl trigger reproduces on Linux + Raspberry Pi (ARM) + Windows + macOS, and across Intel / ASMedia / Fresco Logic / VIA / Renesas xHCI silicons with varying severity (ASMedia catastrophic, Intel tolerant per stream-mmap and hammerint tests). On Windows, uninstalling Razer Synapse — which removes the software issuing rapid UVC control bursts — restores stability, validating the throttling intervention shape from the kernel side. See [`kernel-patches/upstream-report.md` § Third-Party Reproduction Evidence](kernel-patches/upstream-report.md#third-party-reproduction-evidence) for sources.

## The Fix

Three kernel patches, all necessary:

### 1. Kernel Patches (upstream submissions)

- **`0001`** — `USB_QUIRK_NO_LPM` for 1532:0e05 — disables Link Power Management to prevent firmware destabilization during power state transitions
- **`0002`** — `UVC_QUIRK_CTRL_THROTTLE` — new UVC quirk implementing three coordinated mitigations in `__uvc_query_ctrl()`:
  - **Uniform 100ms** minimum interval between any two control transfers (prevents firmware overflow under sustained rapid traffic)
  - **Additional 200ms** before `SET_CUR` to `UVC_VS_COMMIT_CONTROL` (the operation empirically responsible for every observed crash — `Failed to set UVC commit control : -110` precedes every `HC died`)
  - **Extended 10s URB timeout** for that same `COMMIT_CONTROL` path (vs default 5s — gives the firmware twice the time to self-recover before the xHCI abort path runs, which is the cooperative half of the mitigation)
- **`0003`** — Razer Kiyo Pro device entry with `UVC_QUIRK_CTRL_THROTTLE | UVC_QUIRK_DISABLE_AUTOSUSPEND | UVC_QUIRK_NO_RESET_RESUME`, plus full `lsusb -v` in commit message documenting the wBytesPerInterval spec violation

The v5–v7 drafts used a uniform 50ms throttle; **v8.1 (2026-05-13)** revised this after a real-world WebRTC call produced 4 commit-control timeouts in 41 minutes despite the 50ms throttle being active. The synthetic SET_CUR stress test passed at 50ms but real-world probe→commit re-negotiation patterns did not, so v8.1 targets the specific failing operation (COMMIT) rather than broadening uniform throttle. See [`kernel-patches/v8-0000-cover-letter.patch`](kernel-patches/v8-0000-cover-letter.patch) and [`kernel-patches/crash-evidence/2026-05-13-v8.1-validation/RESULTS.md`](kernel-patches/crash-evidence/2026-05-13-v8.1-validation/RESULTS.md) for empirical reasoning.

See [`kernel-patches/upstream-report.md`](kernel-patches/upstream-report.md) for the full bug analysis submitted to `linux-usb@vger.kernel.org`.

### 2. Userspace Watchdog (`usb-watchdog.sh`)

A systemd user service that monitors `journalctl -k` for xHCI fatal errors and performs single-pass recovery:

- **Level 0:** Early intervention (added 2026-06-07 from the 06-06 crash analysis). On a **pre-cascade precursor** (`timeout: still N active urbs on EP`, `Failed to set UVC commit control`) it gently cycles only the Kiyo's port while the keyboard/mouse are still alive — instead of waiting the observed ~14 minutes for `HC died` to take the whole bus down. Has its own 30s cooldown and can never delay or suppress the hard recovery levels. Disable with `WATCHDOG_EARLY_INTERVENTION=0`. Trade-off: a mid-call precursor blips the camera for a few seconds; far cheaper than losing every USB device.
- **Level 1:** Rebind the Kiyo's USB port
- **Level 2:** Full xHCI controller PCI unbind/bind
- **Level 3:** Full xHCI driver reload (`modprobe -r xhci_pci xhci_pci_renesas` + reload). On Ubuntu HWE kernels where xhci is builtin to the kernel, L3 is automatically replaced with an extended L2 settle wait (modprobe is a no-op against builtin modules, and the kernel hub-driver's own port power-cycle is what does the actual rescue).
- **Level 4:** Last-resort escalation. Bundles dmesg/lsusb/sysfs/watchdog state into an incident directory under `/tmp/usb-watchdog-incident-*/` and spawns a Ghostty window running Claude Code pointed at the bundle, so the AI can attempt novel recoveries (port power cycling, PCIe relink, device-level reset) while the keyboard and mouse are still wedged. One-shot per boot via `/tmp/usb-watchdog-claude-called` sentinel — won't fire repeatedly into the same wedged controller.

If all levels fail, the watchdog **stops** — no retry loops, no death spirals. A wedged controller needs a reboot.

Behavioral details that surfaced from the 2026-05-13 live-call incident (four crashes in 41 minutes) are now corrected in the script: stale `HC died` matches arriving in the `journalctl -k` pipe after a successful recovery no longer log misleading FATAL/WARNING entries, and crash-dump capture uses `sudo -n dmesg` so kernel context isn't lost on systems with `kernel.dmesg_restrict=1`.

### 3. Quick Fix (no reboot, no patches)

```bash
# Disable LPM for the Kiyo at runtime (k = USB_QUIRK_NO_LPM)
echo "1532:0e05:k" | sudo tee /sys/module/usbcore/parameters/quirks
# Then replug the camera (or unbind/rebind the USB port)
```

Note: The runtime quirk only applies to devices enumerated **after** it's set. This only addresses crash trigger #1 (LPM). For full protection against rapid control transfer crashes, the CTRL_THROTTLE patch (via DKMS) is also needed.

### 4. Pre-call ritual (`pre-call.sh`)

The cheapest mitigation found so far: start every call from a **freshly enumerated** camera.

```bash
./pre-call.sh    # run before joining; exit 0 = green light
```

Both real-world v8.1 failures (2026-05-30, 2026-06-06) involved long-lived camera state, while the first clean 61-minute real-world call (2026-06-10) started minutes after a fresh enumeration — consistent with accumulated firmware state being the underlying destabilizer. The script verifies the patched DKMS module and watchdog are live, port-cycles the camera (refusing if `/dev/video0` is held), fixes the **USB2-fallback trap** — a link cycle doesn't always retrain SuperSpeed, so check `speed=5000`, not just presence — and confirms no precursors fired during the dance. Evidence and the confound caveat: [`kernel-patches/crash-evidence/2026-06-10-v8.1-clean-call/RESULTS.md`](kernel-patches/crash-evidence/2026-06-10-v8.1-clean-call/RESULTS.md).

> **Known-benign log line:** `Failed to set UVC probe control : -32 (exp. 26)` fires on *every* enumeration of this camera with the device healthy. It is a per-probe artifact, **not** a crash precursor — the dangerous sibling is `Failed to set UVC **commit** control`. Don't add the probe line to watchdog/capture trigger patterns.

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

### Reproducers

```bash
# Synthetic SET_CUR flood reproducer — exercises the rate axis only
bash kernel-patches/stress-test-kiyo.sh 50

# Probe→commit hot-restart reproducer — mimics WebRTC bandwidth
# renegotiation. Rotates through Chromium's actual format ladder
# (480p/720p/1080p MJPG + YUYV) forcing fresh probe+commit pairs.
# Discriminates rate-only hypothesis from sequence-dependent
# hypothesis by sweeping INTERVAL_MS.
CYCLES=200 INTERVAL_MS=0 ./kernel-patches/test-probe-commit-cycle.sh

# Wire-level USB capture (binary, Wireshark-loadable as Linux USB capture)
./kernel-patches/capture-usbmon.sh    # then run your call / test

# Auto-detect video call + auto-manage capture. Polls /dev/video0 every
# 3s; starts capture on a fresh holder, stops + classifies on release
# (preserves compressed under kernel-patches/crash-evidence/auto-captures/
# only if a kernel failure marker — crash OR pre-cascade precursor like
# "timeout: still N active urbs" — fired in the call window; otherwise
# silently deletes, so clean calls don't leave 100 MB+ files around).
./kernel-patches/call-watch.sh

# Build and test the CTRL_THROTTLE patch in isolation
sudo bash kernel-patches/build-uvc-module.sh
sudo bash kernel-patches/test-ctrl-throttle.sh 50
```

### Validation evidence

- [`kernel-patches/crash-evidence/`](kernel-patches/crash-evidence/) — kernel logs from real-world failure events
- [`kernel-patches/crash-evidence/2026-05-30-v8.1-realworld-failure/`](kernel-patches/crash-evidence/2026-05-30-v8.1-realworld-failure/) — **v8.1 real-world FAILURE** (2026-05-30): `commit control -110` → HC-died cascade ×2 during organic use with the throttle active (INCIDENT.md + dmesg) — the synthetic-vs-real gap
- [`kernel-patches/crash-evidence/2026-06-06-v8.1-resume-crash/`](kernel-patches/crash-evidence/2026-06-06-v8.1-resume-crash/) — **second v8.1 real-world FAILURE** (2026-06-06): post-resume with Google Meet holding the camera (no active call) — EP#82 iso URB timeout → `-32` commit STALL 4s later → 827s of unlogged silence → HC died; watchdog Level-2 recovered. Opus-audited `analysis.md` (camera was *idle* → COMMIT rate is not the trigger → a more-aggressive-throttle v9 cannot help; pivoted the deliverable to data for the xHCI-side fix)
- [`kernel-patches/crash-evidence/2026-06-10-v8.1-clean-call/`](kernel-patches/crash-evidence/2026-06-10-v8.1-clean-call/) — **first clean v8.1 real-world call** (2026-06-10): 61-min Brave/Meet call + post-call idle window, zero precursors — with a pre-call fresh-enumeration confound (RESULTS.md); origin of `pre-call.sh`
- [`kernel-patches/crash-evidence/2026-05-13-live-call/`](kernel-patches/crash-evidence/2026-05-13-live-call/) — the four-crash live call that motivated v8.1
- [`kernel-patches/crash-evidence/2026-05-13-v8.1-validation/`](kernel-patches/crash-evidence/2026-05-13-v8.1-validation/) — 200/200 clean run at zero-interval hot-restart with v8.1 active (RESULTS.md + 1.9 MB compressed usbmon capture; 808 PROBE + 200 COMMIT SET_CURs landed, all completed normally)
- [`kernel-patches/crash-evidence/auto-captures/`](kernel-patches/crash-evidence/auto-captures/) — preserved automatically by `call-watch.sh` when a real call triggers a kernel failure

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
| `revive-kiyo.sh` | Revive a firmware-locked Kiyo via software USB port-cycle (no physical replug); verifies SuperSpeed after revival and retrains on USB2 fallback — EXPERIMENTAL (2026-05-30) |
| `pre-call.sh` | Pre-call stability ritual — fresh enumeration + SuperSpeed/module/watchdog verification (2026-06-10) |
| `fix-kiyo-pro.sh` | All-in-one fix installer (quirk + udev + WirePlumber) |
| `kernel-patches/0000-cover-letter.txt` | Original cover letter from the first send (legacy reference) |
| `kernel-patches/v8-0000-cover-letter.patch` | v8.1 cover letter for the next LKML send |
| `kernel-patches/v8-0001-…CTRL_THROTTLE…patch` | v8.1 patch 1/2: layered CTRL_THROTTLE quirk |
| `kernel-patches/v8-0002-…Razer-Kiyo-Pro…patch` | v8.1 patch 2/2: device-info table entry |
| `kernel-patches/send-patches.sh` | Sends original 3-patch series via `git send-email` (historical) |
| `kernel-patches/send-patches-v8.sh` | Sends the current v8 series — threads under the v3 root |
| `kernel-patches/build-uvc-module.sh` | Builds patched uvcvideo module from kernel source |
| `kernel-patches/apply-and-test.sh` | Applies patches to kernel tree and runs build |
| `kernel-patches/test-ctrl-throttle.sh` | CTRL_THROTTLE isolation test (swaps module, removes LPM quirk) |
| `kernel-patches/test-probe-commit-cycle.sh` | Probe→commit hot-restart reproducer mimicking WebRTC renegotiation |
| `kernel-patches/test-quirks-locally.sh` | Local quirk validation without rebooting |
| `kernel-patches/test-watchdog.sh` | Watchdog service test harness |
| `kernel-patches/stress-test-kiyo.sh` | Rapid SET_CUR crash reproducer (rate-only stress) |
| `kernel-patches/capture-usbmon.sh` | Wire-level USB capture helper (Wireshark-loadable) |
| `kernel-patches/call-watch.sh` | Auto-detects video calls and manages usbmon capture; preserves only on crash/precursor markers |
| `kernel-patches/install-watchdog.sh` | Installs watchdog systemd service |
| `kernel-patches/upstream-report.md` | Full bug report for linux-usb mailing list |
| `kernel-patches/test-methodology.md` | Test methodology and procedures |
| `kernel-patches/research-*.md` | Root cause analysis notes (historical) |
| `kernel-patches/capture-crash.sh` | dmesg capture script for crash reproduction |
| `kernel-patches/michal-xhci-test.patch` | Michal Pecio's xhci test patch (max_esit_payload clamp + short packet retry) |
| `kernel-patches/crash-evidence/` | Kernel logs from real crash events + v8.1 validation data |
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
- **Kernel:** Tested on 6.8.0-106-generic, 6.17.0-19/20/29/35-generic (Ubuntu 24.04 + HWE), and custom 6.17.0-xhci-test (Michal Pecio's xhci patch)

## Firmware Root Cause

The camera's firmware (Sigmastar SAV630D, built by AIT) has a **USB descriptor spec violation**: the SuperSpeed Endpoint Companion Descriptor for EP5 IN (interrupt) declares `wBytesPerInterval = 8` when it should be `64` (matching `wMaxPacketSize`). This causes the xHCI driver to allocate insufficient bandwidth for the endpoint, contributing to spurious completion events that can cascade into host controller death.

The bug byte is at offset `0x1F570A` in the raw firmware image (`fwimage.bin`) and at offset `0xa1845d` in the .NET ResourceSet (`DeviceUpdater.resources`).

A Linux firmware tool ([`firmware-analysis/kiyo-flash.py`](firmware-analysis/kiyo-flash.py)) implements the reverse-engineered UVC Extension Unit protocol — the same protocol used by the official Windows updater. The tool sends firmware in 32-byte chunks through XU6 selector 3, using raw USB control transfers to bypass the Linux UVC driver's descriptor validation (sel=3 is marked GET-only but the device accepts SET_CUR). ROM boot mode recovery via SCSI is also implemented as a fallback.

**Flash status (2026-04-11):** After extensive testing (6+ attempts with progressive bug fixes), the normal-mode UVC XU flash path does NOT persist firmware on this device. The device accepts data and reports burn-complete (status 0x82) but wBytesPerInterval remains 8 after power cycle. The soft ROM boot entry path is also locked out in production firmware. A firmware-level fix would require either hardware ROM boot (grounding the SoC boot pin) or a Windows VM with USB passthrough to test the official updater. See [`firmware-analysis/README.md`](firmware-analysis/README.md) for the full protocol documentation and findings.

## Upstream Status

- **Patch 1** (`USB_QUIRK_NO_LPM`): **Merged** into `usb-linus` by Greg Kroah-Hartman. Backported to stable kernels 6.1, 6.6, 6.12, 6.18, and 6.19 as of 2026-04-09.
- **Patches 2-3** (`UVC_QUIRK_CTRL_THROTTLE` + device entry): under review on linux-media. **v7 sent 2026-04-09**; **v8.1 staged 2026-05-13** but not yet sent — locally at [`kernel-patches/v8-000{0,1,2}-*.patch`](kernel-patches/) with [`send-patches-v8.sh`](kernel-patches/send-patches-v8.sh) as the launcher. v8.1 reworks the CTRL_THROTTLE quirk from uniform 50ms to layered (uniform 100ms + COMMIT-specific 200ms + COMMIT-specific 10s URB timeout) based on real-world WebRTC failure data. **Real-world validation FAILED 2026-05-30** (and again **2026-06-06**): the cascade recurred during organic desktop use with the v8.1 CTRL_THROTTLE module loaded — so **v8 must NOT be sent**. The 2026-06-07 re-audit of the 06-06 crash (camera *idle* at failure time → control rate is not the trigger) killed the planned v9 "more throttle" iteration too: **CTRL_THROTTLE is the wrong layer for this failure**, and the deliverable has pivoted to evidence for the xHCI-side fix (stock repro + usbmon + `6.17.0-xhci-test` A/B, per [`kernel-patches/reply-to-pecio-v7.txt`](kernel-patches/reply-to-pecio-v7.txt)). Evidence: [`2026-05-30-v8.1-realworld-failure/`](kernel-patches/crash-evidence/2026-05-30-v8.1-realworld-failure/INCIDENT.md), [`2026-06-06-v8.1-resume-crash/`](kernel-patches/crash-evidence/2026-06-06-v8.1-resume-crash/analysis.md).
- **Thread Message-ID:** `<20260331003806.212565-1-jp@jphein.com>`
- **v7 Message-ID:** `<20260410002720.1033303-1-jp@jphein.com>`

### Key Upstream Discussion

- **Mathias Nyman (Intel xHCI maintainer):** Dual-URB cancellation on control EP leaves dequeue on no-op TRB, violating xHCI spec 4.8.3. Disabling LPM reduces control transfers, lowering the dual-cancel risk.
- **Michal Pecio:** Identified wBytesPerInterval=8 as a spec violation; xHCI driver's max_esit_payload derived from it. His test patch (clamp max_esit_payload + short packet retry) allowed HC to survive firmware lockup. 2026-04-27: shared `hammerint.c` standalone reproducer (libusb interrupt-EP cancel hammering) and asked for stream-mmap loop test on stock kernel + stock uvcvideo + no quirks. Concluded "Looks like a HW bug."
- **Test results (2026-04-10):** Two crash reproduction tests on kernel 6.17.0-xhci-test with Michal's xhci patch:
  - **Test 1** (all fixes + Michal's patch): HC DIED — 437 repeated cancel/resubmit on EP5 IN → ~994K spurious SHORT_PACKET events → control URB timeouts → hc_died
  - **Test 2** (Michal's patch only, no JP patches): HC SURVIVED — firmware locked at round ~23 but host controller handled errors gracefully
- **Test results (2026-04-29 hammerint):** Intel xHCI 0000:00:14.0 (NO_LPM active) survived 60s × 2 Kiyos clean — ~12,000 submit/cancel cycles each on EP 0x85 IN with zero `xhci_hc_died` and zero event-198. Confirms Intel xHCI tolerates the dual-cancel pattern that catastrophically kills ASMedia.
- **Test results (2026-05-03 stream-mmap loop, Michal's Test 1):** Two-Kiyo run on Intel xHCI vanilla kernel + stock uvcvideo + **no** quirks (booted into the `Kiyo VANILLA (no fixes)` GRUB entry), 300s real MJPG 1920x1080 @ 30fps streaming each, with test-mode watchdog supervision. Both Kiyos `verdict: no_death_in_window` + `PASS: clean`, dmesg.post empty of fatal patterns. Pure stream-mmap teardown without control-rate stress does **not** reproduce HC death on Intel — confirms CTRL_THROTTLE targets the actual trigger path (rapid SET_CUR overflow), not a generic streaming concern. Forensics: [`kernel-patches/matrix/michal-tests/results/streamloop-20260503T221219Z/`](kernel-patches/matrix/michal-tests/results/streamloop-20260503T221219Z/).
- **Live-call evidence (2026-05-13 morning):** Real Brave WebRTC call on Intel Cannon Lake xHCI, 6.17.0-20-generic, DKMS `uvcvideo-kiyo` with `UVC_QUIRK_CTRL_THROTTLE` at uniform 50ms active. **Four** xHCI host controller deaths in 41 minutes (11:34, 11:37, 12:09, 12:15), every one preceded verbatim by `Failed to set UVC commit control : -110 (exp. 26)`. The 50ms throttle reduced but did not eliminate; the failure was sequence-dependent (PROBE→COMMIT under load), not pure rate. Watchdog recovered each crash in 6–33s. Crash logs: [`kernel-patches/crash-evidence/2026-05-13-live-call/`](kernel-patches/crash-evidence/2026-05-13-live-call/). This evidence motivated the v8.1 revision.
- **v8.1 synthetic validation (2026-05-13 afternoon):** [`test-probe-commit-cycle.sh`](kernel-patches/test-probe-commit-cycle.sh) at `CYCLES=200 INTERVAL_MS=0` against v8.1 throttle live, with usbmon capture in parallel. **200/200 cycles successful, 0 v4l2-ctl errors, 0 kernel failure markers.** Wire capture confirmed 808 PROBE + 200 COMMIT `SET_CUR`s landed on the bus, all completing normally. Same hardware that crashed 4× in 41 min with uniform 50ms now passes ~60s of zero-interval probe→commit hot-restart cleanly with the layered v8.1 mitigation. Synthetic stress is necessary-but-not-sufficient; real-call validation pending. Forensics: [`kernel-patches/crash-evidence/2026-05-13-v8.1-validation/`](kernel-patches/crash-evidence/2026-05-13-v8.1-validation/).
- **v8.1 real-world FAILURE (2026-05-30):** During organic desktop use the Kiyo Pro cascaded the Intel xHCI **twice** (10:42:53, 10:43:41 PDT), each `Failed to set UVC commit control : -110 (exp. 26)` → `HC died` — with a CTRL_THROTTLE build loaded (crash-time `uvcvideo` srcversion `EEC0336…` ≠ stock `7CD08F45…`). So the layered v8.1 throttle did **not** prevent the real-world cascade the synthetic 200/200 implied was fixed. Per the pre-registered rule (≥1 `commit control -110` ⇒ iterate), **v8 is withheld pending v9.** No usbmon for this incident (the recovery watchdog was deadlocked — since fixed). Post-mortem: [`kernel-patches/crash-evidence/2026-05-30-v8.1-realworld-failure/INCIDENT.md`](kernel-patches/crash-evidence/2026-05-30-v8.1-realworld-failure/INCIDENT.md).
- **Second v8.1 real-world FAILURE + re-audit (2026-06-06 / 06-07):** Post-resume crash with Google Meet holding the camera open, no active call: `usb 2-3: timeout: still 12 active urbs on EP #82` (iso video EP) → `-32` commit STALL 4s later → **827s of unlogged silence** → `HC died`; watchdog Level-2 recovered. The re-audit corrected three overclaims from the first analysis draft: the hung iso EP2 has *correct* descriptors (the `wBytesPerInterval` bug is on EP5, a different endpoint, so this is **not** a direct instance of Michal's descriptor bug); the trailing `-110` is HC-died cleanup, not a second stall; resume→timeout was ~43 min. Because the camera was idle, COMMIT *rate* cannot be the trigger — both real-world failures are likely **two presentations of one root cause** (sustained streaming destabilizes firmware; the control-plane stall is a symptom). Analysis: [`kernel-patches/crash-evidence/2026-06-06-v8.1-resume-crash/analysis.md`](kernel-patches/crash-evidence/2026-06-06-v8.1-resume-crash/analysis.md). Three runs decide the open A-vs-B question (EP5 short-packet flood vs independent firmware lock): stock repro, usbmon of it, and the same on `6.17.0-xhci-test` — staged in [`reply-to-pecio-v7.txt`](kernel-patches/reply-to-pecio-v7.txt).
- **First clean v8.1 real-world call (2026-06-10):** 61-minute Brave/Meet call plus the post-call idle window (where the 06-06 cascade had hit ~14 min in), zero precursors, zero watchdog interventions — **but** the camera was freshly re-enumerated minutes before the call, while both prior failures had long-lived camera state. The confound means this datapoint supports "fresh firmware state mitigates" at least as much as "v8.1 works"; it established the [`pre-call.sh`](pre-call.sh) ritual. Operational findings from the same session: a link-level SS-port cycle can strand the camera at USB2 (cycle the HS-side port to retrain; always verify `speed=5000`), and `Failed to set UVC probe control : -32` is a benign per-enumeration artifact, not a precursor. Evidence: [`kernel-patches/crash-evidence/2026-06-10-v8.1-clean-call/RESULTS.md`](kernel-patches/crash-evidence/2026-06-10-v8.1-clean-call/RESULTS.md).

## License

GPL-3.0-or-later
