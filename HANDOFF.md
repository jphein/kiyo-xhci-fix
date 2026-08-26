# HANDOFF — updated 2026-08-26

State after the 2026-08-25 crash day (full detail: memory `project_kernel_patches.md`,
evidence `kernel-patches/crash-evidence/2026-08-25-stock-hc-crash/RESULTS.md`).

## Where things stand

- **Stock repro DELIVERED** (owed since April): HC death on stock 7.0.0-30 with
  full usbmon + provenance; two same-day precursor stalls also captured. EP5
  hypothesis-A excluded on stock. Wire timings: Phase-1 SET_INTERFACE hang 5.16s,
  Phase-2 COMMIT hang ~18.5s → HC died.
- **NO_LPM regression found**: merged P1 quirk not applied on 7.x (u1 was live).
  Bisect + linux-usb report pending. Stopgap active: v9-candidate module calls
  usb_disable_lpm() at probe.
- **v9-candidate LIVE** as DKMS `uvcvideo-kiyo/2.0` (7.0-based source):
  CTRL_THROTTLE spacing kept, 10s COMMIT timeout dropped (per 06-13/06-30),
  driver-level LPM disable added. srcversion E2EBD0A2… Repo copy:
  `kernel-patches/v9-candidate-7.0.diff`. 6.x kernels still use `uvcvideo-kiyo/1.0`
  (BUILD_EXCLUSIVE ^6). **Patched module has ~no real call exposure yet** — its
  one datapoint is the 15:08 −32 stall (pre-rebind enum). Next real calls decide.
- **Reply draft ready for JP review**: `kernel-patches/reply-to-pecio-v8.txt`
  (stock repro + 0x82=mic correction + EP5-on-stock + LPM regression + xhci-test
  rebase question). DO NOT send unreviewed.
- Defense stack all live + production-proven: usb-watchdog (L0 save 14:30, L2
  16s recovery 14:27), call-watch (journald classification, provenance stamps,
  crash preservation), scarlett-storm-guard (2 saves 08-22; unit file now in repo).

## Open items

1. JP reviews/sends reply-to-pecio-v8.
2. Bisect the NO_LPM application failure (static table vs parser vs hub.c) →
   separate linux-usb report.
3. xhci-test A/B — needs decision: 7.x rebase of Michal's patch vs 6.17 skew run.
4. call-watch still writes live captures to /tmp (16G tmpfs) — move to /var/tmp
   or project tmp/ (katana /tmp rule, CLAUDE.md 2026-08-25).
5. Collect patched-module call tally (call-watch now stamps PATCHED/STOCK per call).
6. Scarlett sink-disable decision still open (JP hasn't said whether the
   headphone out is used) — guard covers it meanwhile.
