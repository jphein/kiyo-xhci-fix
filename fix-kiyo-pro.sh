#!/bin/bash
# Fix Razer Kiyo Pro USB crash cascade
# Run with: sudo bash ~/Desktop/fix-kiyo-pro.sh

set -e

echo "=== Razer Kiyo Pro USB Crash Fix ==="

# Layer 1: Kernel module quirk — skip sample rate readback & defer interface setup
# Bit 0 = skip GET_CUR sample rate (prevents 16kHz vs 48kHz mismatch warning)
# Bit 26 = skip interface setup at probe (audio endpoint stays closed until needed)
echo "[1/4] Installing snd-usb-audio quirk for Kiyo Pro..."
cat > /etc/modprobe.d/razer-kiyo-pro.conf << 'EOF'
# Razer Kiyo Pro (1532:0e05) — skip rate readback + defer iface setup
# Prevents 16kHz/48kHz rate mismatch that destabilizes UVC firmware
options snd-usb-audio vid=0x1532 pid=0x0e05 quirk_flags=0x4000001
EOF
echo "  Done. (takes effect on next module load / reboot)"

# Layer 2: Prevent crash cascading via udev
echo "[2/4] Installing udev rule (avoid_reset_quirk)..."
cat > /etc/udev/rules.d/99-kiyo-pro-no-cascade.rules << 'EOF'
# Prevent Razer Kiyo Pro USB errors from cascading to xHCI controller
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="1532", ATTR{idProduct}=="0e05", ATTR{avoid_reset_quirk}="1"
EOF
udevadm control --reload-rules
echo "  Done."

# Layer 3: Apply quirk to already-plugged device (immediate, no reboot)
echo "[3/4] Applying avoid_reset_quirk to current device..."
found=0
for dev in /sys/bus/usb/devices/*/; do
    if [ -f "$dev/idVendor" ] && [ "$(cat "$dev/idVendor" 2>/dev/null)" = "1532" ] && [ "$(cat "$dev/idProduct" 2>/dev/null)" = "0e05" ]; then
        echo 1 > "$dev/avoid_reset_quirk"
        echo "  Set avoid_reset_quirk=1 on $(basename "$dev")"
        found=1
    fi
done
[ "$found" = 0 ] && echo "  Kiyo Pro not currently connected, will apply on next plug-in"

# Layer 4: Restart WirePlumber to pick up the 48kHz-only rule
echo "[4/4] Restarting WirePlumber (picks up 48kHz audio rule)..."
sudo -u jp XDG_RUNTIME_DIR=/run/user/$(id -u jp) systemctl --user restart wireplumber 2>/dev/null || true
echo "  Done."

echo ""
echo "=== All fixes applied ==="
echo "  Kernel:       snd-usb-audio quirk skips rate probe + defers iface setup"
echo "  udev:         avoid_reset_quirk prevents xHCI cascade"
echo "  WirePlumber:  forces Kiyo Pro audio to 48kHz only"
echo "  speech-to-cli: releases mic after 30s idle (already committed)"
echo ""
echo "NOTE: Kernel quirk takes full effect after reboot (or: sudo modprobe -r snd-usb-audio && sudo modprobe snd-usb-audio)"
