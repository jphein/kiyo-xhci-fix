#!/usr/bin/env python3
"""
kiyo-flash.py — Linux firmware tool for Razer Kiyo Pro (Sigmastar SAV630D)

Communicates with the camera in both normal UVC mode (1532:0e05) and
ROM boot mode (114D:8200) via SCSI vendor commands.

Protocol based on:
  - DongshanPI/SigmaStar-USBDownloadTool
  - OpenIPC/u-boot-sigmastar (f_firmware_update.c)
  - HackingThings/LinuxInMyWebcam (DEFCON 33)
  - ProbablyXS/razer-kiyo-pro-firmware-updater-fix

SCSI vendor command 0xE8 subcodes:
  0x01 DOWNLOAD_KEEP  — send data chunk (more to follow)
  0x02 GET_RESULT     — read 4-byte status
  0x03 GET_STATE      — query device state (ROM/Updater/U-Boot)
  0x04 DOWNLOAD_END   — send final data chunk
  0x05 UFU_LOADINFO   — send load address + size + MD5
  0x06 UFU_RUN_CMD    — execute u-boot command string

Result format: [0x0D, errcode, 0x00, 0x00]
  errcode 0x00 = success
  errcode 0x01 = MD5 error
  errcode 0x02 = invalid param
  errcode 0x03 = runcmd fail
"""

import argparse
import ctypes
import fcntl
import glob
import hashlib
import os
import struct
import sys
import time

# SCSI Generic (SG) ioctl constants
SG_IO = 0x2285
SG_DXFER_NONE = -1
SG_DXFER_TO_DEV = -2
SG_DXFER_FROM_DEV = -3

# SCSI vendor command
SSTAR_OPCODE = 0xE8
SUBCODE_DOWNLOAD_KEEP = 0x01
SUBCODE_GET_RESULT = 0x02
SUBCODE_GET_STATE = 0x03
SUBCODE_DOWNLOAD_END = 0x04
SUBCODE_UFU_LOADINFO = 0x05
SUBCODE_UFU_RUN_CMD = 0x06

# Device states (from SCSI INQUIRY bytes[16..])
DEV_STATE_ROM = 0
DEV_STATE_UPDATER = 1
DEV_STATE_UBOOT = 2
DEV_STATE_UNKNOWN = 3

MAX_PACKET = 32768  # 32KB max per SCSI transfer


class SgIoHdr(ctypes.Structure):
    """Linux SG_IO ioctl header structure."""
    _fields_ = [
        ('interface_id', ctypes.c_int),      # 'S' for SCSI
        ('dxfer_direction', ctypes.c_int),
        ('cmd_len', ctypes.c_ubyte),
        ('mx_sb_len', ctypes.c_ubyte),
        ('iovec_count', ctypes.c_ushort),
        ('dxfer_len', ctypes.c_uint),
        ('dxferp', ctypes.c_void_p),
        ('cmdp', ctypes.c_void_p),
        ('sbp', ctypes.c_void_p),
        ('timeout', ctypes.c_uint),          # milliseconds
        ('flags', ctypes.c_uint),
        ('pack_id', ctypes.c_int),
        ('usr_ptr', ctypes.c_void_p),
        ('status', ctypes.c_ubyte),
        ('masked_status', ctypes.c_ubyte),
        ('msg_status', ctypes.c_ubyte),
        ('sb_len_wr', ctypes.c_ubyte),
        ('host_status', ctypes.c_ushort),
        ('driver_status', ctypes.c_ushort),
        ('resid', ctypes.c_int),
        ('duration', ctypes.c_uint),
        ('info', ctypes.c_uint),
    ]


def sg_io(fd, cdb, data=None, data_len=0, direction=SG_DXFER_NONE, timeout_ms=120000):
    """Execute a SCSI command via SG_IO ioctl."""
    cdb_buf = (ctypes.c_ubyte * len(cdb))(*cdb)
    sense_buf = (ctypes.c_ubyte * 64)()

    if direction == SG_DXFER_FROM_DEV:
        data_buf = (ctypes.c_ubyte * data_len)()
        dxferp = ctypes.cast(data_buf, ctypes.c_void_p)
    elif direction == SG_DXFER_TO_DEV and data is not None:
        data_buf = (ctypes.c_ubyte * len(data))(*data)
        data_len = len(data)
        dxferp = ctypes.cast(data_buf, ctypes.c_void_p)
    else:
        data_buf = None
        dxferp = None
        data_len = 0

    hdr = SgIoHdr()
    hdr.interface_id = ord('S')
    hdr.dxfer_direction = direction
    hdr.cmd_len = len(cdb)
    hdr.mx_sb_len = 64
    hdr.dxfer_len = data_len
    hdr.dxferp = dxferp
    hdr.cmdp = ctypes.cast(cdb_buf, ctypes.c_void_p)
    hdr.sbp = ctypes.cast(sense_buf, ctypes.c_void_p)
    hdr.timeout = timeout_ms
    hdr.flags = 0
    hdr.pack_id = 0
    hdr.usr_ptr = None

    fcntl.ioctl(fd, SG_IO, hdr)

    if hdr.status != 0:
        sense_data = bytes(sense_buf[:hdr.sb_len_wr])
        raise RuntimeError(f"SCSI error: status=0x{hdr.status:02x}, "
                          f"host=0x{hdr.host_status:04x}, "
                          f"driver=0x{hdr.driver_status:04x}, "
                          f"sense={sense_data.hex()}")

    if direction == SG_DXFER_FROM_DEV:
        return bytes(data_buf[:data_len - hdr.resid])
    return None


