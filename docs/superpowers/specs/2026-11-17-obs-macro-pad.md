# OBS macro pad for katana: a 10-key USB pad, grabbed, driving the call stack

**Author:** nebula (dreamteam, nebula-katana lane). **Date:** 2026-11-17.
**Status:** design, built disabled. The key map goes to JP as one card; the service is enabled only on his word.

**Asked by:** JP, 2026-11-17 11:2x: *"we need to start our macro pad for obs, what's the best cheapest way … a phone
or tablet or cyd s3 black or a 10key usb pad"*. Decision recorded the same hour (memory `katana-camera-stack`): the
10-key USB pad first, Bitfocus Companion as the icon-and-state layer with its web emulator for the phone or tablet,
the CYD S3 as a later dedicated deck.

**Rules carried in from ha, the camera-stack owner (via Sen, 2026-11-17 14:4x):**
1. `flock -n ~/.local/state/camera-stack.lock` before any OBS websocket **write** or any nvpoca touch; back off when
   it is held (ha holds it `-x` during its restart window). Reads need no lock.
2. Work in an own worktree of kiyo-xhci-fix, never the synced checkout.
3. The Kiyo-Call scenes belong to `camera-scene`: never set the program scene directly; add own scenes if needed;
   switch program only through `camera-scene brand|plain`.

---

## 1. What exists today (measured 2026-11-17 14:4x on katana)

| Piece | State |
|---|---|
| The pad | **Plugged in.** `Hailuck Co.,Ltd USB KEYBOARD`, USB `258e:000f`, serial `SN:0009`, on root port 1-9. Three evdev interfaces: `event11` (keyboard), `event12` (consumer control: mute/volume), `event13` (second keyboard). It declares a full keyboard's keys, as these cheap pads do; the keys that physically exist are the numpad set `KP0`–`KP9`, `KPDOT`, `KPENTER`, `KPPLUS`, `KPMINUS`, `KPASTERISK`, `KPSLASH`, `NUMLOCK`, `BACKSPACE`. Today it types into whatever window has focus. |
| OBS | 33.0.0, obs-websocket 5.7.6 on `127.0.0.1:4455` (auth on; password read from OBS's own `plugin_config/obs-websocket/config.json`, as `camera-scene` and `obs-vcam-ctl.py` do). Collection `Kiyo-Call`. Scenes: `right`, `left`, `screen cast`, `Brand over room`, `Kiyo` (program). Virtual camera on; record off; stream off; **no stream service configured** (no `service.json` in the Kiyo-Call profile). |
| Audio | **OBS has no audio input.** The call mic is the Scarlett 2i2 (`alsa_input.usb-Focusrite_Scarlett_2i2_4th_Gen…Mic1__source`) feeding Zoom directly as the PipeWire default source. So "mic mute" is a PipeWire mute, not an OBS one. |
| Camera stack | Kiyo → `nvpoca.service` → `/dev/video11` → OBS → `/dev/video9`. `camera-mode hdr|fast` stops nvpoca, flips HDR, restarts it, proves the mode by fps (drops the picture for ~20 s; refuses during a call unless `--force`). `camera-scene brand|plain` owns the program scene. |
| Wayland | GNOME on Wayland delivers OBS global hotkeys only while OBS is focused. In a meeting Zoom is focused, so a plain hotkey pad fails exactly when it is needed. This is why the pad is grabbed and the actions go over websocket. |
| input-remapper | Running, autoloads a preset for the Logitech receiver only. It does not touch the pad. (It could grab the pad too, but it only emits keys, which lands us back on the hotkey problem.) |
| Companion | Not installed. Bitfocus publishes no GitHub release assets (v5.1.3, 2026-11-12: downloads sit behind a bitfocus.io account). The Docker image `ghcr.io/bitfocus/companion/companion:latest` is public; Docker 29 is on katana. |
| uinput | `/dev/uinput` is `rw` for jp (ACL), so a **fake pad** can be created for tests without grabbing JP's real one. |

## 2. Intent

One press on the pad does the one thing JP needs mid-call, whichever window is focused, without his hands leaving
the desk: scene, mic, camera privacy, record, camera mode. The pad never types into a window again while the
service runs. Later the same actions get icons and state on a phone or tablet (Companion), and a dedicated deck
(CYD S3).

**Goals**
- Works with Zoom focused (the real case). Works with OBS minimised to the tray.
- Every action is the stack's own verb (`camera-scene`, `camera-mode`, obs-websocket, `wpctl`), never a key
  replay; no synthetic input ever reaches JP's windows.
- Safe by construction: respects the camera-stack lock; never sets the program scene itself; never stops the
  virtual camera (Zoom enumerates cameras only at start); never restarts OBS or nvpoca except through `camera-mode`.
- Enabled only after JP has approved the key map on one card.

**Non-goals**
- A GUI. Companion is the GUI.
- Replacing `camera-scene` or `camera-mode`. The pad calls them.
- Streaming. No stream service is configured; the stream key stays unmapped until one is (says so on the card).

**Anti-goals** (would make this a failure even if it "works")
- A press that drops the call picture by stopping the virtual camera or OBS.
- A press that switches the program scene behind `camera-scene`'s back (ha's rule 3).
- A grab that steals a keyboard that is not the pad (match on vendor:product:serial, never on "a keyboard").
- A stuck grab after the service dies (the kernel releases the grab with the fd; the unit never leaves a daemon
  holding it).

