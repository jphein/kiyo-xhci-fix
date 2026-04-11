#!/usr/bin/env bash
# parse-usbmon.sh — Extract firmware flash protocol phases from usbmon text capture
#
# Usage: ./parse-usbmon.sh <usbmon-raw.txt> [device_num]
#
# usbmon text format (from /sys/kernel/debug/usb/usbmon/Nu):
#
#   For Control OUT submission (host sends data to device):
#     TAG TS S Co:BUS:DEV:EP s RT RQ VL VH IL IH LL LH LEN = DATAHEX
#     Example: ffff... 123456 S Co:2:020:0 s 21 01 00 04 00 06 08 00 8 = 0100030087d61200
#
#   For Control IN submission (host requests data from device):
#     TAG TS S Ci:BUS:DEV:EP s RT RQ VL VH IL IH LL LH LEN <
#     (data comes back in the callback)
#
#   For Control callback (completion):
#     TAG TS C Co:BUS:DEV:EP STATUS LEN = DATAHEX  (OUT: echo of sent data)
#     TAG TS C Ci:BUS:DEV:EP STATUS LEN = DATAHEX  (IN: received data)
#
# IMPORTANT: Setup bytes have spaces between them (21 01 00 04 00 06 08 00)
#            Data bytes are grouped as 4-byte hex words WITHOUT spaces (0100030087d61200)
#
# UVC class requests we're looking for (setup packet patterns):
#   SET_CUR sel=3: 21 01 00 03 00 06 20 00  (32 bytes, firmware data)
#   SET_CUR sel=4: 21 01 00 04 00 06 08 00  (8 bytes, commands)
#   GET_CUR sel=3: a1 81 00 03 00 06 20 00  (32 bytes, handshake)
#   GET_CUR sel=5: a1 81 00 05 00 06 08 00  (8 bytes, status)
#   SET_CUR sel=14: 21 01 00 0e 00 06 10 00 (16 bytes, mode reset)

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Usage: $0 <usbmon-raw.txt> [device_num]"
    echo ""
    echo "device_num: USB device number (e.g., 20). If omitted, shows all control transfers."
    exit 1
fi

RAW_FILE="$1"
DEV_FILTER="${2:-}"

if [ ! -f "$RAW_FILE" ]; then
    echo "ERROR: File not found: $RAW_FILE"
    exit 1
fi

# If device number given, zero-pad to 3 digits for address matching
DEV_PAD=""
if [ -n "$DEV_FILTER" ]; then
    DEV_PAD=$(printf "%03d" "$DEV_FILTER")
fi

TOTAL_LINES=$(wc -l < "$RAW_FILE")

echo "============================================================"
echo "  USB Protocol Capture Analysis — Razer Kiyo Pro Flash"
echo "============================================================"
echo "  File: $RAW_FILE"
echo "  Device filter: ${DEV_FILTER:-all}"
echo "  Lines in capture: $TOTAL_LINES"
echo "============================================================"
echo ""

# ---- Helper: format data hex words into spaced byte pairs ----
# Input:  "0100030087d61200"  (usbmon grouped format)
# Output: "01 00 03 00 87 d6 12 00"
fmt_data() {
    echo "$1" | sed 's/\([0-9a-f]\{2\}\)/\1 /g' | sed 's/ $//'
}

