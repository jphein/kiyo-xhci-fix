#!/bin/bash
# Send Razer Kiyo Pro kernel patch series v8 upstream.
# Threading: --in-reply-to points at the v3 thread root, the same
# anchor used for v7. v8 will thread under the existing chain.
# (If you'd rather thread explicitly under v7 instead of the original
# root, switch --in-reply-to to <20260410002720.1033303-1-jp@jphein.com>.)

cd "$(dirname "$0")"

git send-email \
  --confirm=never \
  --to="Laurent Pinchart <laurent.pinchart@ideasonboard.com>" \
  --to="Hans de Goede <hansg@kernel.org>" \
  --to="Greg Kroah-Hartman <gregkh@linuxfoundation.org>" \
  --cc="linux-media@vger.kernel.org" \
  --cc="linux-usb@vger.kernel.org" \
  --cc="Ricardo Ribalda <ribalda@chromium.org>" \
  --cc="Michal Pecio <michal.pecio@gmail.com>" \
  --cc="Mathias Nyman <mathias.nyman@linux.intel.com>" \
  --in-reply-to="<20260331003806.212565-1-jp@jphein.com>" \
  --thread \
  --no-chain-reply-to \
  v8-0000-cover-letter.patch \
  v8-0001-media-uvcvideo-add-UVC_QUIRK_CTRL_THROTTLE-for-fragile-firmware.patch \
  v8-0002-media-uvcvideo-add-Razer-Kiyo-Pro-to-device-info-table.patch
