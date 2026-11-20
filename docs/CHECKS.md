# CHECKS: kiyo-xhci-fix's durable checks (systemd user timers on katana)

Rule: every timer prints one fixed-shape line

    CHECK <name> <ok|warn|fail> · <fact, number, time> · <next/owner>

to `~/.local/state/checks/<name>.line` on the host it runs on, written to a temp file and renamed. The checks page reads each line and its age; a missing or stale line is a fail, never a quiet zero. A "none yet" row names the line the timer should print; the weekly no-CHECKS pass lists it until the line is real. The host is in the name because these run on the desktop, not on the server.

| name | host | timer | cadence | measures | line shape | owner | status |
|---|---|---|---|---|---|---|---|
| kiyo-selfcheck-katana | katana | kiyo-selfcheck.timer → `kiyo-selfcheck --log` | 3 min after boot, then every 24 h | the Razer Kiyo Pro stack is in effect (the script's own PASS/FAIL items) | `CHECK kiyo-selfcheck-katana ok · N of N items pass, checked HH:MM · next 24 h` and `fail · K of N items fail: <first failing item>` | the lead, until a desktop lane exists | none yet (2026-11-20): the script writes PASS/FAIL to `scratch/selfcheck` only, which no page reads |
| audio-selfcheck-katana | katana | audio-selfcheck.timer → `katana-av/audio-selfcheck --log` | 3 min after boot, then every 24 h | the desktop's call audio and video path: interface at 48 kHz, default devices, OBS at 720p30, the virtual camera | `CHECK audio-selfcheck-katana ok · N of N items pass, checked HH:MM · next 24 h` and `fail · K of N items fail: <first failing item>` | the lead, until a desktop lane exists | none yet (2026-11-20): same as above |

Notes for whoever makes the lines real:
- Both timers are `OnUnitActiveSec=24h`, so a desktop that sleeps overnight checks at an hour that drifts. The line should carry the time it was measured, and the page's stale limit for these two should be about 48 h.
- The desktop is in use: the checks stay read-only and light, and nothing here restarts audio or video.

Behind the rows: the 2026-11-17 timer audit (17 projects ran timers with no CHECKS.md).
