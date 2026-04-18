# Kiyo Pro xHCI test matrix

Replication matrix for the v7/v8 reply on LKML. Answers: does
CTRL_THROTTLE still earn its keep once Michal's xhci-ring fix is
applied?

## The matrix

Five cells × two workloads × N reps (default 5) = 50 runs.

| Cell | Kernel          | `usbcore.quirks` | `uvcvideo` module |
|------|-----------------|------------------|-------------------|
| 1    | stock 6.17      | —                | stock             |
| 2    | stock + michal  | —                | stock             |
| 3    | stock 6.17      | `1532:0e05:k`    | stock             |
| 4    | stock 6.17      | `1532:0e05:k`    | patched (throttle)|
| 5    | stock + michal  | `1532:0e05:k`    | patched (throttle)|

Workloads:
- **spam-only** — `stress-test-kiyo.sh` for 100 rounds, no video stream
- **spam-stream** — same, but with a 120s ffmpeg v4l2 pull running in parallel

## Boot configs

Four distinct boots cover all five cells:

| Boot | Kernel | Cmdline addition       | Cells runnable in this boot |
|------|--------|------------------------|-----------------------------|
| A    | stock  | —                      | 1                           |
| B    | stock  | `usbcore.quirks=1532:0e05:k` | 3, 4 (swap module in-place) |
| C    | michal | —                      | 2                           |
| D    | michal | `usbcore.quirks=1532:0e05:k` | 5                          |

The runner swaps the `uvcvideo` module in place when moving between
cells 3 and 4 (both use boot B). All other cell transitions need a
reboot.

## Setup (on a fresh Ubuntu box)

```
git clone https://github.com/jphein/kiyo-xhci-fix.git ~/Projects/kiyo-xhci-fix
cd ~/Projects/kiyo-xhci-fix/kernel-patches/matrix
bash bootstrap.sh
```

`bootstrap.sh` does:
1. `apt install` build deps, v4l-utils, ffmpeg
2. Build patched `uvcvideo.ko` (CTRL_THROTTLE)
3. Build 6.x kernel with `michal-xhci-test.patch` applied (slow)
4. Install `matrix-queue.service` systemd unit
5. Generate `queue.txt` with 5 reps per (cell, workload)

Grub entries are NOT auto-configured — you add them by hand or edit
`GRUB_CMDLINE_LINUX_DEFAULT` between configs. See bootstrap output
for suggested menuentry shapes.

## Running

Pre-flight (do this manually for the first rep to verify detection):
```
# Boot into config A (stock kernel, no usbcore.quirks)
# Kiyo Pro plugged in, /dev/video0 visible
bash queue.sh
```

Inspect `results/cell1_spam-only_rep1/` — check `verdict`,
`dmesg.delta`, `env.txt` all look right.

Once confident, enable the systemd unit and walk away:
```
sudo systemctl enable --now matrix-queue.service
tail -f results/queue.log
```

The service runs on every boot. If the runner exits with code 100
(HC died), `queue.sh` auto-reboots and the service picks up the
next rep when the system comes back. Between reps in different boot
configs, the runner reports `SKIP: config mismatch (needs reboot)`
and JP reboots into the right config manually.

**Pause:** `touch /tmp/kiyo-matrix-pause` — queue.sh respects this
on next invocation.

## Understanding results

```
bash summary.sh
```

Outputs a markdown table suitable for pasting into the v8 cover
letter or the LKML reply. Raw data at `results/summary.tsv`.

Per-rep artifacts in `results/cell<N>_<workload>_rep<M>/`:
- `verdict` — one-line PASS/FAIL/WARN/SKIP with reason
- `dmesg.delta` — kernel log lines produced during the run
- `workload.log` — stress-test output
- `stream.log` — ffmpeg output (spam-stream only)
- `env.txt` — uname, cmdline, loaded modules at run time
- `runner.log` — runner's own narration

## Verdict rules

The runner classifies by grepping `dmesg.delta` in this order:

| Pattern                                             | Verdict |
|-----------------------------------------------------|---------|
| `xhci_hc_died` / `HC died` / `Host halt failed` / `probably busted` | FAIL (hc-died) |
| `event condition 198`                               | FAIL (event-198) |
| camera unresponsive post-run                        | FAIL (camera-unresponsive-post) |
| stress-test timeout (>180s)                         | FAIL (stress-test-timeout) |
| stress-test non-zero exit (and no HC death)         | FAIL (stress-test-exit-N) |
| `Stop Endpoint timeout` or `Command timeout USBSTS` without HC death | WARN (stop-ep-timeout-no-hc-death) |
| none of the above                                   | PASS (clean) |

The runner signals "reboot required" (exit 100) only for HC-death,
event-198, and post-run unresponsive. WARN and soft-FAIL are
considered recoverable without reboot.

## Reordering the queue

`setup.sh` emits the queue in cell order (1 → 5). To minimise
reboots, group by boot config:

```
# Boot A — cell 1 only
1  spam-only   1..5
1  spam-stream 1..5
# Reboot into boot B — cells 3 and 4 (module swap in place)
3  spam-only   1..5
3  spam-stream 1..5
4  spam-only   1..5
4  spam-stream 1..5
# Reboot into boot C — cell 2
2  spam-only   1..5
2  spam-stream 1..5
# Reboot into boot D — cell 5
5  spam-only   1..5
5  spam-stream 1..5
```

Just hand-edit `results/queue.txt` after `setup.sh` runs.

## Known gotchas

- **Dynamic debug noise:** xhci_hcd dynamic debug produces a lot of
  kernel log output. `dmesg.pre` / `dmesg.post` can get large. Expected.
- **HWE timing:** on Ubuntu 24.04 HWE, `linux-source-6.17` may lag
  the `linux-image` version. Bootstrap falls back to kernel.org if
  apt source isn't available.
- **`uvcvideo-patched.ko` is kernel-specific.** Rebuild it when you
  change kernels: `bash $REPO_DIR/kernel-patches/build-uvc-module.sh`
- **Secure Boot must be off** on the test machine (stock Ubuntu
  distro kernels are signed; Michal's custom build isn't).
