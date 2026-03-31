#!/bin/bash
# Send Razer Kiyo Pro kernel patch series upstream
cd "$(dirname "$0")"

git send-email \
  --to="Laurent Pinchart <laurent.pinchart@ideasonboard.com>" \
  --to="Hans de Goede <hansg@kernel.org>" \
  --to="Greg Kroah-Hartman <gregkh@linuxfoundation.org>" \
  --cc="linux-media@vger.kernel.org" \
  --cc="linux-usb@vger.kernel.org" \
  --cc="Ricardo Ribalda <ribalda@chromium.org>" \
  --cc="Michal Pecio <michal.pecio@gmail.com>" \
  --thread \
  --no-chain-reply-to \
  0000-cover-letter.txt \
  0001-usb-core-add-NO_LPM-quirk-for-Razer-Kiyo-Pro.patch \
  0002-media-uvcvideo-add-UVC_QUIRK_CTRL_THROTTLE-for-fragile-firmware.patch \
  0003-media-uvcvideo-add-quirks-for-Razer-Kiyo-Pro-webcam.patch
