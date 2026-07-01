# 2026-06-30 — HC died on 3-day-stale enumeration; host back in 16 s, camera dead for 24 h

**Verdict: v8.1 did NOT prevent a full HC death (4th v8.1-era failure), and this
one had ZERO warning — the first kernel line about the problem is already the
death announcement, so Level 0 structurally could not fire.** The watchdog's
hard path worked exactly as designed: detection <1 s after `HC died` (the
05-30 deadlock fix fully vindicated — that incident took 19 min), Level 2
xHCI rebind, all HID alive 16 s after death. But the **camera itself stayed
protocol-dead for ~23.7 hours**: with a freshly rebound controller it failed
setup-address twice (`error -71`), the hub's `attempt power cycle` was
**electrically a no-op** (root hub reports "No power switching" — verified
below), and the port gave up. It only returned on **physical replug**
(JP-confirmed: "I had to") the next day at 13:01:03 — 2 minutes before a
37-min Brave call that then ran completely clean on that fresh enumeration.

This is the first incident that cleanly separates **host recovery** (software,
seconds) from **device recovery** (VBUS drop required, i.e. human). It is the
strongest evidence yet that the underlying wedge lives in **camera firmware**:
it survived an xHCI controller reset, four setup-address attempts, and a
(link-level) port cycle, and only a real power cycle cleared it.

## Environment (all verified, not assumed)

- Kernel `6.17.0-35-generic`, boot 2026-06-27 09:14:20 PDT (same boot still
  running on 07-01, so live checks below describe crash-time state)
- uvcvideo: DKMS `uvcvideo-kiyo/1.0` **v8.1**, srcversion `7FCA6457401AD6917E659B7`.
  Loaded == on-disk verified 07-01; the `.ko.zst` mtime is **2026-06-02**, i.e.
  it predates the 06-27 boot and was not rebuilt since ⇒ the module loaded at
  boot (and at crash) was this v8.1 build.
- NO_LPM: active via live cmdline `usbcore.quirks=1532:0e05:k` (read from
  `/proc/cmdline` of the same boot)
- Watchdog: user unit `usb-watchdog.service` (Level 0 early intervention
  enabled, e3957db lineage), running since boot
- **No usbmon / call-watch during the crash** — this incident is dmesg-only.
  (call-watch.sh was armed for the 07-01 call, one day too late.)
- Kiyo enumeration age at crash: **bus-2 device number 3** while the bus's
  device counter had reached 22 (`2-4` was device 22) ⇒ enumerated at the
  very start of the 06-27 boot and never re-enumerated since (zero `usb 2-3`
  events in the retained journal, which starts 06-28 19:21) ⇒ **~3.2 days of
  accumulated camera/firmware state**. Fits the stale-state crash pattern.

## Timeline (PDT; ✓ = logged, ~ = inferred from known timeouts)

| Time | Ev | Event |
|---|---|---|
| ~13:21:06.7 | ~ | COMMIT control URB submitted (back-calculated: v8.1 extends the COMMIT URB timeout to 10 s) |
| ~13:21:16.7 | ~ | URB timeout → `usb_kill_urb` → xHCI **Stop Endpoint** command issued; firmware never answers (5 s xHCI command watchdog starts) |
| 13:21:21.113 | ✓ | apparmor audit: brave ThreadPool exec — **coincidental noise**, 0.6 s before death; the trigger chain began ≥15 s earlier |
| 13:21:21.7 | ✓ | `xHCI host not responding to stop endpoint command` → `assume dead` → **`HC died; cleaning up`** (00:14.0). Full-bus cascade: buses 1+2 torn down, all devices disconnect |
| 13:21:21.737 | ✓ | `uvcvideo 2-3:1.1: Failed to set UVC commit control : -110 (exp. 26)` — ~1 ms AFTER `HC died`: the hung COMMIT given back by cleanup (same post-mortem-flush reading as 06-06/06-13; NOT a second stall) |
| 13:21:22 | ✓ | Watchdog `FATAL: xHCI not responding — initiating recovery` (**detection <1 s**), crash dump saved, Level 2 unbind |
| 13:21:27 | ✓ | Level 2 bind; controller re-registers buses 1+2 |
| 13:21:27–35 | ✓ | Everything re-enumerates: VIA hubs, Dygma, Logitech, Hailuck, storage, BT — **except the Kiyo** |
| 13:21:28–32 | ✓ | Kiyo enum attempts: `Device not responding to setup address` ×2 → `-71`; retry ×2 → `-71`; `usb usb2-port3: attempt power cycle` (**no-op — no PPPS, see below**); ×2 → `-71`; ×2 → `-71`; **`unable to enumerate USB device`** — port gives up |
| 13:21:37 | ✓ | Watchdog `LEVEL 2 OK: All devices alive` (checks HID; the absent camera raises no alarm) |
| —23.66 h— | ✓ | Zero `usb 2-3` events. Camera absent from the bus the entire time; watchdog silent |
| 07-01 13:01:03 | ✓ | Fresh connect (physical replug — JP confirmed): SuperSpeed, device 13, benign per-enumeration probe `-32` at 13:01:05 |
| 07-01 13:03–13:40 | ✓ | 37-min Brave call on that fresh enumeration: **clean** (626 MB usbmon captured by call-watch, zero markers, deleted per policy) |

## Mechanism (dmesg-inferred — no wire data; marked accordingly)

