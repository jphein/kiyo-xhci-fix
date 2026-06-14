# 2026-06-13 — first wire-level captures of the precursor + Level 0's first live saves

**This is the most decisive evidence the project has produced.** Two precursor
events fired during real Brave video calls; the watchdog's Level 0 early
intervention caught **both** (its first live validation) and `call-watch.sh`
auto-preserved usbmon for each. The 121 MB capture answers the A-vs-B question
the `reply-to-pecio-v7` draft was built around: **hypothesis A (EP5
short-packet flood) is definitively absent in a real crash.**

All wire-level claims below were independently re-derived and adversarially
verified (a second agent tried to refute each load-bearing finding and could
not; `refuted: false`, confidence high).

## Environment

- Kernel 6.17.0-35-generic; uvcvideo DKMS v8.1 `7FCA6457…` loaded (verified this session)
- NO_LPM active via boot cmdline; watchdog active with Level 0 (commit e3957db)
- **No HC died this boot** — both cascades averted. HID never dropped, no reboot.
- Captures: `crash-evidence/auto-captures/CRASH-20260613T165021Z-1events.txt.gz`
  (62 KB raw, the 09:50 −110 event) and `…182335Z-1events.txt.gz` (121 MB raw,
  the 11:23 −32 event, full ~437 s call).

## The two events

| Time | dmesg signature | What the watchdog did | Outcome |
|---|---|---|---|
| 09:50:20 | `Failed to set UVC commit control : -110` (ETIMEDOUT), **15 s into the call**, on a **5 h-old post-resume enumeration** (no `pre-call.sh` run) | EARLY #1 cycled Kiyo port 2-3 (HID untouched) | re-enumerated in ~16 s, **no HC died** |
| 11:23:31 | `Failed to set UVC commit control : -32` (EPIPE), ~7 min into a call **after 70+ min of prior streaming** | EARLY #2 cycled port 2-3 | re-enumerated in ~8 s, **no HC died** |

Every other call segment that day (incl. a 72-min and a 38-min stretch) ran clean.

## Level 0 early intervention — validated in the wild (×2)

Committed 2026-06-07 with only offline tests; today it did exactly what it was
designed for, twice — converting what the 06-06 evidence shows would have been
two full-bus cascades (`HC died`, keyboard+mouse down, reboot) into ~15-second
camera-only blips. `EARLY_COUNT` reached 2. This is the strongest argument yet
for keeping the watchdog as the daily-driver mitigation regardless of the
upstream outcome.

## Wire-level forensics (EV2, the 121 MB / 11:23 capture)

### 1. Hypothesis A (EP5 short-packet flood) is DEFINITIVELY ABSENT

Camera EP5 (`Ii:2:010:5`, the `wBytesPerInterval`-bug interrupt endpoint):
**89 events total** across the whole 437.7 s (44 submit / 45 complete). Of the
45 completions: **2** normal 6-byte UVC status reads, **42** ENOENT(−2) unlinks,
**1** ESHUTDOWN(−108) — i.e. all the "activity" is the watchdog *tearing the
device down* at the end. EP5 was **silent for the first ~430 s**; all 89 events
cluster in a 5.85 s teardown burst.

- **Zero** short-packet-success completions.
- vs the 2026-04-10 synthetic "Test 1" flood of **~994,000** EP5 short-packet
  events → real is **~1/22,000th, 4.3 orders of magnitude below**.
- The actual high-volume traffic was the **healthy** iso video stream EP2
  (`Zi:2:010:2`): 429,212 status-0 completions, only 12 errors (all −104, and
  all *after* the stall).

Verification agent enumerated every device number and transfer type on bus 2:
EP5 exists only under dev 010; no flood hides under the re-enumerated dev 011;
event density is flat (~25,500/10 s) with no ring-overflow gap that could mask a
flood. **This is the signature of hypothesis B** — the EP5 interrupt pipe is
quiet; the crash is an iso/firmware lock independent of the descriptor bug.
Consistent with the Opus 06-07 re-audit (one root cause, *not* the EP5
`wBytesPerInterval` path; Michal's short-packet-retry patch does not run for iso
and would not engage here).

### 2. Failure sequence — a TWO-PHASE stream-reconfiguration lock

