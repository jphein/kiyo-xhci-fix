# Auto-captures index

call-watch preserves a usbmon capture of bus 2 whenever a call ends with crash events.
Files over GitHub's 100 MB blob limit stay local-only (gitignored by name) and are
listed here with sha256 so provenance survives. katana copy is the master.

| capture | size | sha256 | tracked | context |
|---|---|---|---|---|
| CRASH-20260613T165021Z-1events.txt.gz | 8.0K | 0b29487d2451e93e… | yes |  |
| CRASH-20260613T182335Z-1events.txt.gz | 22M | 3c715ff26e4d7b15… | yes |  |
| CRASH-20260825T212701Z-4events.txt.gz | 12M | 163c8ce104de8baa… | yes | 08-25 stock HC-death series (see 2026-08-25-stock-hc-crash/) |
| CRASH-20260825T213016Z-1events.txt.gz | 1.3M | 5a61891742b11ae6… | yes | 08-25 stock HC-death series (see 2026-08-25-stock-hc-crash/) |
| CRASH-20260825T213154Z-1events.txt.gz | 2.1M | 6fce963da0178b58… | yes | 08-25 stock HC-death series (see 2026-08-25-stock-hc-crash/) |
| CRASH-20260825T220834Z-1events.txt.gz | 168K | d4a2ebb3ba1c0216… | yes | 08-25 stock HC-death series (see 2026-08-25-stock-hc-crash/) |
| CRASH-20260908T202356Z-3events.txt.gz | 113M | 781b3debcef69150… | no (>100 MB) | 09-08 3-event crash |
| CRASH-20260910T190442Z-1events.txt.gz | 22M | 1b9952697fea976d… | yes | 09-10 stale COMMIT hang |
| CRASH-20260910T193017Z-3events.txt.gz | 77M | 6f66ea7e092f70fa… | yes | 09-10 fresh HC death → protocol-dead → replug (motivated c4d37cc) |
| CRASH-20260917T193156Z-3events.txt.gz | 145M | ce8ec65047db385a… | no (>100 MB) | 09-17 12:31 zero-warning HC death on stock 7.0.0-31, watchdog L2 16 s, Kiyo on root port → physical replug |
| CRASH-20260917T194547Z-1events.txt.gz | 25M | d922116d9abe55ab… | yes | 09-17 12:45 hung COMMIT -110 → can't set config -71; EARLY link-cycle false-OK; fixed by authorized toggle |
