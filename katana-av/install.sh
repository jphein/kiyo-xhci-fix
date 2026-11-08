#!/bin/bash
# Install audio-selfcheck as a user timer (3 min after boot + daily) and put
# audio-selfcheck + av-selfcheck on PATH. Idempotent.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNITDIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
mkdir -p "$UNITDIR" "$HOME/.local/bin"
cp "$HERE/audio-selfcheck.service" "$HERE/audio-selfcheck.timer" "$UNITDIR/"
ln -sfn "$HERE/audio-selfcheck" "$HOME/.local/bin/audio-selfcheck"
ln -sfn "$HERE/av-selfcheck" "$HOME/.local/bin/av-selfcheck"
systemctl --user daemon-reload
systemctl --user enable --now audio-selfcheck.timer
systemctl --user list-timers audio-selfcheck.timer --no-pager
echo "installed: ~/.local/bin/{audio,av}-selfcheck, user timer audio-selfcheck.timer (logs: $HERE/../scratch/selfcheck/<host>-audio*)"
