#!/bin/bash
# Install kiyo-selfcheck as a user timer (after boot + daily) and on PATH.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNITDIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
mkdir -p "$UNITDIR" "$HOME/.local/bin"
cp "$HERE/kiyo-selfcheck.service" "$HERE/kiyo-selfcheck.timer" "$UNITDIR/"
ln -sfn "$HERE/kiyo-selfcheck" "$HOME/.local/bin/kiyo-selfcheck"
systemctl --user daemon-reload
systemctl --user enable --now kiyo-selfcheck.timer
systemctl --user list-timers kiyo-selfcheck.timer --no-pager
echo "installed: ~/.local/bin/kiyo-selfcheck, user timer kiyo-selfcheck.timer (logs: $HERE/scratch/selfcheck/)"