## 3. Approaches considered

| | Approach | Why not / why |
|---|---|---|
| A | OBS global hotkeys bound to the numpad | Wayland delivers them only with OBS focused. Fails in meetings. |
| B | input-remapper preset: pad keys → OBS hotkey combos | Same problem as A: it still emits keys that go to the focused window. Also cannot run `camera-mode` or mute PipeWire. |
| C | **A user service grabs the pad via evdev (EVIOCGRAB) and maps each key to a stack verb or websocket call** | Chosen. Works regardless of focus; the pad disappears from the desktop; each action is the verb that already exists. ~200 lines of Python on the venv the stack already uses (`~/.venvs/obsws`, + `evdev`). |
| D | Companion with a Stream Deck | Money and a new device; JP asked for the cheapest. Companion still comes in as the icon layer (its web emulator on the phone) and, once it is configured, as a second front end for the same verbs. |
| E | CYD S3 (ESP32 touch display) via ESPHome → HA → katana | A later deck, not first: needs a bridge from HA to katana's verbs (HA → `ssh katana obs-macro-pad do <verb>` or a tiny HTTP endpoint). The same verb table serves it. Noted in §8; not built. |

## 4. Key map (proposed; JP approves on the card before it is enabled)

The physical numpad, as it sits on the desk:

```
 NumLk   /     *    BkSp
   7     8     9     -
   4     5     6     +
   1     2     3    Ent
      0        .    Ent
```

| Key | Verb | What happens | Via |
|---|---|---|---|
| **1** | `scene plain` | program scene → `Kiyo` (the default look) | `camera-scene plain` |
| **2** | `scene brand` | program scene → `Brand over room` | `camera-scene brand` |
| **3** | *(unmapped)* | reserved for `screen cast` once `camera-scene` grows a verb for it (ha's tool, ha's rule 3) | — |
| **4** | *(unmapped)* | reserved for `left` / `right` likewise | — |
| **5** | `mic toggle` | mute/unmute the call mic (PipeWire default source = Scarlett). **NumLock LED on = muted.** | `wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle` |
| **6** | `camera toggle` | privacy: hide/show the camera sources (`Kiyo Pro`, `Room (raw camera)`) in the **current** scene; the virtual camera keeps running (Zoom stays attached), viewers see the brand or black | obs-websocket `SetSceneItemEnabled` |
| **7** | `record toggle` | start/stop an OBS recording | obs-websocket `ToggleRecord` |
| **8** | `stream toggle` | **unmapped until a stream service exists** (none today); pressing it logs "no stream service" | obs-websocket `ToggleStream`, gated on `GetStreamServiceSettings` |
| **9** | `camera-mode toggle` | HDR-30 ↔ 60 fps. Drops the picture ~20 s; `camera-mode` itself refuses during a call (no `--force` from the pad) | `camera-mode hdr|fast` (last mode kept in `~/.local/state/obs-macro-pad.json`, seeded from `camera-mode status`) |
| **0** | `safe` | back to the default look: `camera-scene plain`, camera sources shown again, mic unmuted | the three verbs above |
| **.** | `status` | one status line to the journal (scene, mic, camera, record, mode) | reads only |
| **Enter** | *(unmapped)* | | |
| **+ − * / BkSp NumLk** | *(unmapped)* | NumLock is swallowed so the LED stays ours | |

