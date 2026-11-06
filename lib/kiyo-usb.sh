#!/bin/bash
# lib/kiyo-usb.sh — shared helpers for the Kiyo tooling (watchdog, call-watch,
# kiyo-selfcheck). Source it; do not execute it.
#
# Why this exists (2026-11-06): the second Kiyo lives on wakizashi, where the
# camera sits on the Thunderbolt dock's xHCI (0000:3b:00.0), not on the
# 0000:00:14.0 the watchdog had hardcoded for katana. Every tool also wrote its
# valuables to /tmp (a RAM tmpfs on katana), and an 08-25 crash dump had to be
# rescued from there. So: one place that answers "where is the Kiyo", "which
# controller is it on" and "where do files go".
#
# Every sysfs path goes through KIYO_SYSFS so tests can point it at a fixture.

KIYO_VID="${KIYO_VID:-1532}"
KIYO_PID="${KIYO_PID:-0e05}"
KIYO_SYSFS="${KIYO_SYSFS:-/sys}"
KIYO_PROJECT_DIR="${KIYO_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# Every Kiyo port currently in sysfs ("2-1.4", "6-2.3.2"), one per line.
kiyo_usb_ports() {
    local d
    for d in "$KIYO_SYSFS"/bus/usb/devices/*/; do
        [ -f "$d/idVendor" ] || continue
        [ "$(cat "$d/idVendor" 2>/dev/null)" = "$KIYO_VID" ] || continue
        [ "$(cat "$d/idProduct" 2>/dev/null)" = "$KIYO_PID" ] || continue
        basename "$d"
    done
}

# PCI address of the xHCI controller behind a USB port ("6-2.3.2" -> "0000:3b:00.0").
# The bus's root hub (usbN) is a symlink into the PCI device tree; its parent
# directory IS the controller. Empty output when the shape is not PCI-like.
kiyo_xhci_pci_for_port() {
    local port="$1" bus pci
    bus="${port%%-*}"
    [ -n "$bus" ] || return 1
    pci="$(basename "$(readlink -f "$KIYO_SYSFS/bus/usb/devices/usb$bus/.." 2>/dev/null)")"
    case "$pci" in
        [0-9a-f][0-9a-f][0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f].[0-9]) echo "$pci" ;;
        *) return 1 ;;
    esac
}

# Controller of the first Kiyo present, else the given fallback (e.g. the host's
# last known value). Callers re-run this each poll so a camera that moves ports
# moves the recovery target with it.
kiyo_detect_xhci_pci() {
    local fallback="${1:-}" port pci
    for port in $(kiyo_usb_ports); do
        if pci="$(kiyo_xhci_pci_for_port "$port")"; then
            echo "$pci"
            return 0
        fi
    done
    [ -n "$fallback" ] && echo "$fallback"
}

# The controller to act on: a PIN wins outright (a host that wants one fixed
# controller regardless of where a camera shows up); otherwise re-detect from
# the camera present now, keeping the current value as the fallback.
kiyo_resolve_xhci_pci() {   # kiyo_resolve_xhci_pci <current> <pin>
    local current="${1:-}" pin="${2:-}"
    if [ -n "$pin" ]; then echo "$pin"; return 0; fi
    kiyo_detect_xhci_pci "$current"
}

# Durable, non-synced, gitignored state directory for a tool: <project>/tmp/<sub>.
# The project tmp/ is on disk (ext4), ignored by git (tmp/.gitignore) and not
# synced by Syncthing. Never /tmp (RAM) and never /var/tmp (disposable only).
kiyo_state_dir() {
    local d="${KIYO_STATE_ROOT:-$KIYO_PROJECT_DIR/tmp}/$1"
    mkdir -p "$d" 2>/dev/null
    echo "$d"
}