def scsi_inquiry(fd):
    """Send SCSI INQUIRY and return 36-byte response."""
    cdb = [0x12, 0x00, 0x00, 0x00, 0x24, 0x00]  # INQUIRY, 36 bytes
    return sg_io(fd, cdb, data_len=36, direction=SG_DXFER_FROM_DEV)


def vendor_send(fd, subcode, data=None, timeout_ms=120000):
    """Send vendor SCSI command 0xE8 with data (bulk-out)."""
    data_len = len(data) if data else 0
    cdb = [SSTAR_OPCODE, subcode, 0, 0, 0, 0,
           (data_len >> 24) & 0xFF,
           (data_len >> 16) & 0xFF,
           (data_len >> 8) & 0xFF,
           data_len & 0xFF]
    if data:
        sg_io(fd, cdb, data=data, direction=SG_DXFER_TO_DEV, timeout_ms=timeout_ms)
    else:
        sg_io(fd, cdb, direction=SG_DXFER_NONE, timeout_ms=timeout_ms)


def vendor_recv(fd, subcode, length, timeout_ms=120000):
    """Send vendor SCSI command 0xE8 and read data (bulk-in)."""
    cdb = [SSTAR_OPCODE, subcode, 0, 0, 0, 0,
           (length >> 24) & 0xFF,
           (length >> 16) & 0xFF,
           (length >> 8) & 0xFF,
           length & 0xFF]
    return sg_io(fd, cdb, data_len=length, direction=SG_DXFER_FROM_DEV,
                 timeout_ms=timeout_ms)


def get_result(fd, retries=10):
    """Read 4-byte result. Returns (success: bool, errcode: int)."""
    for attempt in range(retries):
        try:
            result = vendor_recv(fd, SUBCODE_GET_RESULT, 4)
            if len(result) >= 2:
                return result[0] == 0x0D and result[1] == 0x00, result[1]
        except RuntimeError:
            pass
        time.sleep(0.1)
    return False, 0xFF


def get_state(fd):
    """Query device state. Returns DEV_STATE_* constant."""
    try:
        result = vendor_recv(fd, SUBCODE_GET_STATE, 4)
        if len(result) >= 1:
            return result[0]
    except RuntimeError:
        pass
    return DEV_STATE_UNKNOWN


def send_data(fd, data, max_packet=MAX_PACKET):
    """Send data in chunks using DOWNLOAD_KEEP/DOWNLOAD_END."""
    offset = 0
    total = len(data)
    while offset < total:
        chunk_size = min(max_packet, total - offset)
        chunk = data[offset:offset + chunk_size]
        is_last = (offset + chunk_size >= total)
        subcode = SUBCODE_DOWNLOAD_END if is_last else SUBCODE_DOWNLOAD_KEEP
        vendor_send(fd, subcode, chunk)
        offset += chunk_size
        pct = offset * 100 // total
        print(f"\r  Sending: {offset}/{total} bytes ({pct}%)", end="", flush=True)
    print()


def send_loadinfo(fd, addr, size, md5_hash):
    """Send UFU_LOADINFO struct: addr(4) + size(4) + md5(16) = 24 bytes."""
    info = struct.pack("<II", addr, size) + md5_hash
    vendor_send(fd, SUBCODE_UFU_LOADINFO, info)


def run_cmd(fd, cmd_str):
    """Execute a u-boot command string on the device."""
    cmd_bytes = cmd_str.encode('ascii') + b'\x00'
    vendor_send(fd, SUBCODE_UFU_RUN_CMD, cmd_bytes)
    ok, err = get_result(fd)
    return ok, err