Rules the map obeys: every OBS **write** and the `camera-mode` call run under `flock -n` on the camera-stack lock;
held → the press is logged `backed off (lock held)` and nothing happens. Key repeat is ignored (only `value == 1`,
key down). A second press while an action is still running is dropped, not queued.

## 5. The service

- **`katana-av/obs-macro-pad`** (Python, `#!/home/jp/.venvs/obsws/bin/python`; `evdev` added to that venv, recorded
  in `install.sh`). Subcommands: `run` (the daemon), `do <verb>` (one action, for Companion/HA/tests), `status`,
  `map` (print the effective map).
- **Device match (fail closed, after the xreview on PR 26):** the map names the pad's full by-id name up to its
  interface suffix (`usb-Hailuck_Co._Ltd_USB_KEYBOARD_SN:0009`) and its usb id (`258e:000f`); only
  `/dev/input/by-id/<name>[-ifNN]-event-*` is grabbed (whole-name match: an empty or short prefix can never widen to
  the keyboard and mouse; the map check refuses it before any grab), and every interface's `vendor:product` is
  checked at grab, a stranger under that name = refused, exit 2, unit stays stopped (`RestartPreventExitStatus=2`).
  `obs-macro-pad find` prints what `run` would grab. All three interfaces (`event11/12/13` today) are grabbed, the
  consumer-control one too so the pad's volume keys never reach GNOME.
- **Hotplug:** the daemon waits for the device (2 s poll), grabs, reads; on `OSError` (unplug) it releases the pad,
  stops and joins its worker (an in-flight verb finishes first; no thread leaks per unplug) and waits again.
  `Restart=on-failure`.
- **One action at a time, nothing queued:** a press while a verb runs is dropped (`dropped (busy)` in the journal),
  never run later; the busy flag is taken by the accepted press and released when its action has finished.
- **Stop:** `KillMode=mixed` + `TimeoutStopSec=45`: SIGTERM reaches the daemon only (a self-pipe wakes its read
  loop; no `threading.Event` in a signal handler); it finishes the verb in flight with the pad still grabbed and
  the camera-stack lock held, then releases the pad and exits 0; whatever is left in the cgroup when it exits or at
  the timeout is SIGKILLed, so no `camera-mode`/`camera-scene` child outlives the unit. Not an absolute lock
  lifetime: a crash or an over-budget verb ends the flock seconds before the child is killed in the same stop.
- **Worker death:** a press with no live worker ends the daemon with exit 1 (`Restart=on-failure` brings it back)
  instead of latching the busy flag forever.