> **Refined 2026-06-14** by the 05-30↔06-13 cross-capture verification (run
> `wf_a4d7599d-784`), which adversarially corrected an earlier "iso wedges
> first, control is the downstream symptom" reading. Control trouble actually
> *leads*; the iso wedge follows with the COMMIT.

The failure is a stream-reconfiguration sequence (stop-stream then re-commit)
that hangs in two distinct phases. On camera dev 010:

1. `876363135` — `SET_INTERFACE` alt 0 on iface 1 submitted (host **stopping**
   the stream). It **hangs ~5.4 s while iso video keeps streaming healthily**
   (5,405 EP2 frames in the window, ~2 ms jitter), then the driver unlinks it
   → −2 (ENOENT) at `881768116`. **This is a control-plane-only stall: the
   control endpoint is unresponsive while the data endpoint is perfectly fine.**
2. `881770393` (+2.3 ms) — `VS_COMMIT_CONTROL` SET_CUR submitted (commit new
   params, `s 21 01 0200 0001 001a`, 26 bytes).
3. `881797089` (+26.7 ms) — **now** iso EP2 wedges: silent **5.46 s** (one
   unanswered submit, zero completions).
4. `887254261` — EP2 recovers; `887260603` (+6.3 ms) the COMMIT drains **−32**.

So the **leading edge is the control-plane stall** (SET_INTERFACE, iso healthy);
the iso wedge arrives ~5.4 s later **with the COMMIT**. Both planes are stuck
only in phase 2. The earlier write-up saw only phase 2 (COMMIT→iso-wedge→−32)
and mislabelled the iso wedge as the initiator.

> What the capture cannot prove: whether phase 1 *causes* phase 2, or both are
> escalating symptoms of one firmware lock. What IS verified: the two-phase
> `SET_INTERFACE`→`COMMIT` structure, with iso **healthy in phase 1** and
> **wedged in phase 2**, is identical on 05-30 and 06-13 (cross-capture section
> below). The control endpoint demonstrably stalls ~5 s with video flowing — so
> there is a real control-plane failure component, not merely an iso wedge.

### 3. −110 and −32 are the SAME failure, distinguished only by what reaps the hung COMMIT

- **EV1 (09:50, −110):** the COMMIT got no completion for **10.238 s** → killed
  by the ~10 s control-URB timeout → recorded −2 (ENOENT) on the wire → surfaced
  as **−110 ETIMEDOUT** to UVC.
- **EV2 (11:23, −32):** the identical COMMIT hung **5.49 s** then was reaped by
  the watchdog's Level 0 **port-cycle teardown** (which beat the 10 s timeout) →
  surfaced as **−32 EPIPE**.

Same underlying event (controller wedge, COMMIT hangs); the error code is just
*who reaps the hung URB first* — the 10 s timeout (−110) or the watchdog
teardown (−32). **This corrects the prior project belief that "−32 is an
immediate STALL"** (inferred from dmesg in the 06-06 analysis): the wire shows
it is a ~5.5 s hang, not a synchronous stall.

### 4. v8.1's CTRL_THROTTLE never engages — there is no rate to throttle

The capture contains **exactly one COMMIT in 437 s**. The throttle is a
*minimum-interval* mechanism; with no rapid control burst it has nothing to
pace, so it is (correctly) invisible on the wire. This is not evidence v8.1 was
unloaded (srcversion confirmed loaded this session) — it is the **point**: the
real failure has **no rapid-control-burst component**, so CTRL_THROTTLE (a
minimum-*interval* mechanism) is structurally incapable of preventing it: the
trigger is a single stream-reconfiguration (one SET_INTERFACE + one COMMIT, §2),
not a fast SET_CUR storm. This is the definitive nail in the coffin for the
uvcvideo-throttle-as-*fix* approach (already abandoned 06-07; wire-level
confirmation). Caveat the throttle keeps a *narrow* role — see cross-capture
section: by spacing reconfiguration churn it can reduce how *often* the
two-phase lock fires, which plausibly explains the frequency drop since 05-13.

The 10 s COMMIT URB-timeout extension (the other half of v8.1) is, if anything,
counterproductive: in EV1 it let the COMMIT hang the full 10 s before release;
only the watchdog port-cycle (EV2) ended the hang sooner.

