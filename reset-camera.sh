#!/bin/bash
# Reset Razer Kiyo Pro USB device when it hangs (UVC -71/-110 errors)
# If the simple reset fails, rebind the xHCI controller for Bus 002

DEV=$(lsusb | grep "Razer.*Kiyo" | sed 's/Bus \([0-9]*\) Device \([0-9]*\).*/\/dev\/bus\/usb\/\1\/\2/')

if [ -n "$DEV" ]; then
  echo "Trying soft reset on $DEV ..."
  sudo python3 -c "import fcntl,os; fd=os.open('$DEV',os.O_WRONLY); fcntl.ioctl(fd,21780,0); os.close(fd)" 2>/dev/null
  if [ $? -eq 0 ]; then
    echo "Soft reset OK"
    exit 0
  fi
fi

echo "Soft reset failed — rebinding USB controller..."
# Unbind and rebind just the USB port the camera is on
# Find the Kiyo's actual USB port path dynamically
KIYO_PORT=$(for d in /sys/bus/usb/devices/*/; do
  [ "$(cat "$d/idVendor" 2>/dev/null)" = "1532" ] && [ "$(cat "$d/idProduct" 2>/dev/null)" = "0e05" ] && basename "$d" && break
done)
if [ -z "$KIYO_PORT" ]; then
  echo "Kiyo not found in sysfs — skipping port rebind"
  KIYO_PORT="2-1"  # fallback to last known
fi
echo "Rebinding port $KIYO_PORT..."
echo "$KIYO_PORT" | sudo tee /sys/bus/usb/drivers/usb/unbind 2>/dev/null
sleep 2
echo "$KIYO_PORT" | sudo tee /sys/bus/usb/drivers/usb/bind 2>/dev/null

if [ $? -eq 0 ]; then
  echo "Controller reset OK — camera should re-enumerate"
else
  echo "Port rebind failed — trying full xHCI reset for Intel controller..."
  XHCI="0000:00:14.0"
  echo "$XHCI" | sudo tee /sys/bus/pci/drivers/xhci_hcd/unbind
  sleep 3
  echo "$XHCI" | sudo tee /sys/bus/pci/drivers/xhci_hcd/bind
  echo "Full xHCI reset done — all USB devices should re-enumerate"
fi
