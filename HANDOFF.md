# HANDOFF — updated 2026-11-06 (kiyo lane; plan: scratch/PLAN-2026-11-06.md, report: scratch/reports/2026-11-06.md)

## Where things stand

- **Two beds.** Kiyo Pro A on **katana** (JP's desktop; not plugged in on 11-06), Kiyo Pro B on
  **wakizashi** (Dell laptop, camera at `6-2.3.2` on the Thunderbolt dock's xHCI `0000:3b:00.0`).
  wakizashi is the control: the same stack there, clean = katana's remaining failures are katana's
  own controller/port/cable.
- **The "7.x NO_LPM regression" is closed — it was our parameter.** `usb_detect_quirks()` XORs
  `usbcore.quirks=` against the built-in table; the Kiyo entry is built into 7.0, so katana's
  `usbcore.quirks=1532:0e05:k` switched NO_LPM OFF from the 26.04 upgrade until 2026-11-06
  (quirks attr 0x10 = RESET only; wakizashi with no parameter reads 0x400). Removed from GRUB,
  modprobe.d and the runtime list on 11-06; `/proc/cmdline` carries it until the next boot.
  Verify at plug-in: `quirks` = 0x410, `power/usb3_hardware_lpm_u1` absent. No linux-usb
  regression report; the thread gets a correction instead (reply v9).
- **v9-candidate** DKMS `uvcvideo-kiyo/2.0` (srcversion E2EBD0A2…) installed on BOTH hosts for
  7.0.0-38 and 7.0.0-42; loaded on katana; wakizashi still runs stock until a module reload or
  reboot (JP's window — it re-probes the cameras on a host he uses).
- **Port-level LPM block** (PR #4, `usb3-no-lpm`) stays on katana as belt-and-braces until the
  protocol passes with the in-tree quirk effective; not installed on wakizashi (quirk effective,
  laptop/dock power).
- **kiyo-selfcheck** (PR #8), **kiyo-protocol** + **install-stack.sh** (PR #9): every layer measured, PASS/FAIL, user timer after boot + daily,
  `scratch/selfcheck/<host>.log`, critical notification on FAIL. **Captures and crash dumps are
  off tmpfs** (PR #6): `tmp/captures`, `tmp/watchdog`. The watchdog follows the Kiyo's controller
  (wakizashi: 3b:00.0) and takes `~/.config/usb-watchdog.conf` per host.
- Upstream: last mail is JP's 2026-08-26 reply (SENT; Message-ID 20260826133952.1694379-1); no
  answer in 10 weeks; v8 patches 2/3 unapplied, no review since 04-27.

## Open items (owner · tracker)
1. **Hardware run** — JP's card: plug the Kiyo into katana, reboot katana into -42 (GRUB fix +
   gnome-shell), give the go. Then the protocol (scratch/PLAN-2026-11-06.md §Test protocol) on
   both beds; results in `scratch/results/<date>-<host>.md`. (kiyo lane, on JP's go)
2. **Reply v9** — correction of the 08-26 "regression" paragraph + status + the xhci-test ask;
   JP's send card. (kiyo lane; draft `kernel-patches/reply-v9.eml`, gitignored class)
3. **wakizashi module swap** (`modprobe -r uvcvideo && modprobe uvcvideo`, nothing holding the
   nodes) in JP's window; then `kiyo-selfcheck` there must PASS. (kiyo lane, on JP's go)
4. Decide PR #4's port block on katana after the protocol (retire or keep). (kiyo lane)
5. Stale GRUB custom entries in `/etc/grub.d/40_custom` point at a 6.17.0-20 kernel that no longer
   exists in /boot — harmless, remove in a /housekeep pass. (housekeep)
6. 9 untracked auto-captures (09-23, 09-24, 11-01) — index + sha256, commit the <100 MB ones.
7. `mic-keeper.sh` still has no unit; `obs-vcam` is disabled since ~09-25 (JP's call to re-enable).
8. Scarlett sink-disable: CLOSED (JP uses the output; guard stays).
9. Oracle PR #6 finding 2 (latent): with two Kiyos on two controllers, after A's controller dies the
   watchdog's re-detection moves to B's and Level 2 would rebind the healthy one. Follow-up: take the
   PCI address from the triggering "xhci_hcd 0000:…: HC died" line. (kiyo lane; before any host runs two)
10. Oracle PR #6 finding 3 (pre-existing): the watchdog's `*"USB disconnect"*"$XHCI_PCI"*` branch can never
   match (the kernel line carries no PCI address; 0 hits in 60 days). Harmless; fix or drop. (kiyo lane)
