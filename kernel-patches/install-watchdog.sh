#!/bin/bash
# Install the USB watchdog as a systemd user service
# Requires sudo once to install the sudoers file
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUDOERS_SRC="$SCRIPT_DIR/usb-watchdog-sudoers"
SUDOERS_DST="/etc/sudoers.d/usb-watchdog"
# Use the real user's home, not root's, when run via sudo
REAL_HOME="${SUDO_USER:+$(getent passwd "$SUDO_USER" | cut -d: -f6)}"
REAL_HOME="${REAL_HOME:-$HOME}"
REAL_USER="${SUDO_USER:-$(whoami)}"
USER_SERVICE="$REAL_HOME/.config/systemd/user/usb-watchdog.service"

echo "=== USB Watchdog Installer ==="
echo ""

# Step 1: Install sudoers file
echo "[1/4] Installing sudoers rules..."
if [ ! -f "$SUDOERS_SRC" ]; then
    echo "ERROR: $SUDOERS_SRC not found"
    exit 1
fi

# Validate sudoers syntax before installing
sudo cp "$SUDOERS_SRC" /tmp/usb-watchdog-sudoers.tmp
sudo chmod 0440 /tmp/usb-watchdog-sudoers.tmp
if sudo visudo -cf /tmp/usb-watchdog-sudoers.tmp; then
    sudo mv /tmp/usb-watchdog-sudoers.tmp "$SUDOERS_DST"
    echo "  Installed $SUDOERS_DST"
else
    sudo rm -f /tmp/usb-watchdog-sudoers.tmp
    echo "ERROR: sudoers syntax check failed!"
    exit 1
fi

# Step 2: Verify user service file exists
echo "[2/4] Checking user service file..."
if [ ! -f "$USER_SERVICE" ]; then
    echo "ERROR: $USER_SERVICE not found"
    echo "  Expected at ~/.config/systemd/user/usb-watchdog.service"
    exit 1
fi
echo "  Found $USER_SERVICE"

# Step 3: Disable old system service if present
echo "[3/4] Checking for old system service..."
if systemctl is-enabled usb-watchdog.service >/dev/null 2>&1; then
    echo "  Disabling old system service..."
    sudo systemctl disable --now usb-watchdog.service
    echo "  Old system service disabled"
else
    echo "  No old system service found (OK)"
fi

# Step 4: Enable and start user service (as the real user, not root)
echo "[4/4] Enabling user service..."
REAL_UID=$(id -u "$REAL_USER")
run_as_user() {
    sudo -u "$REAL_USER" XDG_RUNTIME_DIR="/run/user/$REAL_UID" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$REAL_UID/bus" "$@"
}
run_as_user systemctl --user daemon-reload
run_as_user systemctl --user enable --now usb-watchdog.service
echo "  User service enabled and started"

echo ""
echo "=== Verifying ==="
sleep 2
if run_as_user systemctl --user is-active usb-watchdog.service >/dev/null 2>&1; then
    echo "SUCCESS: usb-watchdog is running as a user service"
    run_as_user systemctl --user status usb-watchdog.service --no-pager 2>&1 | head -10
else
    echo "WARNING: Service may not be running yet. Check with:"
    echo "  systemctl --user status usb-watchdog.service"
fi

echo ""
echo "Manage with:"
echo "  systemctl --user status usb-watchdog.service"
echo "  systemctl --user restart usb-watchdog.service"
echo "  journalctl --user -u usb-watchdog.service -f"
