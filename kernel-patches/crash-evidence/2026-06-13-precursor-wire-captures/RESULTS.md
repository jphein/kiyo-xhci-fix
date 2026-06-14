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

### 2. Failure sequence — one root cause, control stall surfaces LAST

Reconstructed from timestamps (all on camera dev 010):

1. `881770393` — the **single** `VS_COMMIT_CONTROL` SET_CUR of the whole call
   submitted (`s 21 01 0200 0001 001a`, 26 bytes).
2. `881797089` (+27 ms) — iso video EP2 **wedges**: goes silent for **5.46 s**
   (its single largest gap by 200×; one unanswered submit, zero completions).
3. `887254261` — EP2 **recovers** (resumes mid-frame).
4. `887260603` (+6.3 ms) — the hung COMMIT finally drains **−32 (EPIPE)**, 5.49 s
   after submit. It is the **only** −32 on the camera.

The control −32 is the **last-surfacing symptom** of an already-wedged
controller, not an independent initiator — the iso ring even un-wedged ~6 ms
*before* the stalled COMMIT reported. The COMMIT was preceded by a
`SET_INTERFACE` that *also* hung ~5.4 s and completed −2 (ENOENT). Two
consecutive control transfers each hanging ~5.4–5.5 s is a **host-controller-
stopped** signature, not a device-side protocol STALL handshake.

> Conservative framing (verified): the 27 ms COMMIT-precedes-wedge ordering
> shows the COMMIT was outstanding when iso stopped, but cannot prove the COMMIT
> *caused* the wedge vs. both being downstream of the same controller fault. The
> strong, defensible claim is: **single wedge event; the −32 is a symptom, not a
> second failure path.**

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
real failure has **no control-transfer-rate component**, so CTRL_THROTTLE is
structurally incapable of preventing it. The single COMMIT hangs because the
controller is already wedged from the iso side. This is the definitive nail in
the coffin for the uvcvideo-throttle approach (already abandoned 06-07; this is
wire-level confirmation).

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

## Method

Captures auto-preserved by `call-watch.sh` (classifier fixed 06-10 to preserve
on the URB-timeout precursor too). Analysed by a 6-agent forensic workflow over
the decompressed captures via shell aggregation only (never loaded into model
context); two load-bearing findings (EP5-quiet, failure-ordering) put through
adversarial-refutation agents that independently re-derived every number.
Workflow run `wf_ad510e76-ffc`.
