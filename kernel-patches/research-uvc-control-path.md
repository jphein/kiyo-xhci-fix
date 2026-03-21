# UVC Control Transfer Crash Path — Kernel Source Analysis

## Device: Razer Kiyo Pro (1532:0e05)

## Crash Sequence Summary

```
v4l2-ctl SET_CUR (rapid) → usb_control_msg() → EPIPE (-32)
  → uvc_query_ctrl error handling sends another GET_CUR to read error code
  → second transfer also fails → xHCI stop-endpoint timeout
  → "xHCI host controller not responding, assume dead"
  → entire USB bus dies, all devices disconnect
```

---

## 1. Exact Code Path: v4l2 ioctl → usb_control_msg

### Entry: v4l2 ioctl (VIDIOC_S_EXT_CTRLS)

The v4l2 framework dispatches to `uvc_ioctl_s_ext_ctrls` in `uvc_v4l2.c`.

### Step 1: uvc_ctrl_begin() — Acquire mutex
**File:** `uvc_ctrl.c:2220-2223`
```c
int uvc_ctrl_begin(struct uvc_video_chain *chain)
{
    return mutex_lock_interruptible(&chain->ctrl_mutex) ? -ERESTARTSYS : 0;
}
```
This acquires `chain->ctrl_mutex`. Only ONE control transaction per chain at a time.

### Step 2: uvc_ctrl_set() — Stage the value
**File:** `uvc_ctrl.c:2618-2664`

Does NOT send a USB transfer. It:
- Looks up the control and mapping
- Validates (clamp) the value
- If the mapping doesn't span the full UVC control, calls `__uvc_ctrl_load_cur()` which DOES issue a `UVC_GET_CUR` USB transfer
- Backs up current value
- Sets `ctrl->dirty = 1`

### Step 3: __uvc_ctrl_commit() → uvc_ctrl_commit_entity() — Send SET_CUR
**File:** `uvc_ctrl.c:2229-2297`

Iterates all dirty controls and calls:
```c
ret = uvc_query_ctrl(dev, UVC_SET_CUR, ctrl->entity->id,
    dev->intfnum, ctrl->info.selector,
    uvc_ctrl_data(ctrl, UVC_CTRL_DATA_CURRENT),
    ctrl->info.size);
```
On error, sets `rollback = 1` for remaining controls, then releases `chain->ctrl_mutex`.

### Step 4: uvc_query_ctrl() — The actual USB transfer + error handling
**File:** `uvc_video.c:71-157`

```c
int uvc_query_ctrl(struct uvc_device *dev, u8 query, u8 unit,
        u8 intfnum, u8 cs, void *data, u16 size)
{
    ret = __uvc_query_ctrl(dev, query, unit, intfnum, cs, data, size,
                UVC_CTRL_CONTROL_TIMEOUT);  // 5000ms timeout
    if (likely(ret == size))
        return 0;

    // Short read quirk (ret > 0): zero-fill, return 0

    if (ret != -EPIPE) {
        // Non-EPIPE error: log and return
        return ret < 0 ? ret : -EPIPE;
    }

    // *** EPIPE case: sends ANOTHER USB control transfer ***
    ret = __uvc_query_ctrl(dev, UVC_GET_CUR, 0, intfnum,
               UVC_VC_REQUEST_ERROR_CODE_CONTROL, data, 1,
               UVC_CTRL_CONTROL_TIMEOUT);  // Another 5000ms timeout!

    // Translate UVC error code to errno
    switch (error) { ... }
}
```

### Step 5: __uvc_query_ctrl() — Raw USB control message
**File:** `uvc_video.c:32-45`

```c
static int __uvc_query_ctrl(struct uvc_device *dev, u8 query, u8 unit,
        u8 intfnum, u8 cs, void *data, u16 size, int timeout)
{
    u8 type = USB_TYPE_CLASS | USB_RECIP_INTERFACE;
    unsigned int pipe;
    pipe = (query & 0x80) ? usb_rcvctrlpipe(dev->udev, 0)
                  : usb_sndctrlpipe(dev->udev, 0);
    type |= (query & 0x80) ? USB_DIR_IN : USB_DIR_OUT;

    return usb_control_msg(dev->udev, pipe, query, type, cs << 8,
            unit << 8 | intfnum, data, size, timeout);
}
```