Consistent with the 06-13 two-phase reconfiguration-lock model, with a new
reaper chain identified:

1. A stream reconfiguration hangs at **COMMIT** (Phase 2 of the 06-13 model).
2. v8.1's **10 s** COMMIT URB timeout expires → `usb_kill_urb`.
3. The kill issues an xHCI **Stop Endpoint** command; the command ring is also
   wedged (matches 06-13's post-stall dead control plane), so it never
   completes.
4. The 5 s xHCI command watchdog fires → `assume dead` → `HC died`.
5. Cleanup gives back the killed URB → uvcvideo logs `-110` post-mortem.

Back-calculated timing (10 s + 5 s ≈ death at 13:21:21.7 ⇒ COMMIT ~13:21:06.7)
is self-consistent, and the −110-after-death ordering falls out naturally:
`usb_kill_urb` blocks until giveback, which only happens at HC teardown.
An alternative chain — Stop Endpoint issued while flushing in-flight iso URBs
during a stream stop (Phase-1-analog at ring level) — cannot be excluded
without usbmon, but requires a COMMIT submitted before the stream stop, which
is out of UVC order; chain above is the parsimonious fit.

**Why Level 0 could not fire:** its triggers are dmesg lines (`active urbs`
timeout / commit-control failure). In this presentation the whole 15 s wedge
is **silent**; the first line the kernel prints is `not responding to stop
endpoint command`, and the Level-0-trigger `-110` line prints only *after*
`HC died`. On 06-13 the same hung-COMMIT kill *succeeded* (command ring still
alive), the −110 printed pre-death, and Level 0 saved the controller — the
differentiator is whether the command ring survives the Stop Endpoint.

**v9 implication (reinforces the 06-13 decision):** the 10 s COMMIT timeout
extension is actively harmful in this presentation — it stretched
wedge-to-death from ~10 s (stock 5 s timeout) to ~15 s and delayed the only
line Level 0 can react to. Drop it. No uvcvideo-side throttle can help a
silent command-ring wedge; this presentation is only addressable xHCI-side
(abort/recovery hardening — Mathias/Michal's territory) or in camera firmware.

## Device-side wedge — the 24 h outage

- `-71` (EPROTO) at **setup-address** stage: the link trains, but the device
  does not speak protocol — camera firmware catatonic, not a link problem.
- `usb usb2-port3: attempt power cycle` did **not** drop VBUS: the root hub
  descriptor reports `wHubCharacteristic 0x000a` = **"No power switching"**
  (verified via `lsusb -v` on bus 2 root hub). On this board, software has
  *no* per-port power control — `ClearPortFeature(PORT_POWER)` is a no-op.
- Consequently `revive-kiyo.sh` / `pre-call.sh` port cycles (link-level
  `disable` attribute) could not have helped either — untested yesterday
  (nobody ran them), but they operate above the layer that was dead.
- Only a **physical replug** (real VBUS drop, firmware cold boot) revived it.

**Watchdog gap (by design, worth knowing):** after `LEVEL 2 OK` the watchdog
never alarmed on the camera's 24 h absence — it guards the controller + HID,
not Kiyo presence. If camera-presence alerting is wanted, that's a new
(small) feature, not a bug fix.

## What this adds for upstream

1. **New failure presentation identified:** silent command-ring wedge →
   stop-endpoint-command death, zero precursor lines. Complements the 06-13
   wire-captured presentations (−110 URB-timeout reap, −32 watchdog reap) as
   a third reaper of the same underlying hung reconfiguration.
2. **Device firmware is the sticky layer:** the wedge survives an xHCI
   controller reset and enumeration retries, and needs a VBUS drop to clear.
   Host-side mitigation can only contain blast radius, not cure.
3. **Stale-vs-fresh tally strengthens:** crash on a ~3.2-day-old enumeration;
   the very next call (07-01, fresh replug enumeration) ran clean. Running
   pattern: fresh-enum sessions clean (06-10 61-min call, 06-11 2-h OBS,
   07-01 37-min call); stale-state sessions produce the failures (05-30,
   06-06, 06-13 EV1, 06-30).

## Unrelated noise in the window (not part of this failure)

- Samsung Android phone (04e8:6860) ACM plug/unplug churn on 1-2 pre-crash.
- `BTRFS error (device nvme1n1) … rd` counter climbing steadily (881→896 in
  the captured window; ~2 read errors/min). **Separate storage issue — flag
  to JP**, unrelated to USB but deserves its own investigation.

## Files

- `usb-watchdog-crash-20260630-132122.log` — watchdog crash dump (rescued
  from `/tmp` on 07-01; dmesg tail ×50, lsusb, expected-device check)
- `kernel-journal-cascade-and-recovery.txt` — kernel journal 13:20:50–13:25:00
  (cascade, rebind, full re-enumeration, Kiyo enum failures)
- `watchdog-journal-window.txt` — user-unit journal 13:15–13:40 (FATAL →
  dump → Level 2 → OK; raw, includes sudo/pam lines)
- `kiyo-absent-until-replug-20260701.txt` — every `2-3`/port event from
  13:21:25 to the 07-01 13:01:03 return (the 24 h gap is the point)

## Open items

- Workload at crash time unknown (brave held the camera; call vs preview
  unrecorded — call-watch wasn't running).
- Consider auto-starting `call-watch.sh` (login unit) so no future incident
  is dmesg-only.
