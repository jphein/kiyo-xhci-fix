# 2026-05-30 — v8.1 real-world FAILURE + two deployment bugs

## TL;DR

The Razer Kiyo Pro cascaded the Intel xHCI controller (`0000:00:14.0`,
Cannon Lake) **twice** during organic desktop use this morning, each time
with the exact fault the `UVC_QUIRK_CTRL_THROTTLE` patch is designed to
prevent:

```
xhci_hcd 0000:00:14.0: xHCI host controller not responding, assume dead
xhci_hcd 0000:00:14.0: HC died; cleaning up
uvcvideo 2-1:1.1: Failed to set UVC commit control : -110 (exp. 26).
```

A **CTRL_THROTTLE (patched) uvcvideo was loaded at the time** — not stock.
So this is **v8.1 failing the real-world test** that the synthetic 200/200
run (2026-05-13) could not stand in for. Per the project's pre-registered
rule (*"if even one `commit control -110`, draft v9"*), **v8 must not be
sent to LKML as-is; this is the v9 trigger.**

Two *deployment* bugs (independent of the patch's correctness) were also
found and fixed during the response — see below.

## Timeline (PDT)

| Time | Event |
|------|-------|
| ~10:42:53 | First cascade — `commit control -110` → `HC died`. All USB on buses 1+2 dropped (keyboard, mouse, audio, storage, BT). |
| ~10:43:14 | Bus re-enumerated (Kiyo Pro re-attached). |
| ~10:43:41 | **Second** cascade — identical `commit control -110` → `HC died`. |
| 10:43:41 → 11:07 | Controller stayed dead ~19 min. **The watchdog did not recover it** (see Bug 1). |
| 11:07 | Manual Level-2 recovery (PCI unbind/bind of `0000:00:14.0`); Kiyo parked `authorized=0`; all devices restored. |
| 11:20–11:28 | Watchdog deadlock fixed + relaunched; v8.1 DKMS module rebuilt/installed/loaded; Kiyo re-enabled; 10-frame stream clean. |

Full kernel log: [`dmesg-crash-20260530.log`](./dmesg-crash-20260530.log).

## Proof the throttle was active (not stock)

`uvcvideo` srcversions on this machine:

| Build | srcversion |
|-------|------------|
| **Loaded at crash (since boot)** | `EEC033608BC692186A12A1E` |
| Stock in-tree (`.../kernel/.../uvcvideo.ko.zst`) | `7CD08F45C7F58DA18CC11AA` |
| 05-13 v8.1 DKMS build (`-22` .ko on disk) | `EEC033608BC692186A12A1E` |
| Fresh `-20` rebuild (now loaded) | `7FCA6457401AD6917E659B7` |

The crash-time module (`EEC0336…`) is **not** stock (`7CD08F45…`) and
matches the 05-13 v8.1 DKMS build → a CTRL_THROTTLE build was active when
the COMMIT-110 cascade fired.

> **Open thread (worth confirming before drafting v9):** a fresh `-20`
> rebuild today hashed to `7FCA645…`, *not* `EEC0336…`, despite ostensibly
> identical v8.1 source. The "not stock" conclusion is solid; "it was
> precisely v8.1 (100/200/10s) vs an earlier throttle revision" has this
> one loose end. Recommend verifying the exact constants in the
> `EEC0336…` build (or rebuild-determinism) before finalizing v9 claims.

## Why this matters

The 2026-05-13 synthetic run was **200/200 clean at zero-interval
hot-restart** — but it exercised a *fast, regular* SET_CUR cadence. The
throttle enforces a minimum *floor* between transfers; it cannot help if
the firmware's failure is driven by something the synthetic test does not
reproduce:

- bandwidth-driven **irregular** WebRTC re-negotiation timing, and/or
- **accumulated firmware state** over a longer real session.

This incident is the concrete demonstration that 200/200-synthetic ≠
real-world-safe — exactly the caveat the validation doc flagged.

## v9 candidates

(Pre-registered in the patch-series notes; this incident promotes them
from "if needed" to "needed".)

1. Increase COMMIT-specific interval **200ms → 300ms**.
2. Add a **probe-just-completed** rate-spike guard (extra delay when COMMIT
   immediately follows a PROBE round).
3. Re-examine the **10s COMMIT URB timeout** — was the abort path still
   reached? (Needs usbmon, which we lack for this incident.)

**Before v9:** capture usbmon (`kernel-patches/capture-usbmon.sh`) during a
controlled repro so the next iteration is grounded in wire-level data, not
just the dmesg signature.

## Deployment bugs found + fixed (separate from patch correctness)

### Bug 1 — watchdog detector deadlock (FIXED)

`usb-watchdog.sh` watched the log via `journalctl -k -f | while read -r
line`. When that feed went silent (journald hiccup, or the kernel log going
quiet as the HC died), `read` blocked forever on `anon_pipe_read`. Since
*every* recovery path lives behind that read, the watchdog stayed "running"
in `ps` but was **deaf** — which is why the controller sat dead ~19 min with
an active watchdog.

**Fix:** persistent FD via process substitution + `read -t 15` periodic
health poll (so a silent feed wakes an independent check) + EOF respawn (so
a dead `journalctl` restarts instead of ending the script). A 2-poll
debounce avoids needless rebinds on an intentional unplug. Now runs as a
single instance under the **user** service
`~/.config/systemd/user/usb-watchdog.service`.

### Bug 2 — v8.1 DKMS module not loaded at boot (FIXED)

The patched `uvcvideo-kiyo/1.0` DKMS module was not the one loaded at the
last boot (srcversion mismatch above). Rebuilt + installed for
`6.17.0-20-generic` (running) and `6.17.0-22-generic` (next boot); loaded
`/sys/module/uvcvideo/srcversion` now matches the `/updates/dkms` .ko.

**Operational check after every kernel update:**

```sh
cat /sys/module/uvcvideo/srcversion
/usr/sbin/modinfo -F srcversion /lib/modules/$(uname -r)/updates/dkms/uvcvideo.ko.zst
# these must match; if not, the throttle is not active → dkms install for the running kernel
```

## Current state (end of response)

- Desktop USB recovered; keyboard/mouse/all devices alive.
- Watchdog: fixed, single supervised instance, armed.
- v8.1 module: rebuilt, installed (-20/-22), loaded (== `/updates` build).
- Kiyo: re-enabled, light stream clean — **but NOT proven call-safe**; this
  incident shows it can still cascade. The (now-working) watchdog is the
  backstop.
- LKML: **do not send v8.** Draft v9 after usbmon-grounded repro.