This is a thin wrapper around `usb_control_msg()` which calls `usb_internal_control_msg()` → `usb_start_wait_urb()`. The URB is submitted to the xHCI driver synchronously.

---

## 2. What Happens After EPIPE

### EPIPE = USB STALL

`-EPIPE` (errno 32) maps to a USB **STALL** handshake on the endpoint. The device is rejecting the control transfer.

### Critical: EPIPE triggers a SECOND USB transfer

When `uvc_query_ctrl()` receives `-EPIPE`, it immediately sends another control transfer (GET_CUR to `UVC_VC_REQUEST_ERROR_CODE_CONTROL`) to read the UVC error code. This is the **amplification** problem:

1. Original SET_CUR fails with EPIPE → device is already in a bad state
2. Driver immediately sends GET_CUR to read error code → stresses the device further
3. If the device is overwhelmed, this second transfer can also fail/hang
4. The xHCI controller waits for the transfer to complete (5000ms timeout)
5. If the device stops responding entirely, xHCI issues a **stop-endpoint** command

### No retry logic on SET_CUR

There is **no retry** after a SET_CUR EPIPE. The error is returned to userspace. However, the error-code query IS attempted, which is an additional USB transfer that the dying device must handle.

The only retry mechanism in the driver is in `__uvc_queryctrl_boundaries()` (`uvc_ctrl.c:1545-1563`):
```c
#define MAX_QUERY_RETRIES 2
for (retries = 0; retries < MAX_QUERY_RETRIES; retries++) {
    ret = uvc_ctrl_populate_cache(chain, ctrl);
    if (ret != -EIO)
        break;
}
```
This retries only `uvc_ctrl_populate_cache()` (GET_MIN/MAX/DEF/RES), not SET_CUR.

### No device reset on EPIPE

Unlike the Elgato Cam Link 4K special case (`uvc_video.c:2216-2228`) which calls `usb_reset_device()` on `-EPROTO`, there is no reset-on-EPIPE logic anywhere in the UVC driver. The Elgato logic only applies to video probe/commit control, not regular controls.

---

## 3. xHCI Stop-Endpoint Trigger Chain

The crash sequence from USB core to xHCI:

1. `usb_control_msg()` calls `usb_start_wait_urb()` with 5000ms timeout
2. The URB is submitted to xHCI via `xhci_urb_enqueue()`
3. xHCI queues a **Transfer TRB** on the device's **endpoint 0 transfer ring**
4. If the device STALLs or goes unresponsive:
   - xHCI receives a **Stall Error** completion event → returns `-EPIPE`
   - OR the transfer times out (no completion event at all)
5. On timeout, `usb_start_wait_urb()` calls `usb_kill_urb()` → `usb_hcd_unlink_urb()`
6. xHCI issues a **Stop Endpoint** command to ring doorbell 0
7. If the device's firmware is locked up, the **Stop Endpoint command itself times out**
8. xHCI driver logs: `"xHCI host controller not responding, assume dead"`
9. xHCI calls `xhci_hc_died()` → marks HC as dead → all URBs on all endpoints fail
10. USB core disconnects all devices on that controller

### Why rapid SET_CUR causes this:

The Razer Kiyo Pro firmware appears unable to handle rapid consecutive control transfers. Each SET_CUR that fails with EPIPE triggers an additional error-code query. With rapid v4l2-ctl calls, the pattern becomes:

```
SET_CUR → EPIPE → GET_CUR(error_code) → [maybe fails too]
SET_CUR → EPIPE → GET_CUR(error_code) → [maybe fails too]
SET_CUR → EPIPE → GET_CUR(error_code) → device firmware lockup
SET_CUR → device unresponsive → 5s timeout → stop-endpoint → xHCI dies
```

