#!/bin/bash
# Install katana's call-audio layer from this directory. Idempotent.
#   - audio-watchdog.service (user) runs katana-av/audio-watchdog.sh; restarted so a new
#     version takes effect (it only re-pins PipeWire settings; it never restarts PipeWire)
#   - audio-selfcheck.timer: 3 min after boot + daily, --log
#   - audio-selfcheck + av-selfcheck on PATH
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNITDIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
mkdir -p "$UNITDIR" "$HOME/.local/bin"
cp "$HERE/audio-watchdog.service" "$HERE/audio-selfcheck.service" "$HERE/audio-selfcheck.timer" "$UNITDIR/"
# obs-vcam: the unit + its after-nvpoca drop-in. Not restarted here (that would drop a call). daemon-reload applies the
# new Restart= policy to the running OBS at once; ExecStartPre changes apply at its next start.
mkdir -p "$UNITDIR/obs-vcam.service.d"
cp "$HERE/obs-vcam.service" "$UNITDIR/"
cp "$HERE/obs-vcam-after-nvpoca.conf" "$UNITDIR/obs-vcam.service.d/10-after-nvpoca.conf"
ln -sfn "$HERE/audio-selfcheck" "$HOME/.local/bin/audio-selfcheck"
ln -sfn "$HERE/av-selfcheck" "$HOME/.local/bin/av-selfcheck"
ln -sfn "$HERE/camera-mode" "$HOME/.local/bin/camera-mode"
ln -sfn "$HERE/camera-scene" "$HOME/.local/bin/camera-scene"
ln -sfn "$HERE/camera-up" "$HOME/.local/bin/camera-up"
# obs-macro-pad: unit + default map installed; the unit is enabled (JP's GO 2026-11-17) but NEVER restarted here: it
# holds the pad grab, and a new version takes effect at the next login or `systemctl --user restart obs-macro-pad`
# in a window JP gives. Needs evdev in the obsws venv:
#   uv pip install --python ~/.venvs/obsws/bin/python evdev   (done 2026-11-17; the venv has no pip)
ln -sfn "$HERE/obs-macro-pad" "$HOME/.local/bin/obs-macro-pad"
cp "$HERE/obs-macro-pad.service" "$HERE/obs-macro-pad-serve.service" "$UNITDIR/"
mkdir -p "$HOME/.config/obs-macro-pad"
MAP="$HOME/.config/obs-macro-pad/map.json"
[ -e "$MAP" ] || cp "$HERE/obs-macro-pad.json" "$MAP"
# the map must carry the pad's usb vendor/product (checked on every grab, PR after xreview on #26): an older copy
# gets them from the vendored map, JP's keys untouched
if ! grep -q '"vendor"' "$MAP"; then
    jq -s '.[1] + {vendor: .[0].vendor, product: .[0].product}' "$HERE/obs-macro-pad.json" "$MAP" > "$MAP.tmp" && mv "$MAP.tmp" "$MAP"
fi
"$HERE/obs-macro-pad" map > /dev/null || { echo "install.sh: $MAP is not a valid map (obs-macro-pad map)"; exit 1; }
# nvpoca.service: copied, never restarted here (a restart reopens the Kiyo = the wedge trigger, and drops a call).
# It runs ~/.local/opt/nvpoca with nvpoca-patches/0001+0002 applied (README). /dev/video12 needs v4l2loopback.conf in
# /etc/modprobe.d (sudo, by hand) or `sudo v4l2loopback-ctl add -n "nvpoca Room" -x 1 -b 2 /dev/video12` live.
cp "$HERE/nvpoca.service" "$UNITDIR/"
systemctl --user daemon-reload
systemctl --user enable audio-watchdog.service
systemctl --user restart audio-watchdog.service
systemctl --user enable --now audio-selfcheck.timer
# the HTTP side grabs nothing: enabled now, restarted so a new version serves (Companion/HA call it on 127.0.0.1:8765).
# Every caller presents the token below (Companion: the "pad" connection's Basic auth, password = token).
# Rollback: `systemctl --user disable --now obs-macro-pad-serve.service` and remove these three lines.
TOKEN="$HOME/.config/obs-macro-pad/token"
[ -s "$TOKEN" ] || ( umask 077; head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$TOKEN" )
chmod 0600 "$TOKEN"
systemctl --user enable obs-macro-pad-serve.service
systemctl --user restart obs-macro-pad-serve.service
systemctl --user --no-pager --lines=0 status audio-watchdog.service | head -3
systemctl --user list-timers audio-selfcheck.timer --no-pager
echo "installed: audio-watchdog.service -> $HERE/audio-watchdog.sh; ~/.local/bin/{audio,av}-selfcheck, camera-mode, obs-macro-pad (unit copied, not restarted), obs-macro-pad-serve (enabled, :8765); audio-selfcheck.timer; obs-vcam.service (not restarted)"