- **Map:** `katana-av/obs-macro-pad.json` vendored (the table above), copied to `~/.config/obs-macro-pad/map.json`
  by `install.sh` only when none exists (JP's edits stay).
- **Unit:** `obs-macro-pad.service` (user, `graphical-session.target`), installed by `install.sh` and **enabled on
  JP's GO** (card 85e5688df08d, 2026-11-17 17:45). `install.sh` never restarts it (it holds the grab): a new
  version takes effect at the next login or on a restart in a window JP gives.
- **Logs:** one journal line per press: `key=KP5 verb=mic toggle result=muted 41ms` or `backed off (lock held)`.
- **The HTTP side** (`obs-macro-pad serve`, `obs-macro-pad-serve.service`, after the xreview on PR 29): binds a
  loopback IP literal only (anything else = refuse, exit 2, unit stays stopped); every request needs the token
  from `~/.config/obs-macro-pad/token` (0600, 64 hex, made by `install.sh`) as `Authorization: Bearer <t>` or
  Basic with `<t>` as the password (Companion's `pad` connection uses Basic, user `pad`); a request with an
  `Origin` header is refused (403: no page in a browser drives the stack, CSRF or not), `Host` must be loopback
  (403), POST takes no body (400), 8 connections at once (more get 503 at once), a stalled client is dropped
  after 10 s. Unit sandbox: `ProtectSystem=strict`, `PrivateTmp`, `NoNewPrivileges`, `RestrictSUIDSGID`,
  `RestrictRealtime`, `LockPersonality`, `ProtectControlGroups`, `RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6`,
  `SystemCallArchitectures=native`; `camera-mode` runs as a transient user unit outside it
  (`OBS_MACRO_PAD_ESCAPE=systemd-run`) because its wedge recovery is `sudo tee` into sysfs. Measured and NOT
  used: `ProtectHome`/`ReadOnlyPaths=%h` leave home writable in a user unit here. Rollback:
  `systemctl --user disable --now obs-macro-pad-serve.service` + drop the enable/restart lines from `install.sh`.

## 6. Tests (pytest, `tests/test_obs_macro_pad.py`, run on katana)

- The key→verb map loads and names only verbs the dispatcher knows.
- A **fake pad** via `evdev.UInput` (name `Hailuck …`, same keys) is created, the daemon is pointed at it with
  `--device`, keys are injected, and the dispatcher receives the verbs in order; repeats (`value 2`) and key-up are
  ignored; a second press during a running action is dropped. No real device is touched.
- `do status` against the live OBS answers (read-only) and `do stream toggle` refuses with "no stream service".
- The lock: with the lock held by a helper `flock -x`, `do mic toggle` and `do scene plain` return "backed off".
  Nothing in the test suite writes to OBS or PipeWire (`--dry-run` makes the dispatcher log instead of act).

## 7. Companion

- Install: Docker, `--network host` (reaches OBS on 127.0.0.1:4455; serves its UI on `:8000`), config volume
  `companion-config`, `--restart unless-stopped`. No USB passthrough (no Stream Deck).
- OBS module: Companion's OBS connection to `127.0.0.1:4455` with the websocket password; one button per verb in §4
  (scene buttons use the Companion OBS module's **feedback** for the live program scene, so the icon shows state;
  mic/camera/record read state via the pad service's `status`).
- Web emulator: `http://katana:8000/emulator/<id>` on the tablet or phone, same LAN. The link goes on the card.
- The pad service is the one place the verbs live; Companion's "custom command" buttons call `obs-macro-pad do
  <verb>` for anything that is not pure OBS (mic, camera-mode, safe).

## 8. CYD S3 (later, not built)

An ESP32-S3 "Cheap Yellow Display" running ESPHome with a 10-button LVGL grid, publishing a `select`/`button` per
verb to HA; an HA automation (or a tiny HTTP listener on katana, `obs-macro-pad serve`) runs the same verb table.
State back to the deck via HA sensors fed by `obs-macro-pad status --json`. Decide the bridge when it is built.

## 9. Rollout

1. Spec (this file) + service + tests on branch `feat/obs-macro-pad`, PR, self-merge per the standing yes.
2. `install.sh` on katana: unit installed, **disabled**; `evdev` in the venv; map in `~/.config`.
3. Companion container up; OBS connection configured; emulator link proven from the LAN.
4. **One card to JP** (ask, lane admin, `--why-jp his-decision`, `--answer text`): the §4 map, the stream caveat, the
   emulator link, and the question "enable as is, or change which keys?". On "go" the lane runs
   `systemctl --user enable --now obs-macro-pad.service` and tells him the pad now belongs to OBS.

## 10. Left to the builder

Icon art in Companion; whether `.` should speak status through gnome-speaks (no: JP's rule, never during calls);
the exact LED feedback (NumLock = mic muted is the proposal).
