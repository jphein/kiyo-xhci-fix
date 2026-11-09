# katana Intel iGPU for hardware call encoding (prepared 2026-11-09, luna-katana-av)

JP 2026-11-09 07:5x: "yes make sure we enable that intel on the next reboot". BIOS step = card 9f89bcae3fe1.

## Why
- The 11-09 test call: Brave encoded 1080p in **software** (Brave 66→82 % CPU); from 07:07 the far end got only the
  180–360p layers, with 0 packet loss.
- katana has no hardware encode for Brave today: `nvidia-vaapi-driver` is **decode-only** ("VA-API NVDEC driver", no
  `VAEntrypointEnc*`), Chromium on Linux encodes WebRTC in hardware only via VA-API (never NVENC), and the Intel iGPU is off.
- Found on the way: Brave's launcher (`/opt/brave.com/brave/brave-browser`) passes only `"$@"`; `~/.config/brave-flags.conf`
  is never read. The running Brave (07:24) had **no** flags, so the VA-API *decode* flags there were never live either.
- The i7-9700K has UHD 630 (not an F part). Its iHD driver (intel-media-va-driver 26.1.2, installed) encodes H.264, VP8, VP9.

## What is ready (nothing in JP's session changes until "igd on")
| file | does |
|---|---|
| `igd-selfcheck` | PASS/FAIL per layer: iGPU on PCI 00:02.0, i915/xe bound, NVIDIA still `boot_vga` (primary), Intel render node, intel-media-va-driver, iHD H.264 encode entrypoint, wrapper, launcher |
| `brave-vaapi` | launches Brave with `LIBVA_DRIVER_NAME=iHD`, `--render-node-override=<Intel node>`, `--enable-features=AcceleratedVideoEncoder,VaapiVideoEncoder,VaapiVideoDecoder,VaapiVideoDecodeLinuxGL,VaapiIgnoreDriverChecks`; **Brave only** (the env never reaches mpv/OBS/GNOME). No Intel node → plain Brave, unchanged. Log `~/.local/state/brave-vaapi.log` |
| `igd-enable` / `igd-disable` | enable: runs igd-selfcheck, refuses on FAIL, then points `~/.local/share/applications/brave-browser.desktop` at the wrapper (backup kept). disable: restores. Neither restarts Brave |

## On JP's "igd on" (agent steps)
1. `katana-av/igd/igd-selfcheck`. FAIL → stop, report the failing line (most likely: primary display set to IGD, or i915 not bound).
2. `katana-av/igd/igd-enable`.
3. One plan-chat line: "restart Brave when convenient (tabs come back)". Then check the new Brave's GPU process carries
   `--render-node-override=<Intel node>` and the features; `~/.local/state/brave-vaapi.log` says "VA-API on".

## Measurement (same as 11-09, before vs after)
Same room `meet.ffmuc.net/katana-av-test-86da8861`, `call-probe` on familiar with JP pinned (receiver constraints 1080),
10 min, OBS Virtual Camera as the source (OBS holds the Kiyo).
- far end: resolution + fps over time, freezes, layer drops (11-09 baseline: 1080p30 for 5 min, then 180–360p from 07:07:21)
- katana: Brave CPU % every 30 s (baseline 66–82 %), and **proof the encoder is on the iGPU**: the Brave GPU process's
  `/proc/<pid>/fdinfo/*` for the Intel render node show `drm-engine-video` busy time rising during the call (no extra tools)
- audio unchanged: mic-measure over the call (baseline 0 dropouts / 0 xruns)

## Risks to the NVIDIA-only Wayland session, and the rollback
- **Primary display.** If the BIOS makes the iGPU primary (IGD instead of PEG), mutter renders on Intel and copies every frame to
  the NVIDIA outputs: stutter or a black login. igd-selfcheck FAILs on `boot_vga` for exactly this. Rollback: BIOS → Primary
  Display = PEG (or IGD Multi-Monitor = Disabled).
- **A second render GPU in GNOME.** mutter already runs multi-GPU on katana (four DisplayLink/evdi cards), so one more secondary
  GPU with no monitor is the same class. switcheroo-control is installed: it picks the `boot_vga` GPU (NVIDIA) as the default, so
  apps keep starting on NVIDIA; "Launch using Discrete Graphics" would read oddly (both are "discrete" to it). Not a functional risk.
- **Render node numbering may change** (`renderD128` could become Intel). Chromium's own default is "the first render node", so
  plain Brave could silently pick Intel for decode: harmless (UHD 630 decodes H.264/VP9/HEVC) and visible in the GPU process args.
  The wrapper always names the node by PCI path, never by number.
- **Vulkan/EGL apps listing two devices** (Ghostty, OBS): they choose the display's device (NVIDIA) on Wayland; OBS's NVENC goes
  through CUDA, unaffected.
- **Power:** a few watts for an idle iGPU.
- **Not touched:** GRUB, the NVIDIA driver, nvidia-drm.modeset, initramfs.
- **Full rollback:** `katana-av/igd/igd-disable` (launcher back), BIOS IGD Multi-Monitor = Disabled.