# ---- Helper: decode data from a SET_CUR sel=4 line ----
# Identifies the command type from the first byte(s)
decode_sel4_data() {
    local data="$1"
    # Remove spaces between 4-byte groups
    local flat=$(echo "$data" | tr -d ' ')
    local b0="${flat:0:2}"
    local b1="${flat:2:2}"
    local b2="${flat:4:2}"
    local b3="${flat:6:2}"

    if [ "$b0" = "01" ] && [ "$b1" = "00" ] && [ "$b2" = "03" ] && [ "$b3" = "00" ]; then
        # Phase 1: Size command — bytes 4-7 are LE u32 firmware size
        local sz_hex="${flat:8:8}"
        # Reverse byte order for LE u32
        local sz_le="${sz_hex:6:2}${sz_hex:4:2}${sz_hex:2:2}${sz_hex:0:2}"
        local sz_dec=$((16#$sz_le))
        echo "PHASE 1 SIZE: header=0x30001, fw_size=$sz_dec (0x${sz_le})"
    elif [ "$b0" = "01" ] && [ "$b1" = "01" ] && [ "$b2" = "03" ] && [ "$b3" = "00" ]; then
        echo "PHASE 3 COMPLETION: [01 01 03 00 ...] — burn signal"
    elif [ "$b0" = "16" ]; then
        echo "PHASE 4 RESET: [0x16 ...] — device reset/romboot command"
    else
        echo "UNKNOWN: first bytes = $(fmt_data "${flat:0:16}")"
    fi
}

# =================================================================
# Phase 1: Size Handshake
# =================================================================
echo "=== Phase 1: Size Handshake ==="
echo "(SET_CUR XU6 sel=4 with firmware size, then GET_CUR sel=5 for ack)"
echo ""

# SET_CUR sel=4 submissions
echo "  SET_CUR sel=4 submissions (S Co:*:${DEV_PAD:-*}:0):"
grep " S Co:.*:${DEV_PAD:-[0-9]*}:0 " "$RAW_FILE" | \
    grep "21 01 00 04 00 06 08 00" | head -5 | while IFS= read -r line; do
    echo "    $line"
    # Extract data after "= "
    data=$(echo "$line" | sed -n 's/.*= //p')
    if [ -n "$data" ]; then
        echo "      -> $(decode_sel4_data "$data")"
        echo "      -> bytes: $(fmt_data "$data")"
    fi
done
echo ""

# GET_CUR sel=5 submissions (requests)
echo "  GET_CUR sel=5 submissions:"
grep " S Ci:.*:${DEV_PAD:-[0-9]*}:0 " "$RAW_FILE" | \
    grep "a1 81 00 05 00 06 08 00" | head -3 | while IFS= read -r line; do
    echo "    $line"
done
echo ""

# GET_CUR sel=5 callbacks (responses with data)
echo "  GET_CUR sel=5 callbacks (first few — ack data):"
# Callbacks for Ci (control IN) contain the device's response
grep " C Ci:.*:${DEV_PAD:-[0-9]*}:0 " "$RAW_FILE" | head -5 | while IFS= read -r line; do
    echo "    $line"
    data=$(echo "$line" | sed -n 's/.*= //p')
    if [ -n "$data" ]; then
        echo "      -> bytes: $(fmt_data "$data")"
    fi
done
echo ""

# =================================================================
# Phase 2: Data Transfer
# =================================================================
echo "=== Phase 2: Data Transfer ==="
echo "(SET_CUR XU6 sel=3 with 32-byte firmware chunks)"
echo ""

# Count data chunks (only submissions, not callbacks)
DATA_CHUNKS=$(grep -c " S Co:.*21 01 00 03 00 06 20 00" "$RAW_FILE" 2>/dev/null || echo "0")
# Fallback: count with looser pattern
if [ "$DATA_CHUNKS" = "0" ]; then
    DATA_CHUNKS=$(grep -c "21 01 00 03 00 06" "$RAW_FILE" 2>/dev/null || echo "0")
fi
echo "  Total SET_CUR sel=3 submissions: $DATA_CHUNKS"

if [ "$DATA_CHUNKS" -gt 0 ]; then
    echo ""
    echo "  First 3 data chunk submissions (with data):"
    grep "21 01 00 03 00 06" "$RAW_FILE" | grep " S " | head -3 | while IFS= read -r line; do
        echo "    $line"
        data=$(echo "$line" | sed -n 's/.*= //p')
        [ -n "$data" ] && echo "      -> bytes: $(fmt_data "$data")"
    done

    echo ""
    echo "  Last 3 data chunk submissions (with data):"
    grep "21 01 00 03 00 06" "$RAW_FILE" | grep " S " | tail -3 | while IFS= read -r line; do
        echo "    $line"
        data=$(echo "$line" | sed -n 's/.*= //p')
        [ -n "$data" ] && echo "      -> bytes: $(fmt_data "$data")"
    done
fi

# GET_CUR sel=3 handshake
echo ""
echo "  GET_CUR sel=3 (initial handshake read):"
grep "a1 81 00 03 00 06" "$RAW_FILE" | head -3 | while IFS= read -r line; do
    echo "    $line"
done
# Callback for GET sel=3
echo "  GET_CUR sel=3 callback (handshake response):"
# The callback immediately after the GET_CUR sel=3 submission
grep " C Ci:.*:${DEV_PAD:-[0-9]*}:0 " "$RAW_FILE" | head -3 | while IFS= read -r line; do
    echo "    $line"
    data=$(echo "$line" | sed -n 's/.*= //p')
    [ -n "$data" ] && echo "      -> bytes: $(fmt_data "$data")"
done
echo ""

# =================================================================
# Phase 3: Completion
# =================================================================
echo "=== Phase 3: Completion Signal ==="
echo "(SET_CUR XU6 sel=4 with [01 01 03 00 ...], then poll GET_CUR sel=5)"
echo ""

echo "  ALL SET_CUR sel=4 submissions (shows all phases):"
grep "21 01 00 04 00 06" "$RAW_FILE" | grep " S " | while IFS= read -r line; do
    echo "    $line"
    data=$(echo "$line" | sed -n 's/.*= //p')
    if [ -n "$data" ]; then
        echo "      -> $(decode_sel4_data "$data")"
        echo "      -> bytes: $(fmt_data "$data")"
    fi
done
echo ""

echo "  ALL SET_CUR sel=4 callbacks (completion status):"
grep "21 01 00 04 00 06" "$RAW_FILE" | grep " C " | while IFS= read -r line; do
    echo "    $line"
done
echo ""

# =================================================================
# Phase 4: Device Reset (part of SET_CUR sel=4 above)
# =================================================================
echo "=== Phase 4: Device Reset ==="
echo "(Look for 0x16 as first data byte in SET_CUR sel=4 above)"
echo ""

# =================================================================
# Status Polls
# =================================================================
echo "=== Status Reads (GET_CUR sel=5) ==="
echo ""

# Count GET_CUR sel=5 submissions
GET5_COUNT=$(grep -c "a1 81 00 05 00 06" "$RAW_FILE" 2>/dev/null || echo "0")
echo "  Total GET_CUR sel=5 (submit + callback): $GET5_COUNT"

# Show GET_CUR sel=5 callbacks (these have the actual status data)
GET5_CB_COUNT=$(grep " C Ci:" "$RAW_FILE" | grep -c ":${DEV_PAD:-[0-9]*}:0 " 2>/dev/null || echo "0")
echo "  Total Control IN callbacks: $GET5_CB_COUNT"

if [ "$GET5_COUNT" -gt 0 ]; then
    echo ""
    echo "  First 5 GET_CUR sel=5 submissions:"
    grep "a1 81 00 05 00 06" "$RAW_FILE" | grep " S " | head -5 | while IFS= read -r line; do
        echo "    $line"
    done

    echo ""
    echo "  Last 5 GET_CUR sel=5 submissions:"
    grep "a1 81 00 05 00 06" "$RAW_FILE" | grep " S " | tail -5 | while IFS= read -r line; do
        echo "    $line"
    done
fi
echo ""

# =================================================================
# Selector 14 (Mode Reset — only used in enter-romboot, not flash-normal)
# =================================================================
echo "=== Selector 14 Transfers (Mode Reset) ==="
SEL14_COUNT=$(grep -c "21 01 00 0e 00 06" "$RAW_FILE" 2>/dev/null || echo "0")
echo "  Total SET_CUR sel=14: $SEL14_COUNT"
if [ "$SEL14_COUNT" -gt 0 ]; then
    grep "21 01 00 0e 00 06" "$RAW_FILE" | while IFS= read -r line; do
        echo "    $line"
    done
fi
echo ""

# =================================================================
# Errors / STALLs
# =================================================================
echo "=== Errors and STALLs ==="
# STALL appears as status -32 in callbacks
STALL_COUNT=$(grep -c " C .*:${DEV_PAD:-[0-9]*}:0 .* -32 " "$RAW_FILE" 2>/dev/null || echo "0")
echo "  STALL responses (-32): $STALL_COUNT"
if [ "$STALL_COUNT" -gt 0 ]; then
    grep " C .*:${DEV_PAD:-[0-9]*}:0 .* -32 " "$RAW_FILE" | while IFS= read -r line; do
        echo "    $line"
    done
fi

# Other errors (negative status)
ERR_COUNT=$(grep " C .*:${DEV_PAD:-[0-9]*}:0 " "$RAW_FILE" | grep -c " -[0-9]" 2>/dev/null || echo "0")
echo "  Total error callbacks: $ERR_COUNT"
if [ "$ERR_COUNT" -gt 0 ] && [ "$ERR_COUNT" -le 20 ]; then
    grep " C .*:${DEV_PAD:-[0-9]*}:0 " "$RAW_FILE" | grep " -[0-9]" | while IFS= read -r line; do
        echo "    $line"
    done
fi
echo ""

# =================================================================
# Summary
# =================================================================
echo "=== Summary ==="
echo ""

SET4=$(grep -c "21 01 00 04 00 06" "$RAW_FILE" 2>/dev/null || echo "0")
GET5=$GET5_COUNT
SET3=$DATA_CHUNKS
GET3=$(grep -c "a1 81 00 03 00 06" "$RAW_FILE" 2>/dev/null || echo "0")

echo "  Transfer counts (submissions + callbacks combined):"
echo "    SET_CUR sel=3 (data chunks):     $SET3"
echo "    SET_CUR sel=4 (commands):         $SET4"
echo "    GET_CUR sel=3 (handshake):        $GET3"
echo "    GET_CUR sel=5 (status):           $GET5"
echo "    SET_CUR sel=14 (mode reset):      $SEL14_COUNT"
echo "    Errors/STALLs:                    $ERR_COUNT"
echo ""
echo "  Expected for a successful flash:"
echo "    SET_CUR sel=4: 3 (size + completion + reset)"
echo "    SET_CUR sel=3: ceil(fw_len / 32)"
echo "    GET_CUR sel=5: 2+ (initial ack + completion polls)"
echo ""

echo "============================================================"
echo "  Analysis complete"
echo "============================================================"