## Implications for the upstream thread

- **A-vs-B is resolved toward B** with real wire data: no EP5 short-packet flood;
  the crash is an iso/firmware lock. This is independent of uvcvideo version
  (EP5 traffic is device-driven, not throttle-driven), so it is valid evidence
  even though v8.1 (not stock) was loaded.
- **Still owed before finalising `reply-to-pecio-v7`:** item 1 (a *stock*-kernel
  reproduction — this was v8.1) and item 3 (the same capture on
  `6.17.0-xhci-test` to see whether Michal's clamp changes the iso wedge). The
  EP5-quiet finding can be folded into the reply now; the stock + xhci-test runs
  remain.
- **Do NOT send v8.** CTRL_THROTTLE is the wrong layer — now confirmed on the wire.

## Fresh-enumeration confound — partially de-confounded

Today's 09:50 crash happened on a **stale 5 h post-resume enumeration with no
`pre-call.sh`** — and it failed 15 s in, versus the two clean days (06-10,
06-11) that both ran the ritual first. That's another point for the ritual. But
event 2 fired *after 70+ min of heavy streaming* on an already-cycled
enumeration, so **fresh start is not a complete fix** — sustained streaming
still destabilises the firmware, consistent with the iso-wedge root cause.
Running tally: ritual-first → 2/2 clean (06-10 Meet, 06-11 OBS); no-ritual or
long-stream → both of today's precursors.

## Cross-capture comparison with 05-30 (added 2026-06-14, adversarially verified)

Comparing this capture against the full 05-30 raw usbmon
(`/home/jp/kiyo-livecall-usbmon-20260530.txt.gz`, 2.5 M lines, iso plane intact
— the in-repo 05-30 extract was control-only, which is what made 05-30 *look*
like a pure control-rate problem) settles the "did our patches reveal a deeper
issue?" question. Run `wf_a4d7599d-784`; a refutation agent independently
re-derived every number.

**The identical two-phase lock appears on both dates** — 05-30 (heavy WebRTC
control churn) and 06-13 (one lone reconfiguration):

| Phase | Transfer | 05-30 (×3 events) | 06-13 | iso during it |
|---|---|---|---|---|
| 1 | `SET_INTERFACE` alt0 | hang ~5.1–5.5 s → −2 | hang 5.4 s → −2 | **healthy** (5,000+ frames, ~2–22 ms jitter) |
| 2 | `COMMIT_CONTROL` | hang ~7 s → −108 (or 0) | hang 5.5 s → −32 | **wedges** ~26 ms after submit, silent = hang |

The submit→iso-wedge offset on the COMMIT is **25–28 ms on every event, both
captures**. The SET_INTERFACE phase shows iso fully alive (the *same* command
completes in 0.1 ms when healthy — so the 5 s hangs are real failures, not
teardowns).

**Verdict on onion-vs-lens:** mostly *lens* — the same two-phase
reconfiguration lock was operating on 05-30, when we mislabelled it a
"control-rate trigger" because the control-only extract hid the iso plane. The
patches reduced **frequency** (4 crashes/41 min on 05-13 → 2 precursors across
many hours), not the mechanism. **But not pure lens:** the verification refuted
the stronger "every failure is just the iso wedge surfacing through control"
claim — the SET_INTERFACE phase is a *genuine control-plane stall with healthy
iso*, so a real control-plane failure component exists (it is not all iso). That
is the kernel of truth in the original control-rate hypothesis, and the honest
basis for CTRL_THROTTLE's narrow frequency-reducing role.

## Method

Captures auto-preserved by `call-watch.sh` (classifier fixed 06-10 to preserve
on the URB-timeout precursor too). Analysed by a 6-agent forensic workflow
(`wf_ad510e76-ffc`) over the decompressed captures via shell aggregation only
(never loaded into model context); load-bearing findings put through
adversarial-refutation agents that independently re-derived every number. The
05-30↔06-13 cross-capture comparison and the two-phase correction are run
`wf_a4d7599d-784` — whose refutation agent overturned an initial "iso wedges
first / one mechanism" reading, the correction now reflected in §2.
