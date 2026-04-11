# Razer Kiyo Pro Firmware Analysis

## Device
- USB ID: 1532:0e05
- Firmware version: 1.5.0.1 (bcdDevice 8.21)
- SoC: Sigmastar (ARM-based ISP)
- Camera module vendor: AIT (Advanced Imaging Technology)

## The Bug

The firmware's USB descriptor table has a spec violation in the
SuperSpeed Endpoint Companion Descriptor for EP5 IN (interrupt):

- `wMaxPacketSize = 64` (correct)
- `wBytesPerInterval = 8` (WRONG — should be 64)

This causes the xHCI host controller to allocate insufficient bandwidth
for the endpoint, leading to spurious completion events and eventual
host controller death.

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

### To fix (hypothetical)

Change byte at offset `0xa1845d` from `0x08` to `0x40`.

**WARNING**: Flashing modified firmware risks bricking the device.
The firmware may have checksums or signatures that reject modifications.
No recovery path is known if the flash fails.

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

### Hypothetical Linux Flash Tool

A Linux implementation would need to:
1. Parse the .NET `DeviceUpdater.resources` to extract firmware sectors
2. Patch byte at offset 0xa1845d from 0x08 to 0x40 in the extracted firmware
3. Send the patched firmware via UVC Extension Unit control transfers
4. The UVC XU protocol used by `AITDLL.dll` would need reverse engineering
   (likely Wireshark USB capture of a Windows update session)

**Risk:** No known recovery path if flash fails. The ROM boot mode (114D:8200)
may provide a recovery path, but this is unverified.

## Sources

- Official updater: https://mysupport.razer.com/app/answers/detail/a_id/4582/
- Community fix: https://github.com/ProbablyXS/razer-kiyo-pro-firmware-updater-fix
- Sigmastar copyright string found at offset 0x73c5f in firmware
- Build path: `/home/jack.zhou/dailyBuild/doRelease/Release_Build_20080603/`
