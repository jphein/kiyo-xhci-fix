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
ln -sfn "$HERE/audio-selfcheck" "$HOME/.local/bin/audio-selfcheck"
ln -sfn "$HERE/av-selfcheck" "$HOME/.local/bin/av-selfcheck"
systemctl --user daemon-reload
systemctl --user enable audio-watchdog.service
systemctl --user restart audio-watchdog.service
systemctl --user enable --now audio-selfcheck.timer
systemctl --user --no-pager --lines=0 status audio-watchdog.service | head -3
systemctl --user list-timers audio-selfcheck.timer --no-pager
echo "installed: audio-watchdog.service -> $HERE/audio-watchdog.sh; ~/.local/bin/{audio,av}-selfcheck; audio-selfcheck.timer"
