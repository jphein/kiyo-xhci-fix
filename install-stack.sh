#!/bin/bash
# install-stack.sh — put the whole user-level Kiyo stack on THIS host, the same
# way on every host: udev rule, watchdog sudoers, the three guard units
# (usb-watchdog, call-watch, scarlett-storm-guard) as user services, and the
# kiyo-selfcheck timer. Idempotent. --dry-run prints what it would do.
#
# NOT covered here (each has its own step): the DKMS module (dkms add/build/
# install uvcvideo-kiyo/2.0 from /usr/src/uvcvideo-kiyo-2.0), the optional
# port-level LPM block (usb3-no-lpm/, katana only), ~/.config/usb-watchdog.conf
# for a host whose camera is not on 0000:00:14.0, and the module reload.
# Afterwards: ./kiyo-selfcheck must PASS.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY=0; [ "${1:-}" = "--dry-run" ] && DRY=1
UNITDIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
run() { if [ "$DRY" -eq 1 ]; then echo "would: $*"; else echo "+ $*"; "$@"; fi; }

echo "== udev rule"
run sudo -n install -m 0644 "$HERE/99-razer-kiyo-pro.rules" /etc/udev/rules.d/99-razer-kiyo-pro.rules
run sudo -n udevadm control --reload-rules

echo "== watchdog sudoers (syntax-checked before install)"
if [ "$DRY" -eq 0 ]; then
    sudo -n visudo -cf "$HERE/usb-watchdog-sudoers" >/dev/null
fi
run sudo -n install -m 0440 "$HERE/usb-watchdog-sudoers" /etc/sudoers.d/usb-watchdog

echo "== user units"
run mkdir -p "$UNITDIR"
for u in usb-watchdog call-watch scarlett-storm-guard; do
    src="$HERE/$u.service"; [ "$u" = call-watch ] && src="$HERE/call-watch.service"
    run install -m 0644 "$src" "$UNITDIR/$u.service"
done
run systemctl --user daemon-reload
for u in usb-watchdog call-watch scarlett-storm-guard; do
    run systemctl --user enable --now "$u.service"
done

echo "== self-check timer"
if [ "$DRY" -eq 1 ]; then echo "would: $HERE/install-selfcheck.sh"; else "$HERE/install-selfcheck.sh"; fi

echo "== done — now run: $HERE/kiyo-selfcheck"