---

## 4. Existing Serialization (Mutexes/Locks)

### chain->ctrl_mutex (per video chain)
**Definition:** `uvcvideo.h:356`
```c
struct uvc_video_chain {
    struct mutex ctrl_mutex;  /* Protects ctrl.info, ctrl.handle,
                                 uvc_fh.pending_async_ctrls */
};
```

**Usage pattern:** Every control operation acquires this:
- `uvc_ctrl_begin()` locks it (`uvc_ctrl.c:2220-2223`)
- `__uvc_ctrl_commit()` unlocks it (`uvc_ctrl.c:2353`)
- `uvc_query_v4l2_ctrl()` locks/unlocks it
- `uvc_query_v4l2_menu()` locks/unlocks it
- `uvc_xu_ctrl_query()` locks/unlocks it

**Key insight:** This mutex serializes control operations within a single process but does NOT rate-limit them. Two rapid `v4l2-ctl` calls from different processes serialize correctly (they wait for the mutex), but the second one fires immediately after the first completes — no cooldown.

### No per-device rate limiting

There is zero rate-limiting infrastructure:
- No `ktime_t last_ctrl_time` field on any struct
- No `msleep()` or `usleep_range()` between control transfers
- No backoff after EPIPE errors
- No counter for consecutive failures

### The `__uvc_query_ctrl` → `usb_control_msg` path has NO mutex

The raw USB transfer function `__uvc_query_ctrl()` has no locking of its own. It relies entirely on callers holding `chain->ctrl_mutex`. The error-code query inside `uvc_query_ctrl()` is also covered by the same mutex since it's called within the locked section.

---

## 5. Where to Add Rate Limiting / Retry-with-Backoff

### Option A: In `uvc_query_ctrl()` — Best location (narrowest scope)
**File:** `uvc_video.c:71`

Add rate limiting BEFORE the `__uvc_query_ctrl()` call:

```c
int uvc_query_ctrl(struct uvc_device *dev, u8 query, u8 unit, ...)
{
    /* Rate limit: ensure minimum interval between control transfers */
    if (dev->quirks & UVC_QUIRK_CTRL_RATE_LIMIT) {
        ktime_t now = ktime_get();
        s64 elapsed_us = ktime_us_delta(now, dev->last_ctrl_time);
        if (elapsed_us < UVC_CTRL_MIN_INTERVAL_US)
            usleep_range(UVC_CTRL_MIN_INTERVAL_US - elapsed_us,
                         UVC_CTRL_MIN_INTERVAL_US - elapsed_us + 100);
        dev->last_ctrl_time = ktime_get();
    }

    ret = __uvc_query_ctrl(...);
    ...
```

**Pros:** Covers ALL control transfers (GET and SET), minimal code change.
**Cons:** Requires new quirk flag and new field on `struct uvc_device`.

### Option B: In `uvc_ctrl_commit_entity()` — SET_CUR specific
**File:** `uvc_ctrl.c:2262`

Add a delay between consecutive SET_CUR calls when committing multiple dirty controls, and add backoff after EPIPE:

```c
if (!rollback) {
    ret = uvc_query_ctrl(dev, UVC_SET_CUR, ...);
    if (ret == -EPIPE && (dev->quirks & UVC_QUIRK_CTRL_RATE_LIMIT)) {
        usleep_range(5000, 10000);  /* 5-10ms backoff */
        ret = uvc_query_ctrl(dev, UVC_SET_CUR, ...);  /* retry once */
    }
}
```

### Option C: Suppress error-code query on known-bad devices
**File:** `uvc_video.c:104-126`

When a device is known to crash on rapid transfers, skip the second USB transfer (error-code query) after EPIPE:

```c
if (ret != -EPIPE) {
    ...
    return ret < 0 ? ret : -EPIPE;
}

/* Skip error code query for devices that crash under load */
if (dev->quirks & UVC_QUIRK_NO_ERROR_QUERY) {
    return -EPIPE;
}
```

