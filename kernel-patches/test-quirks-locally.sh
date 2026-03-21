#!/bin/bash
# Test the Razer Kiyo Pro quirks WITHOUT recompiling the kernel.
# These apply the same effects at runtime via sysfs/module params.
#
# Run as root: sudo bash test-quirks-locally.sh

set -e

KIYO_VID="1532"
KIYO_PID="0e05"

echo "=== Razer Kiyo Pro Quirk Test ==="
echo ""

# 1. Disable LPM for the device (mirrors USB_QUIRK_NO_LPM)
echo "[1/3] Disabling USB LPM for Kiyo Pro..."
for dev in /sys/bus/usb/devices/*/; do
    if [ -f "$dev/idVendor" ] && \
       [ "$(cat "$dev/idVendor" 2>/dev/null)" = "$KIYO_VID" ] && \
       [ "$(cat "$dev/idProduct" 2>/dev/null)" = "$KIYO_PID" ]; then
        devpath=$(basename "$dev")
        # Disable LPM
        if [ -f "$dev/power/usb2_lpm_l1_timeout" ]; then
            echo 0 > "$dev/power/usb2_lpm_l1_timeout" 2>/dev/null && \
                echo "  Disabled L1 LPM timeout on $devpath" || true
        fi
        if [ -f "$dev/power/usb3_lpm_permit" ]; then
            echo 0 > "$dev/power/usb3_lpm_permit" 2>/dev/null && \
                echo "  Disabled U1/U2 LPM on $devpath" || true
        fi
        # Disable autosuspend (mirrors UVC_QUIRK_DISABLE_AUTOSUSPEND)
        echo "on" > "$dev/power/control" 2>/dev/null && \
            echo "  Disabled autosuspend on $devpath" || true
        # Set avoid_reset_quirk (extra safety)
        echo 1 > "$dev/avoid_reset_quirk" 2>/dev/null && \
            echo "  Set avoid_reset_quirk on $devpath" || true
        echo "  Found Kiyo Pro at $devpath"
    fi
done

# 2. Install persistent udev rules (apply on replug)
echo ""
echo "[2/3] Installing udev rules..."
cat > /etc/udev/rules.d/99-razer-kiyo-pro.rules << 'UDEV'
# Razer Kiyo Pro (1532:0e05) — prevent xHCI cascade failure
# Mirrors: USB_QUIRK_NO_LPM + UVC_QUIRK_DISABLE_AUTOSUSPEND + avoid_reset_quirk
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="1532", ATTR{idProduct}=="0e05", \
  ATTR{avoid_reset_quirk}="1", \
  ATTR{power/control}="on", \
  ATTR{power/usb3_lpm_permit}="0"
UDEV
udevadm control --reload-rules
echo "  Installed /etc/udev/rules.d/99-razer-kiyo-pro.rules"

# 3. Verify current state
echo ""
echo "[3/3] Current device state:"
for dev in /sys/bus/usb/devices/*/; do
    if [ -f "$dev/idVendor" ] && \
       [ "$(cat "$dev/idVendor" 2>/dev/null)" = "$KIYO_VID" ] && \
       [ "$(cat "$dev/idProduct" 2>/dev/null)" = "$KIYO_PID" ]; then
        devpath=$(basename "$dev")
        echo "  Device:           $devpath"
        echo "  avoid_reset_quirk: $(cat "$dev/avoid_reset_quirk" 2>/dev/null || echo N/A)"
        echo "  power/control:    $(cat "$dev/power/control" 2>/dev/null || echo N/A)"
        echo "  usb3_lpm_permit:  $(cat "$dev/power/usb3_lpm_permit" 2>/dev/null || echo N/A)"
        echo "  runtime_status:   $(cat "$dev/power/runtime_status" 2>/dev/null || echo N/A)"
    fi
done

echo ""
echo "=== Quirks applied ==="
echo "  LPM disabled, autosuspend disabled, avoid_reset_quirk set."
echo "  Use the camera normally — if no crashes occur over several days,"
echo "  the kernel patches can be submitted upstream with this test data."
echo ""
echo "To stress-test: run 'v4l2-ctl -d /dev/video0 --set-ctrl=focus_automatic_continuous=1'"
echo "in a loop, which previously triggered the -32 EPIPE crash."
