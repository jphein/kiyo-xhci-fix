#!/bin/bash
# USB Watchdog — detects xHCI controller lockups and auto-recovers
# Monitors kernel log for fatal USB errors and escalates recovery
# Runs as a user service with targeted sudoers rules.
#
# Recovery levels:
#   1 — Rebind the specific USB port (Kiyo camera)
#   2 — Full xHCI controller rebind (PCI unbind/bind)
#   3 — Full xHCI driver reload (modprobe -r / modprobe)
#
# Install: ~/Projects/kiyo-xhci-fix/kernel-patches/install-watchdog.sh

XHCI_PCI="0000:00:14.0"
KIYO_VID="1532"
KIYO_PID="0e05"
COOLDOWN=60          # seconds between recovery attempts (from end of last recovery)
LAST_RECOVERY=0
RECOVERING=0         # re-entry guard
CONSEC_FAILS=0       # consecutive failed recoveries
GAVE_UP=0            # set to 1 after all levels fail — stops retrying
LOG_TAG="usb-watchdog"

# Expected USB devices — recovery is not complete until these are present
declare -A EXPECTED_DEVICES=(
    ["Dygma keyboard"]="1209:2201"
    ["Logitech receiver"]="046d:c548"
)

log() { logger -t "$LOG_TAG" "$1"; echo "$(date '+%H:%M:%S') $1"; }

find_kiyo_port() {
    for dev in /sys/bus/usb/devices/*/; do
        if [ -f "$dev/idVendor" ] && \
           [ "$(cat "$dev/idVendor" 2>/dev/null)" = "$KIYO_VID" ] && \
           [ "$(cat "$dev/idProduct" 2>/dev/null)" = "$KIYO_PID" ]; then
            basename "$dev"
            return 0
        fi
    done
    return 1
}

check_hid_alive() {
    # If any HID device has vanished from sysfs, the controller is likely wedged
    local hid_count
    hid_count=$(find /sys/bus/usb/devices/*/driver -maxdepth 0 -name "usbhid" 2>/dev/null | \
                xargs -I{} dirname {} 2>/dev/null | wc -l)
    if [ "$hid_count" -lt 2 ]; then
        return 1  # fewer than 2 HID devices = likely dead
    fi
    return 0
}