This eliminates the amplification problem entirely.

### Option D: Add to `struct uvc_device` for global tracking
**File:** `uvcvideo.h` — add to `struct uvc_device`:

```c
struct uvc_device {
    ...
    /* Control transfer rate limiting (quirk-gated) */
    ktime_t last_ctrl_time;
    unsigned int consecutive_ctrl_errors;
    ...
};
```

### Recommended Combined Approach

1. **New quirk flag:** `UVC_QUIRK_CTRL_RATE_LIMIT` (0x00080000)
2. **Device table entry:** Add Razer Kiyo Pro (1532:0e05) with this quirk
3. **In `uvc_query_ctrl()`:** Enforce minimum 5ms interval between transfers when quirk is set
4. **On EPIPE:** Skip the error-code GET_CUR query when quirk is set (prevents amplification)
5. **On consecutive EPIPE:** Exponential backoff (5ms, 10ms, 20ms) with max 3 retries

### Why NOT in userspace

While a userspace rate limiter (e.g., in v4l2-ctl or a udev wrapper) could work, it cannot prevent:
- Multiple processes racing (only the kernel mutex does this)
- The error-code query amplification (this is inside the kernel)
- Other kernel paths that call `uvc_query_ctrl()` (e.g., `uvc_ctrl_restore_values()` on resume)

---

## Key Constants

| Constant | Value | File |
|----------|-------|------|
| `UVC_CTRL_CONTROL_TIMEOUT` | 5000ms | `uvcvideo.h:58` |
| `UVC_CTRL_STREAMING_TIMEOUT` | 5000ms | `uvcvideo.h:59` |
| `MAX_QUERY_RETRIES` | 2 | `uvc_ctrl.c:1545` |
| `UVC_URBS` | 5 | `uvcvideo.h:54` |

## Key Structures

- `struct uvc_device` (`uvcvideo.h:577-627`) — per-device state, holds `quirks` u32
- `struct uvc_video_chain` (`uvcvideo.h:348-364`) — holds `ctrl_mutex`
- `struct uvc_control` (`uvcvideo.h:152-166`) — per-control state, `dirty`/`loaded` flags

## Existing Quirk Flags (for reference)

```
UVC_QUIRK_STATUS_INTERVAL       0x00000001
UVC_QUIRK_PROBE_MINMAX          0x00000002
UVC_QUIRK_PROBE_EXTRAFIELDS     0x00000004
UVC_QUIRK_BUILTIN_ISIGHT        0x00000008
UVC_QUIRK_STREAM_NO_FID         0x00000010
UVC_QUIRK_IGNORE_SELECTOR_UNIT  0x00000020
UVC_QUIRK_FIX_BANDWIDTH         0x00000080
UVC_QUIRK_PROBE_DEF             0x00000100
UVC_QUIRK_RESTRICT_FRAME_RATE   0x00000200
UVC_QUIRK_RESTORE_CTRLS_ON_INIT 0x00000400
UVC_QUIRK_FORCE_Y8              0x00000800
UVC_QUIRK_FORCE_BPP             0x00001000
UVC_QUIRK_WAKE_AUTOSUSPEND      0x00002000
UVC_QUIRK_NO_RESET_RESUME       0x00004000
UVC_QUIRK_DISABLE_AUTOSUSPEND   0x00008000
UVC_QUIRK_INVALID_DEVICE_SOF    0x00010000
UVC_QUIRK_MJPEG_NO_EOF          0x00020000
UVC_QUIRK_MSXU_META             0x00040000
```

Next available: `0x00080000`

## Razer Kiyo Pro Device Table Status

**Not currently in `uvc_ids[]`.** It matches the generic UVC catch-all at the end of the table:
```c
{ USB_INTERFACE_INFO(USB_CLASS_VIDEO, 1, UVC_PC_PROTOCOL_UNDEFINED) },
{ USB_INTERFACE_INFO(USB_CLASS_VIDEO, 1, UVC_PC_PROTOCOL_15) },
```

A specific entry would need to be added to apply quirks.
