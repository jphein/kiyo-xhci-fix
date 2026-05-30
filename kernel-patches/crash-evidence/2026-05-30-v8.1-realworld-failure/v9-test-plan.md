# v9 test plan — does the xHCI-side fix survive the live-call cascade?

Per `v9-analysis.md`, v8.1's uvcvideo throttle is the wrong axis: well-spaced
COMMITs still stall and the Cannon Lake HC dies ~7s in. The hypothesis to test
is that the **xHCI-side** patch (Michal Pecio's max_esit_payload clamp +
short-packet retry) lets the host **survive** the firmware stall instead of
dying.

## Preconditions (already in place)
- `/boot/vmlinuz-6.17.0-xhci-test` is bootable (Michal's xhci patch).
- `uvcvideo-kiyo/1.0` DKMS is installed for `6.17.0-xhci-test`.
- `usbcore.quirks=1532:0e05:k` (NO_LPM) on cmdline (keep it).

## Procedure (POST-CALL — needs a reboot)
1. Reboot into `6.17.0-xhci-test` (GRUB → that kernel).
2. Confirm: `uname -r` = `6.17.0-xhci-test`; `cat /sys/module/uvcvideo/srcversion`
   matches the `/updates/dkms` build; `cat /proc/cmdline` shows the NO_LPM quirk.
3. Start wire capture: `bash kernel-patches/capture-usbmon.sh` (or
   `sudo cat /sys/kernel/debug/usb/usbmon/0u > /tmp/v9-xhci-test.txt`).
4. Drive the failing pattern — real renegotiation, not a SET_CUR flood:
   - Best: a real ~10-min WebRTC call (Brave/Chromium), the actual trigger.
   - Or synthetic: `bash kernel-patches/test-probe-commit-cycle.sh`
     (CYCLES=200 INTERVAL_MS=0) — note this passed clean even on the stock
     kernel, so it is necessary-but-not-sufficient; the real call is the bar.
5. Watch: `journalctl -k -f | grep -iE 'commit control|HC died|assume dead|stop endpoint'`

## Pass / fail
- **PASS (xHCI fix works):** `Failed to set UVC commit control` may still appear
  (firmware still stalls), but **no `HC died` / `assume dead`** — the host
  absorbs the stall and other USB devices stay alive.
- **FAIL:** `HC died` recurs as on stock 6.17.0-20. Then the clamp/retry is
  insufficient too, and the discussion moves to a deeper xHCI abort-path fix
  with Mathias Nyman.

## After the test
- Take the result + the 2026-05-30 live capture to the LKML thread (reply to
  Michal Pecio / Mathias Nyman). This is the real-call data Michal asked for.
- Decide v8/v9 framing: the uvcvideo throttle (patches 2-3) is now in doubt for
  real-world use; the NO_LPM quirk (patch 1, merged) stays.
