# USB Protocol Capture Setup for Kiyo Pro Firmware Flash

## Current State

### Device
- **Razer Kiyo Pro** (1532:0e05) on **Bus 002, Device 020**
- Connected via USB 3.0 (SuperSpeed 5Gbps) at Port 003 -> Port 001
- Interfaces: Video Control (IF 0), Video Streaming (IF 1), Audio (IF 2, 3)
- Driver: uvcvideo (IF 0 and 1), snd-usb-audio (IF 2 and 3)

### usbmon Module
- **NOT loaded** (not in lsmod output)
- Module exists at `/lib/modules/6.17.0-20-generic/kernel/drivers/usb/mon/usbmon.ko.zst`
- Verified with `modinfo usbmon` — in-tree, GPL licensed
- **To load**: `sudo modprobe usbmon`
- After loading, debugfs interface appears at `/sys/kernel/debug/usb/usbmon/`
- Text interface for bus 2: `/sys/kernel/debug/usb/usbmon/2u`

### Capture Tools Available
- **tcpdump**: installed (`/usr/bin/tcpdump`, version 4.99.4)
- **tshark**: **NOT installed** (candidate: 4.2.2-1.1build3, `sudo apt install tshark`)
- **wireshark**: installed (4.2.2-1.1build3) — can open pcap files after capture
- **usbmon text format**: always available once module is loaded (no extra packages)

### Important: usbmon interfaces not visible yet
tcpdump `--list-interfaces` does NOT show usbmon interfaces because the module isn't loaded.
After `sudo modprobe usbmon`, tcpdump will see `usbmon0`, `usbmon1`, `usbmon2`, etc.

## What the Flash Tool Does on the Wire

The `kiyo-flash.py flash-normal` command uses **raw USB control transfers** via
`USBDEVFS_CONTROL` ioctl on `/dev/bus/usb/002/020`. It detaches the uvcvideo kernel
driver from interface 0, claims it, sends UVC class requests directly, then reattaches.

### Protocol Phases (from cmd_flash_normal)

All transfers target **Extension Unit 6** on **interface 0**.

#### Phase 1 — Size Handshake
```
SET_CUR XU6 sel=4 (8 bytes): struct.pack("<II", 0x30001, fw_len)
  → bmRequestType=0x21, bRequest=0x01, wValue=0x0400, wIndex=0x0600, wLength=0x0008
  → Data: 01 00 03 00 XX XX XX XX  (where XX = firmware size as LE u32)

GET_CUR XU6 sel=5 (8 bytes): read ack
  → bmRequestType=0xA1, bRequest=0x81, wValue=0x0500, wIndex=0x0600, wLength=0x0008
  → Response byte[0] must be 0x00 (device ready)
```

#### Phase 2 — Data Transfer
```
GET_CUR XU6 sel=3 (32 bytes): initial handshake read (may STALL)
  → bmRequestType=0xA1, bRequest=0x81, wValue=0x0300, wIndex=0x0600, wLength=0x0020

Sleep 300ms

Loop: SET_CUR XU6 sel=3 (32 bytes each): firmware data in 32-byte chunks
  → bmRequestType=0x21, bRequest=0x01, wValue=0x0300, wIndex=0x0600, wLength=0x0020
  → Data: 32 bytes of firmware (zero-padded if last chunk < 32)
  → Total chunks = ceil(fw_len / 32)
```

#### Phase 3 — Completion
```
SET_CUR XU6 sel=4 (8 bytes): phase3_cmd as LE u32 + 4 zero bytes
  → Firmware: [0x01, 0x01, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00]  (0x00030101)
  → IQ file:  [0x01, 0x01, 0x03, 0x05, 0x00, 0x00, 0x00, 0x00]  (0x05030101)
  → bmRequestType=0x21, bRequest=0x01, wValue=0x0400, wIndex=0x0600, wLength=0x0008

Poll GET_CUR XU6 sel=5 (8 bytes) every 30ms:
  → bmRequestType=0xA1, bRequest=0x81, wValue=0x0500, wIndex=0x0600, wLength=0x0008
  → Wait for byte[0] == 0x82 (burn complete / success)
  → 0x81 = intermediate (burn in progress), 0x00 = processing (retry with 100ms delay)
```

#### Phase 4 — Device Reset (full ResetToRomBoot)
```
Step 1: SET_CUR XU6 sel=4 (8 bytes): [0x16, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
  → bmRequestType=0x21, bRequest=0x01, wValue=0x0400, wIndex=0x0600, wLength=0x0008
Step 2: Sleep 500ms
Step 3: SET_CUR XU6 sel=14 (16 bytes): [0xFF, 0x03, 0x00, ...zeros]
  → bmRequestType=0x21, bRequest=0x01, wValue=0x0E00, wIndex=0x0600, wLength=0x0010
  → Device may disconnect immediately (OSError expected)

Note: In testing, neither the bare 0x16 nor the full ResetToRomBoot
sequence causes an actual device reboot. The commands are accepted
silently but have no observable effect.
```

## usbmon Text Format Reference

Each line in `/sys/kernel/debug/usb/usbmon/2u`:
```
TIMESTAMP TYPE ADDRESS STATUS URB_LEN DATA_LEN [SETUP_BYTES] [DATA_BYTES]
```

