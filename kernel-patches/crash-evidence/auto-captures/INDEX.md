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
| CRASH-20260923T170203Z-3events.txt.gz | 596K | 54b4cbf35e9f970e… | yes | 09-23 10:02 zero-warning HC death; L2 OK 16 s; post-recovery hub VBUS cycle of 2-1.4 did not revive (protocol-dead); physical replug |
| CRASH-20260923T180944Z-1events.txt.gz | 62M | aa23107f69780290… | yes | 09-23 11:09 single event during the protocol-dead window (hub re-tries; ~790 resets 10:00–12:28) |
| CRASH-20260923T192623Z-1events.txt.gz | 520K | ebd685ca8b1c0f42… | yes | 09-23 12:26 hung COMMIT -110 → re-enum 12:28 |
| CRASH-20260924T175437Z-2events.txt.gz | 4.0K | 539ab0f1846ddb2e… | yes | 09-24 10:54 HC death #1 of five that day; VIA hub 2-1.4 VBUS cycle 0/4 post-recovery |
| CRASH-20260924T195221Z-3events.txt.gz | 109M | 572775946279178c… | no (>100 MB) | 09-24 12:52 HC death #2 (298 MB raw; also re-enumerated the Scarlett → mic-keeper born) |
| CRASH-20260924T201015Z-3events.txt.gz | 22M | 7f878de05352fc1c… | yes | 09-24 13:10 HC death #3 |
| CRASH-20260924T202926Z-3events.txt.gz | 7.4M | a00f8dd35acd36a6… | yes | 09-24 13:29 HC death #4 (re-crash within minutes of the replug) |
| CRASH-20260924T203206Z-3events.txt.gz | 472K | 04669e3e8b3470a0… | yes | 09-24 13:32 HC death #5; 13:34–14:02 then ran clean |
| CRASH-20261101T020305Z-1events.txt.gz | 880K | 7f23ad9a9f6e320d… | yes | 10-31 19:03 PDT, 1 event; context not recorded (journal rotated); 21 min before the usb3-no-lpm install |
