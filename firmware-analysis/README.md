# Razer Kiyo Pro Firmware Analysis

## Device
- USB ID: 1532:0e05
- Firmware version: 1.5.0.1 (bcdDevice 8.21)
- SoC: Sigmastar SAV630D (ARM Cortex-A53, vision ISP)
- Camera module vendor: AIT (Alpha Imaging Technology → MStar → SigmaStar → MediaTek)
- Image sensor: Sony IMX327 (2MP, 1/2.8", starlight)
- SPI flash: Winbond W25N01GVZEIG (1Gbit / 128MB SPI NAND)
- Teardown: https://www.downtowndougbrown.com/2024/12/how-webcams-with-focus-control-work-razer-kiyo-pro-repair/

## The Bug

The firmware's USB descriptor table has a spec violation in the
SuperSpeed Endpoint Companion Descriptor for EP5 IN (interrupt):

- `wMaxPacketSize = 64` (correct)
- `wBytesPerInterval = 8` (WRONG — should be 64)

This causes the xHCI host controller to allocate insufficient bandwidth
for the endpoint, leading to spurious completion events and eventual
host controller death.

## UVC Extension Unit Protocol

The camera has two UVC Extension Units on interface 0:

| Unit | GUID | Controls | Purpose |
|------|------|----------|---------|
| XU2 | `{2c49d16a-32b8-4485-3ea8-643a152362f2}` | 6 (selectors 1-6) | Standard camera controls |
| XU6 | `{23e49ed0-1178-4f31-ae52-d2fb8a8d3b48}` | 15 (selectors 1-15) | AIT firmware/system control |

### XU6 Known Selectors

Reverse-engineered from `AitUVCExtApi.dll` (radare2 disassembly of exported
functions and the core KsProperty wrapper `fcn.1000a270`):

| Selector | Direction | Size | Purpose |
|----------|-----------|------|---------|
| 1 | SET_CUR | 8 | Command channel (send commands to firmware) |
| 2 | GET_CUR | 8 | Response channel (read firmware replies) |
| 4 | SET_CUR | 8 | System commands (ROM boot, etc.) |
| 14 | SET_CUR | 16 | Mode/resolution reset |

### Firmware Version Query

Send `{0xC0, 0x03, 0x01}` to XU6 selector 1 (SET_CUR, 8 bytes, pad with
zeros), then read XU6 selector 2 (GET_CUR, 8 bytes). Response bytes [0:4]
contain the version as four single-byte fields: `[major_lo, major_hi,
minor_lo, minor_hi]`. For firmware 1.5.0.1, response is `[0x01, 0x00, 0x05,
0x01]` → version 0.1.5.1 → display as 1.5.0.1.

Verified working on Linux via `UVCIOC_CTRL_QUERY` ioctl.

### ResetToRomBoot Protocol

Reverse-engineered from three exported functions in `AitUVCExtApi.dll`:

```
AITAPI_ResetToRomboot      @ RVA 0x6680 (VA 0x10007280) — full sequence
AITAPI_ResetToRomboot_MMP8 @ RVA 0x6730 (VA 0x10007330) — step 1 only
AITAPI_ResetToRomboot_MMP16@ RVA 0x67b0 (VA 0x100073b0) — step 3 only
```

All three use `fcn.1000a270` (VA 0x1000a270, 120+ xrefs), a DirectShow
KsProperty wrapper that sends UVC SET_CUR via `IKsControl::KsProperty`
with `KSPROPERTY_TYPE_SET | KSPROPERTY_TYPE_TOPOLOGY` (0x10000002).

**Full sequence** (`AITAPI_ResetToRomboot`):

1. **XU6 selector 4, SET_CUR, 8 bytes:** `[0x16, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]`
   - Command byte `0x16` (22 decimal) = "enter ROM boot" opcode
   - The MMP8 variant sends only this step
2. **Sleep 500ms** — device needs time to process shutdown
3. **XU6 selector 14, SET_CUR, 16 bytes:** `[0xFF, 0x03, 0x00, ...zeros]`
   - Word `0x03FF` (1023) at offset 0 = mode/resolution reset trigger
   - The MMP16 variant sends only this step

After the full sequence, the device disconnects from USB and re-enumerates
with VID/PID `114D:8200` (Alpha Imaging Technology / Sigmastar mask ROM).
The new device presents as SCSI mass storage with vendor ID "GCREADER".

**Linux implementation:** Use `UVCIOC_CTRL_QUERY` ioctl on `/dev/videoN`
with `unit=6, selector=4|14, query=UVC_SET_CUR (0x01)`. See `kiyo-flash.py`
`cmd_enter_romboot()` for the implementation.

## Location in Firmware Binary

Found in `DeviceUpdater.resources` (11.5MB .NET resource bundle
containing the firmware image) from both:
- Official: `RazerKiyoPro_0E05_FirmwareUpdater_v1.5.0.1_r1.exe`
- Community: `ProbablyXS/razer-kiyo-pro-firmware-updater-fix`

### Exact offset

```
Offset    Byte   Field
────────────────────────────────────────
0xa18452: 07     bLength (Endpoint Descriptor)
0xa18453: 05     bDescriptorType (Endpoint)
0xa18454: 85     bEndpointAddress (EP5 IN)
0xa18455: 03     bmAttributes (Interrupt)
0xa18456: 40 00  wMaxPacketSize (64)
0xa18458: 08     bInterval

0xa18459: 06     bLength (SS EP Companion)
0xa1845a: 30     bDescriptorType (0x30)
0xa1845b: 00     bMaxBurst
0xa1845c: 00     bmAttributes
0xa1845d: 08 00  wBytesPerInterval = 8  ← BUG
          ^^
          0x08 should be 0x40 (64)
```

### In raw firmware image (fwimage.bin)

The firmware extracted from the .NET ResourceSet is a 2,065,648-byte
image. The EP5 IN descriptor appears at a different offset here:

```
Offset     Byte   Field
────────────────────────────────────────
0x1F56FF:  07     bLength (Endpoint Descriptor)
0x1F5700:  05     bDescriptorType (Endpoint)
0x1F5701:  85     bEndpointAddress (EP5 IN)
0x1F5702:  03     bmAttributes (Interrupt)
0x1F5703:  40 00  wMaxPacketSize (64)
0x1F5705:  08     bInterval

0x1F5706:  06     bLength (SS EP Companion)
0x1F5707:  30     bDescriptorType (0x30)
0x1F5708:  00     bMaxBurst
0x1F5709:  00     bmAttributes
0x1F570A:  08 00  wBytesPerInterval = 8  ← BUG
           ^^
           0x08 should be 0x40 (64)
```

### Firmware header analysis

```
Offset  Value      Meaning
──────────────────────────────────
0x00:   12 04 00 EA  ARM branch instruction (vector table)
        ...
0x10:   F0 85 1F 00  Payload size: 0x1F85F0 (2,065,904 bytes)
0x18:   A1 36 00 00  Unknown field 0x36A1 — NOT a standard checksum
```

The field at offset 0x18 (`0x36A1`) was exhaustively tested against CRC16
(AIT polynomial 0x8005), CRC32, CRC-CCITT (0x1021), byte sum, and word
sum over multiple ranges. No match. Likely not a standard checksum, or
computed over an unknown subset of the image.

### To fix (hypothetical)

Change byte at offset `0x1F570A` in fwimage.bin (or `0xa1845d` in the
.NET ResourceSet) from `0x08` to `0x40`.

**WARNING**: Flashing modified firmware risks bricking the device.
The header field at offset 0x18 is of unknown purpose — it might be a
non-standard integrity check. The DEFCON 33 BadCam research (CVE-2025-4371)
found that Sigmastar webcams generally do **not** verify firmware signatures,
but this is unconfirmed for the SAV630D specifically.

**Recovery path**: If the flash fails but the mask ROM is intact, the
device should fall into ROM boot mode (114D:8200) on next power cycle,
allowing reflash of the original firmware via the SCSI protocol.

## Firmware Updater Components

The updater uses UVC Extension Unit commands over USB control transfers:
- `AitUVCExtApi.dll` — UVC extension API (talks to camera)
- `FWUpdaterDLL.dll` — firmware update protocol + Windows service management
- `AITDLL.dll` — low-level camera communication (P/Invoke, Cdecl calling convention)
- `KiyoProCustomerFWU.exe` — .NET Framework 4.6.1 GUI wrapper (C#)
- `DeviceUpdater.resources` — .NET ResourceSet bundle containing firmware image

### Update Protocol (from ProbablyXS source analysis)

The updater is a C# Windows Forms app decompiled/reconstructed by ProbablyXS.
Full source at https://github.com/ProbablyXS/razer-kiyo-pro-firmware-updater-fix.

**Device communication via AITDLL.dll:**
- `AITOpenDev(VID, PID)` → opens USB device handle by vendor/product ID
- `AITGetFWVersion(handle, cmd[], ver[])` → queries firmware version via UVC XU
  - For 0E05 (Kiyo Pro): command bytes `{0xC0, 0x03, 0x01}`, returns 4-byte version
- `UpdateDeviceFlash(handle, fwdata[], len)` → writes firmware blob to device flash
- `GetDevUpdateProgress()` → polls progress percentage during flash
- `ResetToRomBoot(handle)` → forces device into bootloader (ROM boot) mode
- `DevReset(handle)` → issues device reset after update

**ROM boot mode:**
- Device re-enumerates with VID/PID `114D:8200` (Sigmastar native USB ID)
- `AITOpenROMDev()` → opens device in bootloader mode (no VID/PID needed)
- `LoadUpdaterv3FW(handle, mode, path)` → loads updater firmware
- `LoadDevFWAtROMBoot(handle, mode, EraseNextArea, path)` → flashes main firmware

**Firmware extraction from .resources:**
- `DeviceUpdater.resources` is a .NET `ResourceSet` with named entries
- Firmware stored in sectors: `Device1FWSector0`, `Device1FWSector1`, ... + `Device1FWFileSize`
- Updater firmware: `UpdaterFWSector0`, ... + `UpdaterFWFileSize`
- IQ file (optional): `IQFWSector0`, ... + `IQFWFileSize`
- For PID 0E05 (Kiyo Pro): firmware written as `fwimage` (no extension)
- Updater written as `updater.bin`

**CRC16 validation:** `Common.CRC16(byte[])` computes checksum for data integrity.

**Flash sequence:**
1. Extract firmware sectors from ResourceSet to temp files
2. Open device via `AITOpenDev(0x1532, 0x0E05)`
3. Read firmware file into byte array
4. Call `UpdateDeviceFlash(handle, fwdata, len)` — returns 1 on success
5. Poll `GetDevUpdateProgress()` for progress percentage
6. Issue `DevReset()` after completion
7. If IQ file update needed: repeat steps 2-6 for IQ firmware
8. Verify new firmware version matches target
9. Delete temp files (`fwimage`, `updater.bin`, `iqfile.lfs`)

### Linux Flash Tool (kiyo-flash.py)

`kiyo-flash.py` implements the complete firmware update protocol on Linux:

```bash
# Check device state
sudo python3 kiyo-flash.py probe

# Enter ROM boot mode (sends UVC XU commands to camera)
sudo python3 kiyo-flash.py enter-romboot

# Flash firmware (device must be in ROM boot / GCREADER mode)
sudo python3 kiyo-flash.py flash --updater updater.bin --firmware fwimage.bin

# Interactive u-boot shell (if device reaches u-boot state)
sudo python3 kiyo-flash.py uboot-shell

# Dump SPI flash (backup before flashing)
sudo python3 kiyo-flash.py dump-flash -o backup.bin
```

**Implementation:**
- ROM boot entry: `UVCIOC_CTRL_QUERY` ioctl sending XU6 commands
- SCSI communication: `SG_IO` ioctl with vendor command `0xE8`
- Data transfer: chunked via `DOWNLOAD_KEEP`/`DOWNLOAD_END` subcodes
- Integrity: MD5 verification via `UFU_LOADINFO` subcode
- Shell access: `UFU_RUN_CMD` subcode executes u-boot command strings

**Status:** ROM boot entry (UVC XU commands) is implemented but **untested**.
SCSI protocol commands are implemented based on DongshanPI/SigmaStar-USBDownloadTool
and OpenIPC/u-boot-sigmastar source code.

**Risk:** ROM boot mode (114D:8200) provides a recovery path — the mask ROM
in the SoC presents a USB boot interface regardless of flash contents. Per
DEFCON 33 BadCam research, Sigmastar webcams generally lack firmware signature
verification, making reflash viable if the ROM boot pathway works.

## Firmware Extraction

The firmware is stored inside `DeviceUpdater.resources`, a .NET ResourceSet
(magic `0xBEEFCACE`) bundled in the updater executable. The ResourceSet
contains firmware split into 1024-byte sectors with named entries.

### Extracted images

| Entry pattern | Output file | Size | Content |
|---------------|-------------|------|---------|
| `Device1FWSector0..N` | `fwimage.bin` | 2,065,648 bytes | Main firmware (ARM, runs on SoC) |
| `UpdaterFWSector0..N` | `updater.bin` | 2,065,648 bytes | Identical to fwimage.bin |
| `IQFWSector0..N` | `iqfile.lfs` | 6,848,544 bytes | Image quality calibration data |

Note: `fwimage.bin` and `updater.bin` are byte-identical (MD5 match). This
suggests the Kiyo Pro uses a single firmware image for both the updater stage
and the main application, unlike dual-image SigmaStar designs.

The total firmware payload (fwimage + iqfile = ~8.9MB) fits within the 128MB
SPI NAND flash. The device likely has dual-bank partitions (RTOS_BACKUP +
RECOVERY) for fault tolerance during updates.

## ROM Boot Mode (SCSI Protocol)

When the SoC enters ROM boot mode (flash empty, corrupted, or forced via
ResetToRomBoot), it presents a USB mass storage device:

- **VID/PID:** `114D:8200` (Alpha Imaging Technology / Sigmastar native)
- **SCSI vendor:** "GCREADER"
- **Interface:** SCSI mass storage (Linux: `/dev/sgN`)

### SCSI Vendor Command 0xE8

All firmware operations use SCSI vendor command opcode `0xE8` with the
subcode in byte 1 of the 10-byte CDB:

| Subcode | Name | Direction | Payload | Purpose |
|---------|------|-----------|---------|---------|
| 0x01 | DOWNLOAD_KEEP | Host→Dev | Data chunk | Send data (more to follow) |
| 0x02 | GET_RESULT | Dev→Host | 4 bytes | Read status: `[0x0D, errcode, 0, 0]` |
| 0x03 | GET_STATE | Dev→Host | 4 bytes | Query device state (ROM/Updater/U-Boot) |
| 0x04 | DOWNLOAD_END | Host→Dev | Data chunk | Send final data chunk |
| 0x05 | UFU_LOADINFO | Host→Dev | 24 bytes | Load address (4) + size (4) + MD5 (16) |
| 0x06 | UFU_RUN_CMD | Host→Dev | String | Execute u-boot command (null-terminated) |

CDB format: `[0xE8, subcode, 0, 0, 0, 0, len_b3, len_b2, len_b1, len_b0]`

Error codes (from GET_RESULT byte 1):
- `0x00` = success
- `0x01` = MD5 verification failed
- `0x02` = invalid parameter
- `0x03` = runcmd failed
- `0x04` = image format error

### Flash sequence

1. Device is in ROM boot state (GCREADER, state=ROM)
2. Send `updater.bin` via DOWNLOAD_KEEP/DOWNLOAD_END (1KB chunks in ROM mode)
3. Device reboots into updater state (GCREADER, state=Updater)
4. Send LOADINFO: RAM address + firmware size + MD5 hash
5. Send `fwimage.bin` via DOWNLOAD_KEEP/DOWNLOAD_END (32KB chunks)
6. Device verifies MD5 and writes to SPI flash
7. Send `UFU_RUN_CMD("reset")` to reboot
8. (Optional) Repeat steps 4-7 for IQ file

### UFU_RUN_CMD (Interactive Shell)

Subcode 0x06 accepts any u-boot command string. This provides full
shell access to the device's u-boot environment, enabling:

- `sf probe 0` — initialize SPI flash
- `sf read <addr> <offset> <size>` — read flash to RAM
- `md.b <addr> <size>` — dump memory (hex)
- `printenv` — show u-boot environment variables
- `reset` — reboot device

This is the mechanism used by the SigmaStar USB Download Tool and
documented in the OpenIPC u-boot source (`f_firmware_update.c`).

## Sources

- Official updater: https://mysupport.razer.com/app/answers/detail/a_id/4582/
- Community fix: https://github.com/ProbablyXS/razer-kiyo-pro-firmware-updater-fix
- SigmaStar USB Download Tool: https://github.com/DongshanPI/SigmaStar-USBDownloadTool
- OpenIPC u-boot (f_firmware_update.c): https://github.com/OpenIPC/u-boot-sigmastar
- DEFCON 33 BadCam (CVE-2025-4371): https://github.com/HackingThings/LinuxInMyWebcam
- Eclypsium BadCam blog: https://eclypsium.com/blog/badcam-now-weaponizing-linux-webcams/
- Downtown Doug Brown teardown: https://www.downtowndougbrown.com/2024/12/how-webcams-with-focus-control-work-razer-kiyo-pro-repair/
- linux-chenxing.org (MStar/Sigmastar SoC): http://linux-chenxing.org/
- PSA Certified (SigmaStar SAV5xx/SAV6xx): https://products.psacertified.org/products/sigmastar-sav5xx-sav6xx-ssc37x-ssu939x-product-family
- SigmaStar USB/SD update docs: https://wx.comake.online/doc/ds82ff82j7jsd9-SSD220/customer/development/software/Px/en/sys/P3/usb%20update.html
- Sigmastar copyright string at firmware offset 0x73c5f
- AIT build path in DLLs: `D:\SampleSourceCode\0.AIT\SVN\CamAP_Windows\`
- Firmware build path: `/home/jack.zhou/dailyBuild/doRelease/Release_Build_20080603/`