def download_file(fd, filepath, load_addr=0xFFFFFFFF):
    """Download a file to device RAM with loadinfo + MD5 verification."""
    with open(filepath, 'rb') as f:
        data = f.read()

    md5 = hashlib.md5(data).digest()
    print(f"  File: {filepath} ({len(data)} bytes)")
    print(f"  MD5:  {md5.hex()}")
    print(f"  Load addr: 0x{load_addr:08X}")

    send_loadinfo(fd, load_addr, len(data), md5)
    send_data(fd, data)

    # Wait for MD5 verification
    wait_ms = max(1000, len(data) // 20)
    time.sleep(wait_ms / 1000.0)

    ok, err = get_result(fd)
    if ok:
        print("  Download OK (MD5 verified)")
    else:
        err_names = {0: "success", 1: "MD5 error", 2: "invalid param",
                     3: "runcmd fail", 4: "img format error"}
        print(f"  Download FAILED: {err_names.get(err, f'unknown error 0x{err:02x}')}")
    return ok


def find_gcreader():
    """Scan /dev/sg* devices for a GCREADER SCSI device (Sigmastar bootloader)."""
    for sg_path in sorted(glob.glob("/dev/sg*")):
        try:
            fd = os.open(sg_path, os.O_RDWR)
            try:
                inquiry = scsi_inquiry(fd)
                # Check for GCREADER at bytes 8-15
                vendor_id = inquiry[8:16].decode('ascii', errors='replace').strip()
                if 'GCREADER' in vendor_id or 'GC' == vendor_id[:2]:
                    # Determine state from bytes 16-20
                    state_bytes = inquiry[16:21]
                    if state_bytes[0] == 0:
                        state = DEV_STATE_ROM
                        state_name = "ROM Boot"
                    elif state_bytes[:3] == b'UPD':
                        state = DEV_STATE_UPDATER
                        state_name = "Updater"
                    elif state_bytes[:3] == b'UBO':
                        state = DEV_STATE_UBOOT
                        state_name = "U-Boot"
                    else:
                        state = DEV_STATE_UNKNOWN
                        state_name = f"Unknown ({state_bytes.hex()})"

                    print(f"Found GCREADER at {sg_path} — state: {state_name}")
                    return fd, sg_path, state
            except (RuntimeError, OSError):
                pass
            os.close(fd)
        except (OSError, PermissionError):
            pass
    return None, None, None


def cmd_probe(args):
    """Check if device is in ROM boot mode."""
    print("Scanning for Sigmastar bootloader device (GCREADER)...")
    fd, path, state = find_gcreader()
    if fd is None:
        print("No GCREADER device found.")
        print("\nChecking for Razer Kiyo Pro in normal mode...")
        # Check if camera is in normal UVC mode
        import subprocess
        result = subprocess.run(["lsusb", "-d", "1532:0e05"],
                              capture_output=True, text=True)
        if result.stdout.strip():
            print(f"  Camera found in normal mode: {result.stdout.strip()}")
            print("  To enter ROM boot mode, use: kiyo-flash.py enter-romboot")
        else:
            print("  Camera not found in any mode.")
        return

    state_names = {DEV_STATE_ROM: "ROM Boot (mask ROM)",
                   DEV_STATE_UPDATER: "Updater (RAM)",
                   DEV_STATE_UBOOT: "U-Boot (ready for commands)"}
    print(f"\nDevice state: {state_names.get(state, 'Unknown')}")

    inquiry = scsi_inquiry(fd)
    print(f"INQUIRY vendor:  {inquiry[8:16].decode('ascii', errors='replace').strip()}")
    print(f"INQUIRY product: {inquiry[16:32].decode('ascii', errors='replace').strip()}")
    print(f"INQUIRY raw:     {inquiry.hex()}")
    os.close(fd)


def uvc_xu_query(video_fd, unit, selector, query, data):
    """Send a UVC query to an Extension Unit control.

    Uses the UVCIOC_CTRL_QUERY ioctl defined in linux/uvcvideo.h:

        struct uvc_xu_control_query {
            __u8  unit;
            __u8  selector;
            __u8  query;      // UVC_SET_CUR=0x01, UVC_GET_CUR=0x81
            __u16 size;
            __u8 *data;
        };

    For SET_CUR, data is sent to device. For GET_CUR, data buffer is filled.
    """
    UVCIOC_CTRL_QUERY = 0xc0107521  # _IOWR('u', 0x21, 16) on x86_64

    data_buf = (ctypes.c_ubyte * len(data))(*data)
    data_ptr = ctypes.cast(data_buf, ctypes.c_void_p).value

    # struct uvc_xu_control_query on x86_64: total 16 bytes
    #   __u8 unit;        // offset 0
    #   __u8 selector;    // offset 1
    #   __u8 query;       // offset 2
    #   /* pad 1 */       // offset 3
    #   __u16 size;       // offset 4
    #   /* pad 2 */       // offset 6
    #   __u8 *data;       // offset 8 (8-byte aligned pointer)
    query_buf = struct.pack("@BBBxH2xP", unit, selector, query,
                            len(data), data_ptr)

    fcntl.ioctl(video_fd, UVCIOC_CTRL_QUERY, query_buf)
    return bytes(data_buf)


def uvc_xu_set_cur(video_fd, unit, selector, data):
    """Send UVC SET_CUR to an Extension Unit control."""
    uvc_xu_query(video_fd, unit, selector, 0x01, data)


def uvc_xu_get_cur(video_fd, unit, selector, size):
    """Send UVC GET_CUR to an Extension Unit control. Returns response bytes."""
    return uvc_xu_query(video_fd, unit, selector, 0x81, bytes(size))


# --- Raw USB control transfers (bypass uvcvideo driver) ---
# Used when UVC descriptor marks a selector as GET-only but we need SET_CUR.
# The Windows driver ignores descriptor capabilities; Linux enforces them.

# USBDEVFS ioctl numbers (x86_64)
USBDEVFS_CONTROL = 0xc0185500         # _IOWR('U', 0, struct usbdevfs_ctrltransfer)
USBDEVFS_CLAIMINTERFACE = 0x8004550f  # _IOR('U', 15, unsigned int)
USBDEVFS_RELEASEINTERFACE = 0x80045510  # _IOR('U', 16, unsigned int)
USBDEVFS_IOCTL = 0xc0105512           # _IOWR('U', 18, struct usbdevfs_ioctl)
USBDEVFS_DISCONNECT = 0x5516          # _IO('U', 22) — sub-ioctl code
USBDEVFS_CONNECT = 0x5517             # _IO('U', 23) — sub-ioctl code

# UVC class request constants
UVC_SET_CUR = 0x01
UVC_GET_CUR = 0x81


def find_kiyo_usb_path():
    """Find /dev/bus/usb/BBB/DDD and interface number for Razer Kiyo Pro.

    Returns (usb_dev_path, interface_num) or (None, None).
    """
    for dev_dir in sorted(glob.glob("/sys/bus/usb/devices/[0-9]*-[0-9]*")):
        try:
            vid = open(os.path.join(dev_dir, "idVendor")).read().strip()
            pid = open(os.path.join(dev_dir, "idProduct")).read().strip()
            if vid == "1532" and pid == "0e05":
                busnum = int(open(os.path.join(dev_dir, "busnum")).read().strip())
                devnum = int(open(os.path.join(dev_dir, "devnum")).read().strip())
                usb_path = f"/dev/bus/usb/{busnum:03d}/{devnum:03d}"
                # UVC Video Control interface is typically interface 0
                return usb_path, 0
        except (OSError, ValueError):
            pass
    return None, None


def usb_raw_control(usb_fd, request_type, request, value, index, data,
                    timeout_ms=5000):
    """Send a raw USB control transfer via USBDEVFS_CONTROL ioctl.

    For device-to-host (request_type & 0x80): returns response bytes.
    For host-to-device: sends data, returns None.
    """
    is_read = bool(request_type & 0x80)
    length = len(data)

    if is_read:
        data_buf = (ctypes.c_ubyte * length)()
    else:
        data_buf = (ctypes.c_ubyte * length)(*data)

    data_ptr = ctypes.cast(data_buf, ctypes.c_void_p).value

    # struct usbdevfs_ctrltransfer on x86_64 (24 bytes):
    #   __u8  bRequestType;   // offset 0
    #   __u8  bRequest;       // offset 1
    #   __u16 wValue;         // offset 2
    #   __u16 wIndex;         // offset 4
    #   __u16 wLength;        // offset 6
    #   __u32 timeout;        // offset 8
    #   /* pad 4 bytes */     // offset 12
    #   void *data;           // offset 16
    ctrl_buf = struct.pack("@BBHHHIP", request_type, request, value, index,
                           length, timeout_ms, data_ptr)

    fcntl.ioctl(usb_fd, USBDEVFS_CONTROL, ctrl_buf)

    if is_read:
        return bytes(data_buf)
    return None


class RawUsbXu:
    """Raw USB access to UVC Extension Unit, bypassing uvcvideo driver.

    Detaches the kernel driver, claims the interface, and sends UVC class
    requests directly. Reattaches the driver on close.
    """

    def __init__(self, usb_path, interface_num):
        self.usb_fd = os.open(usb_path, os.O_RDWR)
        self.interface = interface_num
        self.detached = False

        # Detach kernel driver (uvcvideo) from the VC interface.
        # Uses USBDEVFS_IOCTL with USBDEVFS_DISCONNECT sub-ioctl:
        #   struct usbdevfs_ioctl { int ifno; int ioctl_code; void *data; }
        try:
            ioctl_buf = struct.pack("@iiP", self.interface, USBDEVFS_DISCONNECT, 0)
            fcntl.ioctl(self.usb_fd, USBDEVFS_IOCTL, ioctl_buf)
            self.detached = True
        except OSError as e:
            # ENODATA (61) = no driver attached, that's fine
            if e.errno != 61:
                raise

        # Claim the interface
        intf_buf = struct.pack("@I", self.interface)
        fcntl.ioctl(self.usb_fd, USBDEVFS_CLAIMINTERFACE, intf_buf)

    def set_cur(self, unit, selector, data):
        """UVC SET_CUR via raw USB control transfer."""
        usb_raw_control(
            self.usb_fd,
            request_type=0x21,  # host-to-device, class, interface
            request=UVC_SET_CUR,
            value=selector << 8,
            index=(unit << 8) | self.interface,
            data=data
        )

    def get_cur(self, unit, selector, size):
        """UVC GET_CUR via raw USB control transfer. Returns response bytes."""
        return usb_raw_control(
            self.usb_fd,
            request_type=0xA1,  # device-to-host, class, interface
            request=UVC_GET_CUR,
            value=selector << 8,
            index=(unit << 8) | self.interface,
            data=bytes(size)
        )

    def close(self):
        """Release interface and reattach kernel driver."""
        try:
            intf_buf = struct.pack("@I", self.interface)
            fcntl.ioctl(self.usb_fd, USBDEVFS_RELEASEINTERFACE, intf_buf)
        except OSError:
            pass
        if self.detached:
            try:
                ioctl_buf = struct.pack("@iiP", self.interface, USBDEVFS_CONNECT, 0)
                fcntl.ioctl(self.usb_fd, USBDEVFS_IOCTL, ioctl_buf)
            except OSError:
                pass
        os.close(self.usb_fd)

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()


def find_kiyo_video_dev():
    """Find the /dev/videoN device for the Razer Kiyo Pro."""
    import subprocess

    for dev in sorted(glob.glob("/dev/video*")):
        try:
            result = subprocess.run(
                ["v4l2-ctl", "-d", dev, "--info"],
                capture_output=True, text=True, timeout=2)
            if "1532" in result.stdout and "0e05" in result.stdout:
                return dev
        except (subprocess.TimeoutExpired, FileNotFoundError):
            pass

    # Fallback: try /dev/video0
    return "/dev/video0" if os.path.exists("/dev/video0") else None


def cmd_enter_romboot(args):
    """Enter ROM boot mode via UVC Extension Unit commands.

    Protocol reverse-engineered from AitUVCExtApi.dll (AITAPI_ResetToRomboot):

    The function sends two UVC SET_CUR transfers to Extension Unit 6
    (GUID {23e49ed0-1178-4f31-ae52-d2fb8a8d3b48}):

    1. XU6 selector 4, 8 bytes:  [0x16, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
       Command byte 0x16 (22) = "enter ROM boot" opcode
    2. Sleep 500ms
    3. XU6 selector 14, 16 bytes: [0xFF, 0x03, 0x00, ...zeros]
       Word 0x03FF (1023) = resolution/mode reset trigger

    The MMP8 variant (AITAPI_ResetToRomboot_MMP8) only sends step 1.
    The MMP16 variant (AITAPI_ResetToRomboot_MMP16) only sends step 3.
    The main variant sends both in sequence with a 500ms pause.

    After this, the device disconnects from USB and re-enumerates as
    114D:8200 (Sigmastar mask ROM bootloader, SCSI mass storage "GCREADER").
    """
    import subprocess

    print("=== Enter ROM Boot Mode ===")
    print()

    # Check camera is present in normal mode
    result = subprocess.run(["lsusb", "-d", "1532:0e05"],
                          capture_output=True, text=True)
    if not result.stdout.strip():
        print("Camera not found in normal mode (1532:0e05).")
        print("Checking for ROM boot device...")
        fd, path, state = find_gcreader()
        if fd:
            print(f"Already in ROM boot mode at {path}!")
            os.close(fd)
        else:
            print("Camera not found in any mode.")
        return

    print(f"Camera found: {result.stdout.strip()}")
    print()

    # Find the UVC video device
    video_dev = find_kiyo_video_dev()
    if not video_dev:
        print("ERROR: Could not find /dev/video* for Kiyo Pro")
        return 1

    print(f"Video device: {video_dev}")
    print()
    print("WARNING: This will force the camera into ROM boot mode.")
    print("The device will disconnect and re-enumerate as 114D:8200.")
    print("All USB video applications using the camera will lose access.")
    print()

    if not args.force:
        try:
            confirm = input("Continue? [y/N] ").strip().lower()
            if confirm != 'y':
                print("Aborted.")
                return
        except (EOFError, KeyboardInterrupt):
            print("\nAborted.")
            return

    # Open video device
    try:
        video_fd = os.open(video_dev, os.O_RDWR)
    except OSError as e:
        print(f"ERROR: Cannot open {video_dev}: {e}")
        print("Try: sudo python3 kiyo-flash.py enter-romboot")
        return 1

    try:
        # Step 1: Send ROM boot command (XU6 selector 4, command byte 0x16)
        print("[Step 1] Sending ROM boot command to XU6 selector 4...")
        romboot_cmd = bytes([0x16, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        try:
            uvc_xu_set_cur(video_fd, unit=6, selector=4, data=romboot_cmd)
            print("  Sent: [0x16, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]")
        except OSError as e:
            # The device may disconnect immediately, causing an I/O error
            # This is expected — the command worked
            print(f"  Device responded with error (may be expected): {e}")

        # Step 2: Wait 500ms
        print("[Step 2] Waiting 500ms...")
        time.sleep(0.5)

        # Step 3: Send mode reset (XU6 selector 14, word 0x03FF)
        print("[Step 3] Sending mode reset to XU6 selector 14...")
        mode_reset = bytes([0xFF, 0x03] + [0x00] * 14)
        try:
            uvc_xu_set_cur(video_fd, unit=6, selector=14, data=mode_reset)
            print("  Sent: [0xFF, 0x03, 0x00, ...zeros] (16 bytes)")
        except OSError as e:
            print(f"  Device responded with error (may be expected): {e}")

    finally:
        os.close(video_fd)

    # Wait for device to re-enumerate
    print()
    print("Waiting for device to re-enumerate as 114D:8200...")
    for i in range(10):
        time.sleep(1)
        fd, path, state = find_gcreader()
        if fd:
            print(f"\nROM boot device found at {path}!")
            os.close(fd)
            return 0
        print(f"  Waiting... ({i+1}/10)")

    print()
    print("Device did not appear as GCREADER within 10 seconds.")
    print("Check 'lsusb' and 'dmesg' for clues.")
    print("If the device is still in normal mode, the command may need adjustment.")
    return 1


def _flash_image(usb_path, intf, fw_data, label="firmware",
                  phase1_cmd=0x30001, phase3_cmd=None):
    """Flash a single firmware image via UVC XU protocol.

    Sends data through XU6 and polls for burn completion.
    Returns True on success, False on error.
    The caller manages USB connection lifecycle.

    Command codes (from DLL disassembly):
      Firmware:  phase1=0x00030001, phase3=0x00030101
      IQ data:   phase1=0x05030001, phase3=0x05030101
    """
    if phase3_cmd is None:
        # Default: derive phase3 from phase1 by setting byte[1] to 0x01
        # 0x00030001 -> 0x00030101, 0x05030001 -> 0x05030101
        phase3_cmd = phase1_cmd | 0x100
    XU6_UNIT = 6
    fw_len = len(fw_data)

    xu = RawUsbXu(usb_path, intf)
    try:
        # Phase 1: Size handshake
        # DLL sends command header + fw_len as LE u32 to sel=4
        # Firmware uses 0x00030001, IQ calibration uses 0x05030001
        print(f"[Phase 1] Sending {label} size to sel=4...")
        size_data = struct.pack("<II", phase1_cmd, fw_len)
        xu.set_cur(XU6_UNIT, 4, size_data)
        print(f"  Sent size: {fw_len} bytes ({size_data.hex()})")

        print("  Reading ack from sel=5...")
        ack = xu.get_cur(XU6_UNIT, 5, 8)
        print(f"  Ack: {ack.hex()}")
        if ack[0] != 0x00:
            print(f"  ERROR: Device not ready (byte[0]=0x{ack[0]:02x}, expected 0x00)")
            return False
        print("  Device ready for data.")

        # Phase 2: Data transfer
        print(f"\n[Phase 2] Transferring {label} ({fw_len} bytes in 32-byte chunks)...")
        print("  Reading initial handshake from sel=3...")
        try:
            handshake = xu.get_cur(XU6_UNIT, 3, 32)
            print(f"  Handshake: {handshake[:8].hex()}...")
        except OSError:
            # sel=3 GET may STALL — the DLL does this but it's not required
            print("  Handshake: STALL (expected, continuing)")

        print("  Sleeping 300ms...")
        time.sleep(0.3)

        offset = 0
        total_chunks = (fw_len + 31) // 32
        start_time = time.time()
        while offset < fw_len:
            chunk_size = min(32, fw_len - offset)
            # Zero-padded 32-byte buffer (matches DLL behavior)
            chunk = bytearray(32)
            chunk[:chunk_size] = fw_data[offset:offset + chunk_size]

            xu.set_cur(XU6_UNIT, 3, bytes(chunk))
            offset += chunk_size

            # Progress display
            pct = offset * 100 // fw_len
            chunk_num = offset // 32
            elapsed = time.time() - start_time
            rate = offset / elapsed if elapsed > 0 else 0
            eta = (fw_len - offset) / rate if rate > 0 else 0
            print(f"\r  Sending: {offset}/{fw_len} bytes ({pct}%) "
                  f"[{chunk_num}/{total_chunks} chunks, "
                  f"{rate/1024:.1f} KB/s, ETA {eta:.0f}s]",
                  end="", flush=True)

        elapsed = time.time() - start_time
        print(f"\n  Transfer complete in {elapsed:.1f}s")

        # Phase 3: Completion
        # DLL sends phase3_cmd as LE u32 in first 4 bytes of 8-byte buffer
        print("\n[Phase 3] Sending completion signal to sel=4...")
        completion = struct.pack("<II", phase3_cmd, 0)
        xu.set_cur(XU6_UNIT, 4, completion)
        print(f"  Sent: {completion.hex()}")

        print("  Polling sel=5 for burn status...")
        zero_retries = 10  # DLL retries 10 times at 100ms when status=0x00
        for attempt in range(200):  # max ~6 seconds
            time.sleep(0.03)  # 30ms between polls
            status = xu.get_cur(XU6_UNIT, 5, 8)
            status_byte = status[0]

            if status_byte == 0x82:
                # 0x82 = burn complete (confirmed via DLL disassembly)
                print(f"  Status: 0x82 — burn complete!")
                break
            elif status_byte == 0x00:
                # 0x00 = still processing — DLL waits 100ms × 10 retries
                if zero_retries > 0:
                    zero_retries -= 1
                    time.sleep(0.1)  # 100ms per DLL
                else:
                    print("  Status: 0x00 persists — still processing...")
            else:
                # 0x81 or other = intermediate state, keep polling
                print(f"  Status: 0x{status_byte:02x} (intermediate, waiting for 0x82)...")
        else:
            print("  WARNING: Polling timed out (never reached 0x82)")
            return False

        # Windows updater sleeps 1s after burn completes before closing
        print("  Waiting 1s for flash controller to commit...")
        time.sleep(1.0)
        return True

    except OSError as e:
        print(f"\n  ERROR during {label} flash: {e}")
        return False
    finally:
        xu.close()


def _send_dev_reset(usb_path, intf):
    """Send full ResetToRomBoot sequence via a fresh USB connection.

    The Windows updater uses a two-step reset:
      1. DevReset: 0x16 to XU6 sel=4 (8 bytes) — prepare for reset
      2. 500ms sleep
      3. Mode reset: [0xFF, 0x03] to XU6 sel=14 (16 bytes) — trigger reboot

    Without step 3, the device acknowledges the reset but never actually
    reboots, so firmware written to RAM is never committed to SPI NAND.
    """
    XU6_UNIT = 6
    print("\n[DevReset] Opening fresh USB connection for reset...")
    xu = RawUsbXu(usb_path, intf)
    try:
        # Step 1: DevReset command
        reset_cmd = bytes([0x16] + [0x00] * 7)
        xu.set_cur(XU6_UNIT, 4, reset_cmd)
        print(f"  Step 1: Sent DevReset {reset_cmd.hex()}")

        # Step 2: Wait 500ms (matches Windows updater timing)
        time.sleep(0.5)

        # Step 3: Mode reset to trigger actual reboot
        mode_reset = bytes([0xFF, 0x03] + [0x00] * 14)
        xu.set_cur(XU6_UNIT, 14, mode_reset)
        print(f"  Step 3: Sent mode reset {mode_reset.hex()}")
        print("  Device should reboot now.")
    except OSError as e:
        # Device may disconnect immediately during reset — that's expected
        print(f"  Reset sent (device may have disconnected: {e})")
    finally:
        xu.close()


def _wait_for_kiyo(timeout=15):
    """Wait for Kiyo Pro to re-enumerate after reset. Returns (path, intf) or (None, None)."""
    print(f"\n  Waiting up to {timeout}s for device to re-enumerate...")
    for i in range(timeout):
        time.sleep(1.0)
        usb_path, intf = find_kiyo_usb_path()
        if usb_path:
            print(f"  Device found at {usb_path} after {i+1}s")
            return usb_path, intf
        print(f"  Waiting... ({i+1}/{timeout})")
    print("  Device did not re-enumerate within timeout.")
    return None, None


def cmd_flash_normal(args):
    """Flash firmware via normal-mode UVC Extension Unit protocol.

    Protocol reverse-engineered from AitUVCExtApi.dll AITAPI_UpdateFW_842x
    and AITDLL.dll UpdateDeviceFlash/DevReset, plus the ProbablyXS
    decompiled C# source (KiyoProCustomerFWU).

    The complete update sequence for the Kiyo Pro (UpdateIQFile=1):

    Stage 1 — Flash main firmware:
      Phase 1: SET_CUR sel=4 [0x30001 header + fw_len] → GET_CUR sel=5 ack
      Phase 2: GET_CUR sel=3 handshake → sleep 300ms → loop SET_CUR sel=3
      Phase 3: SET_CUR sel=4 completion → poll GET_CUR sel=5 → sleep 1s

    DevReset #1 — Fresh USB connection, SET_CUR sel=4 [0x16, 0, ...]

    Stage 2 — Flash IQ file (if --iqfile provided):
      Same Phase 1-3 as Stage 1, with the IQ calibration data

    DevReset #2 — Fresh USB connection again
    """
    print("=== Normal-Mode Firmware Flash ===")
    print()

    # Validate firmware file
    if not os.path.isfile(args.firmware):
        print(f"ERROR: Firmware file not found: {args.firmware}")
        return 1

    with open(args.firmware, 'rb') as f:
        fw_data = f.read()
    print(f"Firmware: {args.firmware} ({len(fw_data)} bytes)")

    # Load IQ file if provided
    iq_data = None
    if args.iqfile:
        if not os.path.isfile(args.iqfile):
            print(f"ERROR: IQ file not found: {args.iqfile}")
            return 1
        with open(args.iqfile, 'rb') as f:
            iq_data = f.read()
        print(f"IQ file:  {args.iqfile} ({len(iq_data)} bytes)")

    # Find the raw USB device
    usb_path, intf = find_kiyo_usb_path()
    if not usb_path:
        print("ERROR: Razer Kiyo Pro (1532:0e05) not found on USB bus.")
        return 1
    print(f"USB device: {usb_path}")
    print()

    if not args.force:
        print("WARNING: This will flash new firmware to the camera.")
        print("A bad flash can brick the device (recoverable via ROM boot mode).")
        print("Make sure you have a backup of the original firmware.")
        if iq_data:
            print(f"Will also flash IQ calibration data ({len(iq_data)} bytes).")
        else:
            print("NOTE: No --iqfile specified. The Kiyo Pro normally requires an")
            print("IQ file update (UpdateIQFile=1 in resources). The firmware update")
            print("may not persist without it. Use --iqfile iqfile.lfs for the full")
            print("update sequence.")
        print()
        try:
            confirm = input("Continue? [y/N] ").strip().lower()
            if confirm != 'y':
                print("Aborted.")
                return
        except (EOFError, KeyboardInterrupt):
            print("\nAborted.")
            return

    # === Stage 1: Flash main firmware ===
    print("=" * 50)
    print("STAGE 1: Flashing main firmware")
    print("=" * 50)

    if not _flash_image(usb_path, intf, fw_data, label="firmware",
                        phase1_cmd=0x30001):
        print("\nERROR: Firmware flash failed.")
        return 1

    # DevReset #1 — fresh USB connection
    _send_dev_reset(usb_path, intf)

    # === Stage 2: Flash IQ file (if provided) ===
    if iq_data:
        print()
        print("=" * 50)
        print("STAGE 2: Flashing IQ calibration data")
        print("=" * 50)

        # Wait for device to re-enumerate after first DevReset
        usb_path, intf = _wait_for_kiyo(timeout=15)
        if not usb_path:
            print("ERROR: Device did not re-enumerate after DevReset.")
            print("Try unplugging and replugging, then flash the IQ file separately.")
            return 1

        if not _flash_image(usb_path, intf, iq_data, label="IQ calibration",
                            phase1_cmd=0x5030001):
            print("\nERROR: IQ file flash failed.")
            return 1

        # DevReset #2 — fresh USB connection
        _send_dev_reset(usb_path, intf)

    print("\n=== Flash complete! ===")
    print("Wait for the camera to re-enumerate (5-10 seconds).")
    print("If it doesn't appear, unplug and replug the USB cable.")
    if iq_data:
        print("Both firmware and IQ calibration data were flashed.")
    return 0


def cmd_flash(args):
    """Flash firmware via ROM boot mode."""
    print("=== Sigmastar Firmware Flash Tool ===")
    print()

    # Find the GCREADER device
    fd, path, state = find_gcreader()
    if fd is None:
        print("ERROR: No GCREADER device found.")
        print("The camera must be in ROM boot mode first.")
        print("Use: kiyo-flash.py enter-romboot")
        return 1

    if state == DEV_STATE_ROM:
        # Stage 1: Load updater into RAM
        if not args.updater:
            print("ERROR: --updater required when device is in ROM boot state")
            os.close(fd)
            return 1

        print(f"[Stage 1] Loading updater firmware...")
        with open(args.updater, 'rb') as f:
            updater_data = f.read()

        # ROM boot mode uses 1KB chunks, no loadinfo
        send_data(fd, updater_data, max_packet=1024)
        os.close(fd)

        print("  Waiting for updater to initialize...")
        time.sleep(3)

        # Device should re-enumerate as updater
        fd, path, state = find_gcreader()
        if fd is None or state != DEV_STATE_UPDATER:
            print(f"ERROR: Expected updater state, got {state}")
            if fd:
                os.close(fd)
            return 1
        print(f"  Updater running at {path}")

    if state == DEV_STATE_UPDATER:
        # Stage 2: Load u-boot
        # For the Kiyo Pro, the updater may directly accept the firmware
        # without needing a separate u-boot stage
        pass

    # Stage 3: Flash the firmware image
    if not args.firmware:
        print("ERROR: --firmware required")
        if fd:
            os.close(fd)
        return 1

    print(f"\n[Stage 2] Flashing firmware...")
    ok = download_file(fd, args.firmware)
    if not ok:
        print("FLASH FAILED!")
        os.close(fd)
        return 1

    print("\n[Stage 3] Resetting device...")
    run_cmd(fd, "reset")
    os.close(fd)

    print("\nDone! Device should reboot with new firmware.")
    return 0


def cmd_uboot_shell(args):
    """Interactive u-boot command shell."""
    fd, path, state = find_gcreader()
    if fd is None:
        print("No GCREADER device found.")
        return 1

    if state != DEV_STATE_UBOOT:
        print(f"Device is in state {state}, not U-Boot.")
        print("U-Boot shell requires the device to be in U-Boot state.")
        os.close(fd)
        return 1

    print(f"Connected to U-Boot at {path}")
    print("Type 'quit' to exit, 'help' for u-boot help")
    print()

    while True:
        try:
            cmd = input("u-boot> ").strip()
        except (EOFError, KeyboardInterrupt):
            print()
            break

        if cmd == 'quit' or cmd == 'exit':
            break
        if not cmd:
            continue

        ok, err = run_cmd(fd, cmd)
        if ok:
            print("  OK")
        else:
            print(f"  ERROR (code {err})")

        if cmd == 'reset':
            print("Device resetting...")
            break

    os.close(fd)
    return 0


def cmd_dump_flash(args):
    """Dump SPI flash contents via u-boot commands."""
    fd, path, state = find_gcreader()
    if fd is None:
        print("No GCREADER device found.")
        return 1

    if state != DEV_STATE_UBOOT:
        print(f"Device must be in U-Boot state (current: {state})")
        os.close(fd)
        return 1

    output = args.output or "flash_dump.bin"
    size = args.size or 0x800000  # 8MB default (full SPI flash)
    ram_addr = 0x21000000  # Standard Sigmastar RAM load address

    print(f"Dumping {size} bytes of SPI flash to {output}...")
    print(f"  RAM addr: 0x{ram_addr:08X}")

    # Initialize SPI flash
    print("  sf probe 0...")
    ok, _ = run_cmd(fd, "sf probe 0")
    if not ok:
        print("  ERROR: sf probe failed")
        os.close(fd)
        return 1

    # Read flash to RAM
    print(f"  sf read 0x{ram_addr:08X} 0x0 0x{size:X}...")
    ok, _ = run_cmd(fd, f"sf read 0x{ram_addr:x} 0x0 0x{size:x}")
    if not ok:
        print("  ERROR: sf read failed")
        os.close(fd)
        return 1

    # TODO: Transfer RAM contents back to host
    # The protocol supports reading data back, but the exact mechanism
    # for bulk data transfer from device to host needs more research
    print("  NOTE: Data read to device RAM successfully.")
    print("  Bulk transfer back to host not yet implemented.")
    print("  Use 'md.b' command in u-boot shell to inspect memory manually.")

    os.close(fd)
    return 0


def main():
    parser = argparse.ArgumentParser(
        description="Razer Kiyo Pro firmware tool (Sigmastar SAV630D)",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s probe                    Check device state
  %(prog)s enter-romboot            Try to enter ROM boot mode
  %(prog)s flash-normal --firmware patched-fwimage.bin --iqfile iqfile.lfs
                                    Flash via UVC XU (normal mode, no ROM boot)
  %(prog)s flash --updater updater.bin --firmware fwimage.bin
                                    Flash via ROM boot mode (for bricked devices)
  %(prog)s uboot-shell              Interactive u-boot console
  %(prog)s dump-flash -o backup.bin Dump SPI flash (requires u-boot state)
        """)

    sub = parser.add_subparsers(dest='command', help='Command')

    sub.add_parser('probe', help='Detect device and report state')
    romboot_p = sub.add_parser('enter-romboot', help='Enter ROM boot mode via UVC XU')
    romboot_p.add_argument('--force', '-f', action='store_true',
                          help='Skip confirmation prompt')

    flash_normal_p = sub.add_parser('flash-normal',
        help='Flash firmware via normal-mode UVC XU protocol (no ROM boot)')
    flash_normal_p.add_argument('--firmware', required=True,
        help='Firmware image to flash (e.g., fwimage.bin)')
    flash_normal_p.add_argument('--iqfile',
        help='IQ calibration file (iqfile.lfs) — required for Kiyo Pro')
    flash_normal_p.add_argument('--force', '-f', action='store_true',
        help='Skip confirmation prompt')

    flash_p = sub.add_parser('flash', help='Flash firmware via ROM boot mode')
    flash_p.add_argument('--updater', help='Updater firmware (updater.bin)')
    flash_p.add_argument('--firmware', required=True, help='Main firmware image')

    sub.add_parser('uboot-shell', help='Interactive u-boot command shell')

    dump_p = sub.add_parser('dump-flash', help='Dump SPI flash contents')
    dump_p.add_argument('-o', '--output', help='Output file (default: flash_dump.bin)')
    dump_p.add_argument('-s', '--size', type=lambda x: int(x, 0),
                       help='Size in bytes (default: 0x800000 = 8MB)')

    args = parser.parse_args()
    if not args.command:
        parser.print_help()
        return 0

    commands = {
        'probe': cmd_probe,
        'enter-romboot': cmd_enter_romboot,
        'flash-normal': cmd_flash_normal,
        'flash': cmd_flash,
        'uboot-shell': cmd_uboot_shell,
        'dump-flash': cmd_dump_flash,
    }

    return commands[args.command](args) or 0


if __name__ == '__main__':
    sys.exit(main())
