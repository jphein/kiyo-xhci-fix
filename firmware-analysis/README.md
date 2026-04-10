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
- `FWUpdaterDLL.dll` — firmware update protocol
- `AITDLL.dll` — low-level camera communication
- `KiyoProCustomerFWU.exe` — .NET GUI wrapper
- `DeviceUpdater.resources` — .NET resource bundle containing firmware image

## Sources

- Official updater: https://mysupport.razer.com/app/answers/detail/a_id/4582/
- Community fix: https://github.com/ProbablyXS/razer-kiyo-pro-firmware-updater-fix
- Sigmastar copyright string found at offset 0x73c5f in firmware
- Build path: `/home/jack.zhou/dailyBuild/doRelease/Release_Build_20080603/`
