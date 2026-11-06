#!/bin/bash
# Offline test for lib/kiyo-usb.sh against a fixture sysfs tree shaped like
# wakizashi (Kiyo at 6-2.3.2 on the dock's xHCI 0000:3b:00.0) and an empty tree.
# Also guards the 2026-11-06 move off tmpfs: no tool may write valuables to /tmp.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
pass=0; fail=0
ok()  { echo "  [ok]   $1"; pass=$((pass+1)); }
bad() { echo "  [FAIL] $1"; fail=$((fail+1)); }
expect() { # expect <label> <want> <got>
    if [ "$2" = "$3" ]; then ok "$1 = '$3'"; else bad "$1: want '$2', got '$3'"; fi
}

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# --- fixture: wakizashi-shaped sysfs -------------------------------------
fx="$tmp/sys"
pcidev="$fx/devices/pci0000:00/0000:00:1c.4/0000:3b:00.0"
mkdir -p "$pcidev/usb6/6-2/6-2.3/6-2.3.2" "$fx/bus/usb/devices"
echo 1532 > "$pcidev/usb6/6-2/6-2.3/6-2.3.2/idVendor"
echo 0e05 > "$pcidev/usb6/6-2/6-2.3/6-2.3.2/idProduct"
# a non-Kiyo neighbour that must be ignored
mkdir -p "$pcidev/usb6/6-2/6-2.4"; echo 0bda > "$pcidev/usb6/6-2/6-2.4/idVendor"; echo 8153 > "$pcidev/usb6/6-2/6-2.4/idProduct"
ln -s "../../../devices/pci0000:00/0000:00:1c.4/0000:3b:00.0/usb6" "$fx/bus/usb/devices/usb6"
ln -s "../../../devices/pci0000:00/0000:00:1c.4/0000:3b:00.0/usb6/6-2/6-2.3/6-2.3.2" "$fx/bus/usb/devices/6-2.3.2"
ln -s "../../../devices/pci0000:00/0000:00:1c.4/0000:3b:00.0/usb6/6-2/6-2.4" "$fx/bus/usb/devices/6-2.4"

echo "lib/kiyo-usb.sh — wakizashi-shaped fixture"
( KIYO_SYSFS="$fx" KIYO_STATE_ROOT="$tmp/state"; . "$ROOT/lib/kiyo-usb.sh"
  expect "kiyo_usb_ports" "6-2.3.2" "$(kiyo_usb_ports | tr '\n' ' ' | sed 's/ $//')"
  expect "kiyo_xhci_pci_for_port 6-2.3.2" "0000:3b:00.0" "$(kiyo_xhci_pci_for_port 6-2.3.2)"
  expect "kiyo_xhci_pci_for_port on a bus with no root hub" "" "$(kiyo_xhci_pci_for_port 9-1 || true)"
  expect "kiyo_detect_xhci_pci prefers the Kiyo's controller" "0000:3b:00.0" "$(kiyo_detect_xhci_pci 0000:00:14.0)"
  d="$(kiyo_state_dir captures)"
  expect "kiyo_state_dir under KIYO_STATE_ROOT" "$tmp/state/captures" "$d"
  [ -d "$d" ] && ok "kiyo_state_dir creates the directory" || bad "kiyo_state_dir did not create $d"
  case "$pass$fail" in *) exit $fail ;; esac
) ; fail=$((fail + $?))

echo "lib/kiyo-usb.sh — empty sysfs (camera absent)"
mkdir -p "$tmp/empty/bus/usb/devices"
( KIYO_SYSFS="$tmp/empty"; . "$ROOT/lib/kiyo-usb.sh"
  expect "kiyo_usb_ports is empty" "" "$(kiyo_usb_ports)"
  expect "kiyo_detect_xhci_pci falls back" "0000:00:14.0" "$(kiyo_detect_xhci_pci 0000:00:14.0)"
  expect "kiyo_detect_xhci_pci with no fallback is empty" "" "$(kiyo_detect_xhci_pci)"
  exit $fail
) ; fail=$((fail + $?))

echo "default project dir and state root"
( . "$ROOT/lib/kiyo-usb.sh"
  expect "KIYO_PROJECT_DIR is the repo root" "$ROOT" "$KIYO_PROJECT_DIR"
  expect "state dir lands in the gitignored project tmp/" "$ROOT/tmp/watchdog" "$(kiyo_state_dir watchdog)"
  exit $fail
) ; fail=$((fail + $?))

echo "no valuables on tmpfs (static guard)"
# The only /tmp path allowed is the watchdog's Level-4 sentinel, which is MEANT
# to vanish at reboot. Anything else writing under /tmp is a regression.
viol=$(grep -nE '"/tmp/|=/tmp/' "$ROOT/usb-watchdog.sh" "$ROOT/kernel-patches/call-watch.sh" | grep -v 'CLAUDE_SENTINEL=' || true)
if [ -z "$viol" ]; then ok "only the reboot-cleared sentinel lives in /tmp"; else bad "writes under /tmp:"; echo "$viol" | sed 's/^/        /'; fi

echo; echo "fail=$fail (ok lines above are the passes; subshell counts do not propagate)"
[ "$fail" -eq 0 ]
