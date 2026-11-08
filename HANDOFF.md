# HANDOFF — updated 2026-11-08 (luna-katana-av; results: scratch/results/2026-11-08-katana.md; earlier: scratch/PLAN-2026-11-06.md, scratch/reports/2026-11-06.md)

## Where things stand

- **2026-11-08 (katana on 7.0.0-43, Kiyo A + Scarlett plugged in):** the 11-06 fix is verified on hardware:
  quirks **0x410**, LPM attrs absent, SS 5000. A stall still happens on **stop + reconfigure to a new fps**
  (13:42, `probe/commit control -110` → `can't set config -71` → camera boot-looped until replugged), so
  LPM is ruled out as its cause on this kernel. Root ports have no VBUS: recovery needs hands unless the Kiyo
  sits behind a PPPS hub again (card aa593953102c) and/or OBS holds it (card de7a5487154b).
  The `1.1 probe control -32` line at plug and `exposure_dynamic_framerate=1` are camera-side (same on
  wakizashi's Kiyo B with stock uvcvideo). 1080p60 MJPG delivers ~30 fps on BOTH units (29.77 / 29.79)
  under aperture-priority exposure; September's true 60 came through OBS in YUYV.
  Audio: Scarlett on katana, `katana-av/audio-selfcheck` PASS 17/17 (timer), Mic 1 0 dropouts / 0 xruns
  over 60 s, 120 s with the camera at 1080p60 on the same controller, and 11 min.
  New tools in `katana-av/` (PRs #11–#14): audio-selfcheck + av-selfcheck, audio-watchdog (moved here),
  mic-measure, cam-measure, call-probe. The real call test is card f8679972c3d3 (JP never joined today).
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
1. **Hardware run** — steps 1–2 PASS on katana 2026-11-08, bus test done; 30-min stress (step 3)
   not run (it can kill the controller that also carries JP's keyboard, mouse and Scarlett: needs his go);
   real call = card f8679972c3d3; suspend (step 5) not run. (kiyo lane)
2. **Reply v9** — correction of the 08-26 "regression" paragraph + status + the xhci-test ask;
   JP's send card. (kiyo lane; draft `kernel-patches/reply-v9.eml`, gitignored class)
3. **wakizashi module swap** (`modprobe -r uvcvideo && modprobe uvcvideo`, nothing holding the
   nodes) in JP's window; then `kiyo-selfcheck` there must PASS. (kiyo lane, on JP's go)
4. Decide PR #4's port block on katana after the protocol (retire or keep). (kiyo lane)
5. Stale GRUB custom entries: DONE 2026-11-08 (both 6.17.0-20 entries removed, backups in /root, grub-script-check OK).
6. 9 untracked auto-captures (09-23, 09-24, 11-01) — index + sha256, commit the <100 MB ones.
7. `mic-keeper.sh`: DONE 2026-11-08 (retired into katana-av/audio-watchdog.sh, PR #12). `obs-vcam` still
   disabled since ~09-25: JP's card de7a5487154b (recommendation: on).
8. Scarlett sink-disable: CLOSED (JP uses the output; guard stays).
9. Oracle PR #6 finding 2 (latent): with two Kiyos on two controllers, after A's controller dies the
   watchdog's re-detection moves to B's and Level 2 would rebind the healthy one. Follow-up: take the
   PCI address from the triggering "xhci_hcd 0000:…: HC died" line. (kiyo lane; before any host runs two)
10. Oracle PR #6 finding 3 (pre-existing): the watchdog's `*"USB disconnect"*"$XHCI_PCI"*` branch can never
   match (the kernel line carries no PCI address; 0 hits in 60 days). Harmless; fix or drop. (kiyo lane)
