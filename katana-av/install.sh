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
# nvpoca.service: copied, never restarted here (a restart reopens the Kiyo = the wedge trigger, and drops a call).
# It runs ~/.local/opt/nvpoca with nvpoca-patches/0001+0002 applied (README). /dev/video12 needs v4l2loopback.conf in
# /etc/modprobe.d (sudo, by hand) or `sudo v4l2loopback-ctl add -n "nvpoca Room" -x 1 -b 2 /dev/video12` live.
cp "$HERE/nvpoca.service" "$UNITDIR/"
systemctl --user daemon-reload
systemctl --user enable audio-watchdog.service
systemctl --user restart audio-watchdog.service
systemctl --user enable --now audio-selfcheck.timer
systemctl --user --no-pager --lines=0 status audio-watchdog.service | head -3
systemctl --user list-timers audio-selfcheck.timer --no-pager
echo "installed: audio-watchdog.service -> $HERE/audio-watchdog.sh; ~/.local/bin/{audio,av}-selfcheck, camera-mode; audio-selfcheck.timer; obs-vcam.service (not restarted)"