- **TYPE**: `S` = URB submission, `C` = URB callback (completion), `E` = error
- **ADDRESS**: `BUS:DEV:EP` (e.g., `2:020:0` = bus 2, device 20, endpoint 0)
- **SETUP_BYTES**: For control EP0 submissions, 8 hex bytes of the setup packet
- **DATA_BYTES**: Payload data (hex, may be truncated)

### Example usbmon lines for our protocol

Phase 1 SET_CUR sel=4 submission:
```
ffff...  S  Co:2:020:0  s  21 01 00 04 00 06 08 00  8 = 01000300 XXXXXXXX
```

Phase 1 GET_CUR sel=5 submission + callback:
```
ffff...  S  Ci:2:020:0  s  a1 81 00 05 00 06 08 00  8 <
ffff...  C  Ci:2:020:0  0  8 = 00000000 00000000
```

Where:
- `Co` = Control OUT (host to device)
- `Ci` = Control IN (device to host)
- `s` = setup stage
- `= HEXDATA` = data bytes

### What to look for in the capture

1. **Phase 1 data correctness**: Verify `0x30001` header and firmware size match
2. **Phase 2 chunk count**: Compare total SET_CUR sel=3 count vs expected `ceil(fw_len/32)`
3. **Phase 2 data content**: First and last chunks should match firmware file bytes
4. **Phase 3 completion byte**: What does sel=5 status read return? 0x00 processing, 0x82 error, else done
5. **Phase 4 timing**: Does the reset go out? Does device disconnect cleanly?
6. **Missing transfers**: Are any phases missing or reordered vs the DLL sequence?
7. **STALL responses**: Does sel=3 GET_CUR STALL? Does the tool handle it?

## How to Run

### Step 1: Load usbmon
```bash
sudo modprobe usbmon
ls /sys/kernel/debug/usb/usbmon/   # should show 0u, 1u, 2u, etc.
```

### Step 2: (Optional) Install tshark for better output
```bash
sudo apt install tshark
```

### Step 3: Run the capture script
```bash
# Basic (raw usbmon text + tcpdump pcap):
sudo /home/jp/Projects/kiyo-xhci-fix/firmware-analysis/capture-flash.sh

# With custom firmware path:
sudo ./capture-flash.sh --firmware /path/to/firmware.bin

# With tshark (if installed):
sudo ./capture-flash.sh --tshark
```

### Step 4: Analyze the output
```bash
# Parse the raw usbmon text:
./parse-usbmon.sh /tmp/kiyo-flash-capture-*.usbmon-raw.txt 20

# Open pcap in Wireshark (filter: usb.device_address == 20):
wireshark /tmp/kiyo-flash-capture-*.pcap
```

### Wireshark USB display filters
```
usb.device_address == 20                          # All traffic to/from device 20
usb.bmRequestType == 0x21                         # All SET_CUR (class, host-to-device)
usb.bmRequestType == 0xa1                         # All GET_CUR (class, device-to-host)
usb.setup.wValue == 0x0400                        # Selector 4 (commands)
usb.setup.wValue == 0x0300                        # Selector 3 (data)
usb.setup.wValue == 0x0500                        # Selector 5 (status)
usb.setup.wIndex == 0x0600                        # Extension Unit 6, Interface 0
```

## Quick Manual Capture (No Script)

If you just want a quick capture without the script:

```bash
# Terminal 1: Start capture
sudo modprobe usbmon
sudo cat /sys/kernel/debug/usb/usbmon/2u > /tmp/kiyo-usbmon.txt

# Terminal 2: Run the flash
sudo python3 kiyo-flash.py flash-normal --firmware /tmp/razer-fw/fwimage-patched.bin --force

# Terminal 1: Ctrl+C to stop capture
# Then parse:
grep "21 01 00 04 00 06" /tmp/kiyo-usbmon.txt   # SET_CUR sel=4
grep "a1 81 00 05 00 06" /tmp/kiyo-usbmon.txt   # GET_CUR sel=5
grep -c "21 01 00 03 00 06" /tmp/kiyo-usbmon.txt # Count data chunks
```

## Key Questions the Capture Will Answer

1. **Does Phase 1 send the correct header?** Firmware: `0x30001`, IQ: `0x5030001`.
2. **Are all data chunks sent?** Count should be `ceil(fw_len / 32)`.
3. **What does the device respond to status reads?** 0x81 = burning, 0x82 = done, 0x00 = processing.
4. **Does the completion signal use the right command code?** Firmware: `0x30101`, IQ: `0x5030101`.
5. **Is the reset command received before device disconnects?**
6. **Any NAK/STALL on control transfers?** Could indicate the device is rejecting commands.

## Known Answers (from 2026-04-11 testing)

All questions above have been answered through 6+ flash attempts:
- Phase 1 headers are correct (confirmed via usbmon wire capture)
- All data chunks are sent and patched byte 0x40 reaches device at correct position
- Firmware stage reaches 0x82 after ~14 polls; IQ stage never reaches 0x82 (stuck at 0x81)
- Reset commands are accepted but do not cause device reboot
- **Conclusion:** Normal-mode UVC XU flash does not persist to SPI NAND on this device
