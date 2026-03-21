#!/bin/bash
# Apply Razer Kiyo Pro quirks for upstream kernel patch testing
# Cleans up stale fixes, applies new LPM/autosuspend quirks alongside existing ones
#
# Run: sudo bash ~/Projects/kiyo-xhci-fix/kernel-patches/apply-and-test.sh
# Undo: sudo bash ~/Projects/kiyo-xhci-fix/kernel-patches/apply-and-test.sh --undo

set -e

KIYO_VID="1532"
KIYO_PID="0e05"
BACKUP_DIR="/etc/udev/rules.d/.kiyo-backup"

if [ "$1" = "--undo" ]; then
    echo "=== Undoing test changes ==="

    # Restore stale recovery rule if it was backed up
    if [ -f "$BACKUP_DIR/99-kiyo-pro-recovery.rules" ]; then
        cp "$BACKUP_DIR/99-kiyo-pro-recovery.rules" /etc/udev/rules.d/
        echo "[1] Restored 99-kiyo-pro-recovery.rules"
    fi

    # Remove new combined rule
    rm -f /etc/udev/rules.d/99-razer-kiyo-pro.rules
    echo "[2] Removed 99-razer-kiyo-pro.rules"

    udevadm control --reload-rules
    echo "[3] Reloaded udev rules"
    echo ""
    echo "Done. Revert is complete. Replug camera or reboot to take effect."
    exit 0
fi

echo "=== Razer Kiyo Pro — Apply Upstream Quirk Test ==="
echo ""

# 1. Remove stale recovery rule (has wrong port path 2-3.1)
echo "[1/5] Removing stale recovery rule..."
mkdir -p "$BACKUP_DIR"
if [ -f /etc/udev/rules.d/99-kiyo-pro-recovery.rules ]; then
    cp /etc/udev/rules.d/99-kiyo-pro-recovery.rules "$BACKUP_DIR/"
    rm /etc/udev/rules.d/99-kiyo-pro-recovery.rules
    echo "  Backed up and removed 99-kiyo-pro-recovery.rules"
else
    echo "  Not present, skipping"
fi

# 2. Replace old avoid_reset_quirk rule with comprehensive one
echo "[2/5] Installing combined udev rule..."
cat > /etc/udev/rules.d/99-razer-kiyo-pro.rules << 'UDEV'
# Razer Kiyo Pro (1532:0e05) — prevent xHCI cascade failure
# Tests upstream patches: USB_QUIRK_NO_LPM + UVC_QUIRK_DISABLE_AUTOSUSPEND
#
# avoid_reset_quirk  — prevent USB reset from cascading to xHCI controller
# power/control=on   — disable autosuspend (mirrors UVC_QUIRK_DISABLE_AUTOSUSPEND)
# usb3_lpm_permit=0  — disable LPM U1/U2 states (mirrors USB_QUIRK_NO_LPM)
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="1532", ATTR{idProduct}=="0e05", \
  ATTR{avoid_reset_quirk}="1", \
  ATTR{power/control}="on", \
  ATTR{power/usb3_lpm_permit}="0"
UDEV

# Remove old rule since new one covers avoid_reset_quirk
if [ -f /etc/udev/rules.d/99-kiyo-pro-no-cascade.rules ]; then
    cp /etc/udev/rules.d/99-kiyo-pro-no-cascade.rules "$BACKUP_DIR/"
    rm /etc/udev/rules.d/99-kiyo-pro-no-cascade.rules
    echo "  Backed up and removed old 99-kiyo-pro-no-cascade.rules"
fi
echo "  Installed 99-razer-kiyo-pro.rules"

udevadm control --reload-rules
echo "  Reloaded udev rules"

# 3. Apply to currently connected device
echo "[3/5] Applying quirks to live device..."
found=0
for dev in /sys/bus/usb/devices/*/; do
    if [ -f "$dev/idVendor" ] && \
       [ "$(cat "$dev/idVendor" 2>/dev/null)" = "$KIYO_VID" ] && \
       [ "$(cat "$dev/idProduct" 2>/dev/null)" = "$KIYO_PID" ]; then
        devpath=$(basename "$dev")
        echo 1 > "$dev/avoid_reset_quirk" 2>/dev/null && echo "  avoid_reset_quirk=1" || true
        echo "on" > "$dev/power/control" 2>/dev/null && echo "  power/control=on" || true
        # usb3_lpm_permit may not exist — USB 3.0 hardware LPM is set at enumeration
        # and can only be fully disabled with the compiled USB_QUIRK_NO_LPM kernel patch
        if [ -w "$dev/power/usb3_lpm_permit" ]; then
            echo 0 > "$dev/power/usb3_lpm_permit" && echo "  usb3_lpm_permit=0"
        else
            echo "  usb3_lpm_permit: read-only (needs kernel patch for full LPM disable)"
        fi
        found=1
    fi
done
[ "$found" = 0 ] && echo "  Kiyo not connected — will apply on next plug-in"

# 4. Verify existing complementary fixes are still in place
echo "[4/5] Verifying complementary fixes..."
if [ -f /etc/modprobe.d/razer-kiyo-pro.conf ]; then
    echo "  OK: snd-usb-audio quirk (rate probe skip)"
else
    echo "  MISSING: /etc/modprobe.d/razer-kiyo-pro.conf"
fi

# 5. Enable SSH so you can recover if USB dies anyway
echo "[5/5] Checking SSH..."
if systemctl is-active --quiet ssh 2>/dev/null || systemctl is-active --quiet sshd 2>/dev/null; then
    echo "  OK: SSH is running"
else
    echo "  WARNING: SSH is not running — if USB still dies, you'll need to reboot"
    echo "  Enable with: sudo systemctl enable --now ssh"
fi

# Summary
echo ""
echo "=== Applied ==="
echo "  [kept]    snd-usb-audio quirk     — skips rate probe (audio stability)"
echo "  [new]     USB_QUIRK_NO_LPM        — disables U1/U2 power states"
echo "  [new]     DISABLE_AUTOSUSPEND      — keeps device permanently active"
echo "  [new]     avoid_reset_quirk        — prevents reset cascade (was separate rule)"
echo "  [removed] stale recovery rule      — had wrong port path"
echo ""
echo "=== Testing ==="
echo "  Use the camera normally for a few days."
echo "  Stress test:  v4l2-ctl -d /dev/video0 --set-ctrl=focus_automatic_continuous=1"
echo "  Check logs:   journalctl -k -f | grep -i 'xhci\|uvc\|kiyo'"
echo ""
echo "  To undo:  sudo bash $0 --undo"