check_expected_devices() {
    # Verify that ALL expected USB devices are present in sysfs
    local missing=0
    for name in "${!EXPECTED_DEVICES[@]}"; do
        local vidpid="${EXPECTED_DEVICES[$name]}"
        local vid="${vidpid%%:*}"
        local pid="${vidpid##*:}"
        local found=0
        for dev in /sys/bus/usb/devices/*/; do
            if [ -f "$dev/idVendor" ] && \
               [ "$(cat "$dev/idVendor" 2>/dev/null)" = "$vid" ] && \
               [ "$(cat "$dev/idProduct" 2>/dev/null)" = "$pid" ]; then
                found=1
                break
            fi
        done
        if [ "$found" -eq 0 ]; then
            log "HEALTH: $name ($vidpid) NOT found"
            missing=$((missing + 1))
        fi
    done
    return "$missing"
}

dump_crash_log() {
    local logfile="/tmp/usb-watchdog-crash-$(date '+%Y%m%d-%H%M%S').log"
    {
        echo "=== USB Watchdog Crash Dump ==="
        echo "Timestamp: $(date)"
        echo ""
        echo "=== Last 50 lines of dmesg ==="
        dmesg | tail -50
        echo ""
        echo "=== USB devices ==="
        lsusb 2>/dev/null || echo "(lsusb not available)"
        echo ""
        echo "=== HID devices in sysfs ==="
        find /sys/bus/usb/devices/*/driver -maxdepth 0 -name "usbhid" 2>/dev/null | \
            xargs -I{} dirname {} 2>/dev/null
        echo ""
        echo "=== Expected device check ==="
        for name in "${!EXPECTED_DEVICES[@]}"; do
            local vidpid="${EXPECTED_DEVICES[$name]}"
            local vid="${vidpid%%:*}"
            local pid="${vidpid##*:}"
            local status="MISSING"
            for dev in /sys/bus/usb/devices/*/; do
                if [ -f "$dev/idVendor" ] && \
                   [ "$(cat "$dev/idVendor" 2>/dev/null)" = "$vid" ] && \
                   [ "$(cat "$dev/idProduct" 2>/dev/null)" = "$pid" ]; then
                    status="PRESENT"
                    break
                fi
            done
            echo "  $name ($vidpid): $status"
        done
    } > "$logfile" 2>&1
    log "Crash log saved to $logfile"
}

health_check() {
    # Combined health check: HID alive AND expected devices present
    check_hid_alive || return 1
    check_expected_devices || return 1
    return 0
}

recover() {
    # Prevent re-entry — recovery generates kernel messages that match our patterns
    if [ "$RECOVERING" -eq 1 ]; then
        return
    fi

    local now
    now=$(date +%s)
    if (( now - LAST_RECOVERY < COOLDOWN )); then
        return  # silent skip during cooldown — no log to avoid noise
    fi

    if [ "$GAVE_UP" -eq 1 ]; then
        return  # all levels exhausted — don't hammer a wedged controller
    fi

    RECOVERING=1
    LAST_RECOVERY=$now

    # Save crash context
    dump_crash_log

    # Level 1: Try to reset just the Kiyo's USB port
    local port
    port=$(find_kiyo_port)
    if [ -n "$port" ]; then
        log "LEVEL 1: Unbinding Kiyo port $port..."
        echo "$port" | sudo tee /sys/bus/usb/drivers/usb/unbind >/dev/null 2>&1
        sleep 2
        echo "$port" | sudo tee /sys/bus/usb/drivers/usb/bind >/dev/null 2>&1
        sleep 3

        if health_check; then
            log "LEVEL 1 OK: All devices alive after port rebind"
            LAST_RECOVERY=$(date +%s); RECOVERING=0; CONSEC_FAILS=0
            return
        fi
    fi

    # Level 2: Full xHCI controller rebind (single attempt — retries make wedged controllers worse)
    log "LEVEL 2: Full xHCI rebind ($XHCI_PCI)..."
    echo "$XHCI_PCI" | sudo tee /sys/bus/pci/drivers/xhci_hcd/unbind >/dev/null 2>&1
    sleep 5
    echo "$XHCI_PCI" | sudo tee /sys/bus/pci/drivers/xhci_hcd/bind >/dev/null 2>&1
    sleep 10

    if health_check; then
        log "LEVEL 2 OK: All devices alive after xHCI rebind"
        LAST_RECOVERY=$(date +%s); RECOVERING=0; CONSEC_FAILS=0
        return
    fi

    # Level 3: Full xHCI driver reload (single attempt)
    log "LEVEL 3: Full driver reload..."
    sudo /sbin/modprobe -r xhci_pci xhci_pci_renesas 2>&1 | while read -r l; do log "modprobe-r: $l"; done
    sleep 3
    sudo /sbin/modprobe xhci_pci xhci_pci_renesas 2>&1 | while read -r l; do log "modprobe: $l"; done
    sleep 12

    if health_check; then
        log "LEVEL 3 OK: All devices alive after driver reload"
        LAST_RECOVERY=$(date +%s); RECOVERING=0; CONSEC_FAILS=0
        return
    fi

    # All levels exhausted — STOP, don't retry. Controller is wedged, needs reboot.
    log "ALL LEVELS FAILED — controller is wedged. Stopping recovery to prevent cascade."
    log "ACTION REQUIRED: Reboot to restore USB. Watchdog will not retry."
    dump_crash_log
    LAST_RECOVERY=$(date +%s)
    RECOVERING=0
    GAVE_UP=1
}

log "Started — watching for xHCI lockups on $XHCI_PCI"
log "Expected devices:"
for name in "${!EXPECTED_DEVICES[@]}"; do
    log "  $name: ${EXPECTED_DEVICES[$name]}"
done

# Initial health check
if health_check; then
    log "Initial health check PASSED — all expected devices present"
else
    log "Initial health check WARNING — some expected devices missing (see above)"
fi

# Watch kernel log for fatal USB/xHCI error patterns
journalctl -k -f --no-pager | while read -r line; do
    case "$line" in
        *"HC died"*|*"Host System Error"*|*"host system error"*)
            log "FATAL: xHCI host controller died — initiating recovery"
            recover
            ;;
        *"xHCI host not responding"*|*"xhci_hcd"*"not responding to stop"*)
            log "FATAL: xHCI not responding — initiating recovery"
            recover
            ;;
        *"Cannot set alt interface"*"ret = -19"*|*"usb_set_interface failed"*"-19"*)
            # -19 = ENODEV, device gone mid-transfer
            log "WARNING: USB device gone (-19) — checking health"
            sleep 2
            health_check || recover
            ;;
        *"device descriptor read"*"error -110"*|*"device not accepting address"*"error -110"*)
            # -110 = ETIMEDOUT, controller may be wedging
            log "WARNING: USB timeout (-110) — checking health"
            sleep 5
            health_check || recover
            ;;
        *"uvcvideo"*"error -71"*|*"uvcvideo"*"error -32"*)
            # UVC protocol/pipe errors — camera crashing, check if it cascades
            log "WARNING: UVC error on camera — monitoring for cascade"
            sleep 5
            health_check || recover
            ;;
        *"USB disconnect"*"$XHCI_PCI"*)
            # Mass disconnect event on our controller
            sleep 2
            health_check || {
                log "FATAL: Mass USB disconnect — initiating recovery"
                recover
            }
            ;;
    esac
done
