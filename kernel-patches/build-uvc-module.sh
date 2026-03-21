#!/bin/bash
# Build a patched uvcvideo module with CTRL_THROTTLE quirk
# Extracts UVC source from installed kernel source, applies patch, builds module
set -euo pipefail

KVER=$(uname -r)
BUILD_DIR="/tmp/uvc-build-$$"
KHEADERS="/usr/src/linux-headers-$KVER"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Building patched uvcvideo module ==="
echo "Kernel: $KVER"
echo "Build dir: $BUILD_DIR"
echo ""

# Check prerequisites
if [ ! -d "$KHEADERS" ]; then
    echo "ERROR: kernel headers not found at $KHEADERS"
    echo "Install with: sudo apt install linux-headers-$KVER"
    exit 1
fi

# Check for kernel source tarball
KSRC_TAR="/usr/src/linux-source-6.8.0/linux-source-6.8.0.tar.bz2"
if [ ! -f "$KSRC_TAR" ]; then
    echo "Installing linux-source-6.8.0..."
    sudo apt install -y linux-source-6.8.0
fi

# Extract just the UVC driver source
mkdir -p "$BUILD_DIR"
echo "[1/4] Extracting UVC source from kernel tarball..."
tar -xjf "$KSRC_TAR" -C "$BUILD_DIR" --strip-components=1 \
    "linux-source-6.8.0/drivers/media/usb/uvc/"

UVC_SRC="$BUILD_DIR/drivers/media/usb/uvc"
echo "  Extracted to $UVC_SRC"

# Apply the CTRL_THROTTLE changes
echo "[2/4] Applying CTRL_THROTTLE patch..."

# Add quirk flag to uvcvideo.h
sed -i '/UVC_QUIRK_MSXU_META/a #define UVC_QUIRK_CTRL_THROTTLE\t0x00080000' "$UVC_SRC/uvcvideo.h"

# Add last_ctrl_set_jiffies field to uvc_device struct
sed -i '/u32 quirks;/a\\t/* Control transfer throttling (UVC_QUIRK_CTRL_THROTTLE) */\n\tunsigned long last_ctrl_set_jiffies;' "$UVC_SRC/uvcvideo.h"

# Add throttle logic to uvc_query_ctrl in uvc_video.c
# Insert rate-limit code before the __uvc_query_ctrl call
sed -i '/int uvc_query_ctrl.*/{
n
/^{/a\
\tunsigned long min_interval;\
\tunsigned long elapsed;\
\n\t/*\
\t * Rate-limit SET_CUR operations for devices with fragile firmware.\
\t * The Razer Kiyo Pro locks up after ~25 rapid consecutive SET_CUR\
\t * transfers, ultimately crashing the xHCI host controller.\
\t */\
\tif (query == UVC_SET_CUR \&\&\
\t    (dev->quirks \& UVC_QUIRK_CTRL_THROTTLE)) {\
\t\tmin_interval = msecs_to_jiffies(50);\
\t\tif (dev->last_ctrl_set_jiffies \&\&\
\t\t    time_before(jiffies,\
\t\t\t\tdev->last_ctrl_set_jiffies + min_interval)) {\
\t\t\telapsed = dev->last_ctrl_set_jiffies + min_interval -\
\t\t\t\t  jiffies;\
\t\t\tmsleep(jiffies_to_msecs(elapsed));\
\t\t}\
\t}
}' "$UVC_SRC/uvc_video.c"

# Add jiffies update after __uvc_query_ctrl call and skip error query for throttled devices
# This is trickier with sed, use a Python helper
python3 - "$UVC_SRC/uvc_video.c" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    content = f.read()

# Add jiffies tracking after __uvc_query_ctrl call
old = '\tret = __uvc_query_ctrl(dev, query, unit, intfnum, cs, data, size,\n\t\t\t\tUVC_CTRL_CONTROL_TIMEOUT);'
new = old + '''

\tif (query == UVC_SET_CUR)
\t\tdev->last_ctrl_set_jiffies = jiffies;
'''
content = content.replace(old, new, 1)

# Add EPIPE skip before the error code query
old_err = '\t/* Reuse data[0] to request the error code. */'
new_err = '''\t/*
\t * Skip the error code query for devices that crash under load.
\t * The standard error-code query (GET_CUR on
\t * UVC_VC_REQUEST_ERROR_CODE_CONTROL) sends a second USB transfer to
\t * a device that is already stalling, which can amplify the failure
\t * into a full firmware lockup and xHCI controller death.
\t */
\tif (dev->quirks & UVC_QUIRK_CTRL_THROTTLE)
\t\treturn -EPIPE;

\t/* Reuse data[0] to request the error code. */'''
content = content.replace(old_err, new_err, 1)

with open(path, 'w') as f:
    f.write(content)
print("  Applied throttle + EPIPE skip to uvc_video.c")
PYEOF

# Add Razer Kiyo Pro device entry to uvc_driver.c
python3 - "$UVC_SRC/uvc_driver.c" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    content = f.read()

# Insert before Oculus VR entry
marker = '\t/* Oculus VR Positional Tracker DK2 */'
entry = '''\t/* Razer Kiyo Pro — firmware crashes under rapid control transfers
\t * and on LPM/autosuspend resume, cascading into xHCI controller
\t * death that disconnects all USB devices on the bus. */
\t{ .match_flags\t\t= USB_DEVICE_ID_MATCH_DEVICE
\t\t\t\t| USB_DEVICE_ID_MATCH_INT_INFO,
\t  .idVendor\t\t= 0x1532,
\t  .idProduct\t\t= 0x0e05,
\t  .bInterfaceClass\t= USB_CLASS_VIDEO,
\t  .bInterfaceSubClass\t= 1,
\t  .bInterfaceProtocol\t= 0,
\t  .driver_info\t\t= UVC_INFO_QUIRK(UVC_QUIRK_CTRL_THROTTLE
\t\t\t\t\t| UVC_QUIRK_DISABLE_AUTOSUSPEND
\t\t\t\t\t| UVC_QUIRK_NO_RESET_RESUME) },

'''
content = content.replace(marker, entry + marker, 1)

with open(path, 'w') as f:
    f.write(content)
print("  Added Razer Kiyo Pro device entry to uvc_driver.c")
PYEOF

# Build the module
echo "[3/4] Building uvcvideo.ko..."
make -C "$KHEADERS" M="$UVC_SRC" modules 2>&1 | tail -5

# Copy result
echo "[4/4] Module built:"
ls -la "$UVC_SRC/uvcvideo.ko"
cp "$UVC_SRC/uvcvideo.ko" "$SCRIPT_DIR/uvcvideo-patched.ko"
echo ""
echo "Patched module saved to: $SCRIPT_DIR/uvcvideo-patched.ko"
echo ""
echo "To load:"
echo "  sudo modprobe -r uvcvideo"
echo "  sudo insmod $SCRIPT_DIR/uvcvideo-patched.ko"
echo ""
echo "To revert:"
echo "  sudo modprobe -r uvcvideo"
echo "  sudo modprobe uvcvideo"
