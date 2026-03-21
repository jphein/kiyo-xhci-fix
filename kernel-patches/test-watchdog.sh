#!/bin/bash
# Test the USB watchdog by simulating a crash (unbind xHCI controller)
# This will momentarily disconnect ALL USB devices on the controller!
#
# Prerequisites:
#   - usb-watchdog.service running (systemctl --user status usb-watchdog)
#   - sudoers rules installed (install-watchdog.sh)
#
# What this does:
#   1. Verifies the watchdog is running
#   2. Records current USB device state
#   3. Unbinds the xHCI controller (simulates crash)
#   4. Waits for the watchdog to detect and recover
#   5. Verifies expected devices come back

set -euo pipefail

XHCI_PCI="0000:00:14.0"
TIMEOUT=120  # max seconds to wait for recovery

declare -A EXPECTED_DEVICES=(
    ["Dygma keyboard"]="1209:2201"
    ["Logitech receiver"]="046d:c548"
)

echo "=== USB Watchdog Recovery Test ==="
echo ""
echo "WARNING: This will temporarily disconnect ALL USB devices!"
echo "         Make sure you have an alternative input method."
echo ""
read -r -p "Continue? [y/N] " confirm
if [[ "$confirm" != [yY] ]]; then
    echo "Aborted."
    exit 0
fi

# Check watchdog is running
echo "[1/5] Checking watchdog service..."
if ! systemctl --user is-active usb-watchdog.service >/dev/null 2>&1; then
    echo "ERROR: usb-watchdog.service is not running!"
    echo "  Start it first: systemctl --user start usb-watchdog.service"
    exit 1
fi
echo "  Watchdog is active"

# Record current state
echo "[2/5] Recording current USB state..."
echo "  Current USB devices:"
lsusb 2>/dev/null | while read -r line; do echo "    $line"; done

for name in "${!EXPECTED_DEVICES[@]}"; do
    vidpid="${EXPECTED_DEVICES[$name]}"
    vid="${vidpid%%:*}"
    pid="${vidpid##*:}"
    found=0
    for dev in /sys/bus/usb/devices/*/; do
        if [ -f "$dev/idVendor" ] && \
           [ "$(cat "$dev/idVendor" 2>/dev/null)" = "$vid" ] && \
           [ "$(cat "$dev/idProduct" 2>/dev/null)" = "$pid" ]; then
            found=1
            break
        fi
    done
    if [ "$found" -eq 1 ]; then
        echo "  $name ($vidpid): PRESENT"
    else
        echo "  $name ($vidpid): NOT FOUND (test may not fully validate)"
    fi
done

# Simulate crash
echo ""
echo "[3/5] Simulating xHCI crash — unbinding $XHCI_PCI..."
echo "$XHCI_PCI" | sudo tee /sys/bus/pci/drivers/xhci_hcd/unbind >/dev/null 2>&1
echo "  Controller unbound — USB devices disconnected"

# Wait for watchdog recovery
echo ""
echo "[4/5] Waiting for watchdog to detect and recover (timeout: ${TIMEOUT}s)..."
start_time=$(date +%s)
recovered=0

while true; do
    elapsed=$(( $(date +%s) - start_time ))
    if (( elapsed >= TIMEOUT )); then
        break
    fi

    # Check if controller is rebound
    if [ -d "/sys/bus/pci/drivers/xhci_hcd/$XHCI_PCI" ]; then
        # Controller is back — check devices
        sleep 3  # give devices time to enumerate
        all_present=1
        for name in "${!EXPECTED_DEVICES[@]}"; do
            vidpid="${EXPECTED_DEVICES[$name]}"
            vid="${vidpid%%:*}"
            pid="${vidpid##*:}"
            found=0
            for dev in /sys/bus/usb/devices/*/; do
                if [ -f "$dev/idVendor" ] && \
                   [ "$(cat "$dev/idVendor" 2>/dev/null)" = "$vid" ] && \
                   [ "$(cat "$dev/idProduct" 2>/dev/null)" = "$pid" ]; then
                    found=1
                    break
                fi
            done
            if [ "$found" -eq 0 ]; then
                all_present=0
            fi
        done

        if [ "$all_present" -eq 1 ]; then
            recovered=1
            break
        fi
    fi

    printf "\r  Waiting... %ds / %ds" "$elapsed" "$TIMEOUT"
    sleep 2
done
echo ""

# Verify
echo ""
echo "[5/5] Results:"
if [ "$recovered" -eq 1 ]; then
    elapsed=$(( $(date +%s) - start_time ))
    echo "  SUCCESS: Recovery completed in ${elapsed}s"
    echo ""
    echo "  Device status after recovery:"
    for name in "${!EXPECTED_DEVICES[@]}"; do
        vidpid="${EXPECTED_DEVICES[$name]}"
        vid="${vidpid%%:*}"
        pid="${vidpid##*:}"
        found=0
        for dev in /sys/bus/usb/devices/*/; do
            if [ -f "$dev/idVendor" ] && \
               [ "$(cat "$dev/idVendor" 2>/dev/null)" = "$vid" ] && \
               [ "$(cat "$dev/idProduct" 2>/dev/null)" = "$pid" ]; then
                found=1
                break
            fi
        done
        if [ "$found" -eq 1 ]; then
            echo "    $name ($vidpid): PRESENT"
        else
            echo "    $name ($vidpid): MISSING"
        fi
    done
    echo ""
    echo "  Watchdog log (last 20 lines):"
    journalctl --user -u usb-watchdog.service --no-pager -n 20 2>/dev/null | \
        while read -r line; do echo "    $line"; done
else
    echo "  FAILED: Recovery did not complete within ${TIMEOUT}s"
    echo ""
    echo "  Controller bound: $([ -d "/sys/bus/pci/drivers/xhci_hcd/$XHCI_PCI" ] && echo YES || echo NO)"
    echo ""
    echo "  Watchdog log (last 30 lines):"
    journalctl --user -u usb-watchdog.service --no-pager -n 30 2>/dev/null | \
        while read -r line; do echo "    $line"; done
    echo ""
    echo "  You may need to manually rebind:"
    echo "    echo $XHCI_PCI | sudo tee /sys/bus/pci/drivers/xhci_hcd/bind"
    exit 1
fi
